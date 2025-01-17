{-# LANGUAGE OverloadedStrings #-}

-- |
-- A module for interacting with an SMT solver, using SmtLib-2 format.
--
-- A typical use of this module would look like the following.
-- @
-- import SimpleSMT.SExpr
-- import SimpleSMT.Solver
-- import qualified myBackend
-- import qualified Data.ByteString.Lazy.Char8 as LBS
-- import System.IO (putStrLn)
--
-- main :: IO ()
-- main = do
--   backend <- myBackend.new
--   solver <- initSolverWith backend lazyMode logger
--   setLogic solver "QF_UF"
--   p <- declare solver "p" tBool
--   assert solver $ p `and` not p
--   result <- check solver
--   putStrLn $ "result: " ++ show result
--   myBackend.stop backend
--
--  where lazyMode = True
--        logger = LBS.putStrLn
-- @
module SimpleSMT.Solver
  ( -- * Basic Solver Interface
    Solver (..),
    Backend (..),
    initSolverWith,
    command,
    ackCommand,
    simpleCommand,
    simpleCommandMaybe,
    loadFile,

    -- * Common SmtLib-2 Commands
    setLogic,
    setLogicMaybe,
    setOption,
    setOptionMaybe,
    produceUnsatCores,
    push,
    pushMany,
    pop,
    popMany,
    inNewScope,
    declare,
    declareFun,
    declareDatatype,
    define,
    defineFun,
    defineFunRec,
    defineFunsRec,
    assert,
    check,
    getExprs,
    getExpr,
    getConsts,
    getConst,
    getUnsatCore,
  )
where

import qualified Control.Exception as X
import Data.ByteString.Builder (Builder, lazyByteString, toLazyByteString)
import qualified Data.ByteString.Lazy.Char8 as LBS
import Data.IORef (IORef, atomicModifyIORef, newIORef)
import SimpleSMT.SExpr
import Prelude hiding (abs, and, concat, const, div, log, mod, not, or)

-- | The type of solver backends. SMTLib2 commands are sent to a backend which
-- processes them and outputs the solver's response.
data Backend = Backend
  { -- | Send a command to the backend.
    send :: Builder -> IO LBS.ByteString
  }

type Queue = IORef Builder

-- | Push a command on the solver's queue of commands to evaluate.
-- The command must not produce any output when evaluated, unless it is the last
-- command added before the queue is flushed.
putQueue :: Queue -> SExpr -> IO ()
putQueue q expr = atomicModifyIORef q $ \cmds ->
  (cmds <> renderSExpr expr, ())

-- | Empty the queue of commands to evaluate and return its content as a bytestring
-- builder.
flushQueue :: Queue -> IO Builder
flushQueue q = atomicModifyIORef q $ \cmds ->
  (mempty, cmds)

-- | A solver is essentially a wrapper around a solver backend. It also comes with
-- a function for logging the solver's activity, and an optional queue of commands
-- to send to the backend.
--
-- A solver can either be in eager mode or lazy mode. In eager mode, the queue of
-- commands isn't used and the commands are sent to the backend immediately. In
-- lazy mode, commands whose output are not strictly necessary for the rest of the
-- computation (typically the ones whose output should just be "success") and that
-- are sent through 'ackCommand' are not sent to the backend immediately, but
-- rather written on the solver's queue. When a command whose output is actually
-- necessary needs to be sent, the queue is flushed and sent as a batch to the
-- backend.
--
-- Lazy mode should be faster as there usually is a non-negligible constant
-- overhead in sending a command to the backend. But since the commands are sent by
-- batches, a command sent to the solver will only produce an error when the queue
-- is flushed, i.e. when a command with interesting output is sent. You thus
-- probably want to stick with eager mode when debugging. Moreover, when commands
-- are sent by batches, only the last command in the batch may produce an output
-- for parsing to work properly. Hence the ":print-success" option is disabled in
-- lazy mode, and this should not be overriden manually.
data Solver = Solver
  { -- | The backend processing the commands.
    backend :: Backend,
    -- | An optional queue to write commands that are to be sent to the solver lazily.
    queue :: Maybe Queue,
    -- | The function used for logging the solver's activity.
    log :: LBS.ByteString -> IO ()
  }

-- | Send a command in bytestring builder format to the solver.
sendSolver :: Solver -> Builder -> IO SExpr
sendSolver solver cmd = do
  log solver $ "[send] " <> toLazyByteString cmd
  resp <- send (backend solver) cmd
  case parseSExpr resp of
    Nothing -> do
      log solver $ "[error] failed to parse solver output:\n" <> resp
      fail $
        unlines ["Unexpected response from the SMT solver:", "parsing failed"]
    Just (expr, _) -> do
      log solver $ "[recv] " <> toLazyByteString (renderSExpr expr)
      return expr

-- | Create a new solver and initialize it with some options so that it behaves
-- correctly for our use.
-- In particular, the "print-success" option is disabled in lazy mode. This should
-- not be overriden manually.
initSolverWith ::
  Backend ->
  -- | whether to enable lazy mode. See 'Solver' for the meaning of this flag.
  Bool ->
  -- | function for logging the solver's activity
  (LBS.ByteString -> IO ()) ->
  IO Solver
initSolverWith solverBackend lazy logger = do
  solverQueue <-
    if lazy
      then do
        ref <- newIORef mempty
        return $ Just ref
      else return Nothing
  let solver = Solver solverBackend solverQueue logger
  if lazy
    then return ()
    else -- this should not be enabled when the queue is used, as it messes with parsing
    -- the outputs of commands that are actually interesting
    -- TODO checking for correctness and enabling laziness can be made compatible
    -- but it would require the solver backends to return list of s-expressions
    -- alternatively, we may consider that the user wanting both features should
    -- implement their own backend that deals with this
      setOption solver ":print-success" "true"
  setOption solver ":produce-models" "true"
  return solver

-- | Have the solver evaluate a command in SExpr format.
-- This forces the queued commands to be evaluated as well, but their results are
-- *not* checked for correctness.
command :: Solver -> SExpr -> IO SExpr
command solver expr = do
  let cmd = renderSExpr expr
  sendSolver solver
    =<< case queue solver of
      Nothing -> return $ cmd
      Just q -> (<> renderSExpr expr) <$> flushQueue q

-- | Load the contents of a file.
loadFile :: Solver -> FilePath -> IO ()
loadFile solver file =
  lazyByteString <$> LBS.readFile file >>= sendSolver solver >> return ()

-- | A command with no interesting result.
-- In eager mode, the result is checked for correctness.
-- In lazy mode, (unless the queue is flushed and evaluated
-- right after) the command must not produce any output when evaluated, and
-- its output is thus in particular not checked for correctness.
ackCommand :: Solver -> SExpr -> IO ()
ackCommand solver expr =
  case queue solver of
    Nothing -> do
      res <- sendSolver solver $ renderSExpr expr
      case res of
        Atom "success" -> return ()
        _ ->
          fail $
            unlines
              [ "Unexpected result from the SMT solver:",
                "  Expected: success",
                "  Result: " ++ showsSExpr res ""
              ]
    Just q -> putQueue q expr

-- | A command entirely made out of atoms, with no interesting result.
simpleCommand :: Solver -> [String] -> IO ()
simpleCommand proc = ackCommand proc . List . map Atom

-- | Run a command and return True if successful, and False if unsupported.
-- This is useful for setting options that unsupported by some solvers, but used
-- by others.
simpleCommandMaybe :: Solver -> [String] -> IO Bool
simpleCommandMaybe proc c =
  do
    res <- command proc (List (map Atom c))
    case res of
      Atom "success" -> return True
      Atom "unsupported" -> return False
      _ ->
        fail $
          unlines
            [ "Unexpected result from the SMT solver:",
              "  Expected: success or unsupported",
              "  Result: " ++ showsSExpr res ""
            ]

-- | Set a solver option.
setOption :: Solver -> String -> String -> IO ()
setOption s x y = simpleCommand s ["set-option", x, y]

-- | Set a solver option, returning False if the option is unsupported.
setOptionMaybe :: Solver -> String -> String -> IO Bool
setOptionMaybe s x y = simpleCommandMaybe s ["set-option", x, y]

-- | Set the solver's logic.  Usually, this should be done first.
setLogic :: Solver -> String -> IO ()
setLogic s x = simpleCommand s ["set-logic", x]

-- | Set the solver's logic, returning False if the logic is unsupported.
setLogicMaybe :: Solver -> String -> IO Bool
setLogicMaybe s x = simpleCommandMaybe s ["set-logic", x]

-- | Request unsat cores.  Returns if the solver supports them.
produceUnsatCores :: Solver -> IO Bool
produceUnsatCores s = setOptionMaybe s ":produce-unsat-cores" "true"

-- | Checkpoint state.  A special case of 'pushMany'.
push :: Solver -> IO ()
push proc = pushMany proc 1

-- | Restore to last check-point.  A special case of 'popMany'.
pop :: Solver -> IO ()
pop proc = popMany proc 1

-- | Push multiple scopes.
pushMany :: Solver -> Integer -> IO ()
pushMany proc n = simpleCommand proc ["push", show n]

-- | Pop multiple scopes.
popMany :: Solver -> Integer -> IO ()
popMany proc n = simpleCommand proc ["pop", show n]

-- | Execute the IO action in a new solver scope (push before, pop after)
inNewScope :: Solver -> IO a -> IO a
inNewScope s m =
  do
    push s
    m `X.finally` pop s

-- | Declare a constant.  A common abbreviation for 'declareFun'.
-- For convenience, returns an the declared name as a constant expression.
declare :: Solver -> String -> SExpr -> IO SExpr
declare proc f t = declareFun proc f [] t

-- | Declare a function or a constant.
-- For convenience, returns an the declared name as a constant expression.
declareFun :: Solver -> String -> [SExpr] -> SExpr -> IO SExpr
declareFun proc f as' r =
  do
    ackCommand proc $ fun "declare-fun" [Atom f, List as', r]
    return (const f)

-- | Declare an ADT using the format introduced in SmtLib 2.6.
declareDatatype ::
  Solver ->
  -- | datatype name
  String ->
  -- | sort parameters
  [String] ->
  -- | constructors
  [(String, [(String, SExpr)])] ->
  IO ()
declareDatatype proc t [] cs =
  ackCommand proc $
    fun "declare-datatype" $
      [ Atom t,
        List [List (Atom c : [List [Atom s, argTy] | (s, argTy) <- args]) | (c, args) <- cs]
      ]
declareDatatype proc t ps cs =
  ackCommand proc $
    fun "declare-datatype" $
      [ Atom t,
        fun "par" $
          [ List (map Atom ps),
            List [List (Atom c : [List [Atom s, argTy] | (s, argTy) <- args]) | (c, args) <- cs]
          ]
      ]

-- | Declare a constant.  A common abbreviation for 'declareFun'.
-- For convenience, returns the defined name as a constant expression.
define ::
  Solver ->
  -- | New symbol
  String ->
  -- | Symbol type
  SExpr ->
  -- | Symbol definition
  SExpr ->
  IO SExpr
define proc f t e = defineFun proc f [] t e

-- | Define a function or a constant.
-- For convenience, returns an the defined name as a constant expression.
defineFun ::
  Solver ->
  -- | New symbol
  String ->
  -- | Parameters, with types
  [(String, SExpr)] ->
  -- | Type of result
  SExpr ->
  -- | Definition
  SExpr ->
  IO SExpr
defineFun proc f as' t e =
  do
    ackCommand proc $
      fun "define-fun" $
        [Atom f, List [List [const x, a] | (x, a) <- as'], t, e]
    return (const f)

-- | Define a recursive function or a constant.  For convenience,
-- returns an the defined name as a constant expression.  This body
-- takes the function name as an argument.
defineFunRec ::
  Solver ->
  -- | New symbol
  String ->
  -- | Parameters, with types
  [(String, SExpr)] ->
  -- | Type of result
  SExpr ->
  -- | Definition
  (SExpr -> SExpr) ->
  IO SExpr
defineFunRec proc f as' t e =
  do
    let fs = const f
    ackCommand proc $
      fun "define-fun-rec" $
        [Atom f, List [List [const x, a] | (x, a) <- as'], t, e fs]
    return fs

-- | Define a recursive function or a constant.  For convenience,
-- returns an the defined name as a constant expression.  This body
-- takes the function name as an argument.
defineFunsRec ::
  Solver ->
  [(String, [(String, SExpr)], SExpr, SExpr)] ->
  IO ()
defineFunsRec proc ds = ackCommand proc $ fun "define-funs-rec" [decls, bodies]
  where
    oneArg (f, args, t, _) = List [Atom f, List [List [const x, a] | (x, a) <- args], t]
    decls = List (map oneArg ds)
    bodies = List (map (\(_, _, _, body) -> body) ds)

-- | Assume a fact.
assert :: Solver -> SExpr -> IO ()
assert proc e = ackCommand proc $ fun "assert" [e]

-- | Check if the current set of assertion is consistent.
check :: Solver -> IO Result
check proc = do
  res <- command proc (List [Atom "check-sat"])
  case res of
    Atom "unsat" -> return Unsat
    Atom "unknown" -> return Unknown
    Atom "sat" -> return Sat
    _ ->
      fail $
        unlines
          [ "Unexpected result from the SMT solver:",
            "  Expected: unsat, unknown, or sat",
            "  Result: " ++ showsSExpr res ""
          ]

-- | Get assignments.
-- Only valid after a 'Sat' result

-- | Get the values of some s-expressions.
-- Only valid after a 'Sat' result.
getExprs :: Solver -> [SExpr] -> IO [(SExpr, Value)]
getExprs proc vals =
  do
    res <- command proc $ List [Atom "get-value", List vals]
    case res of
      List xs -> mapM getAns xs
      _ ->
        fail $
          unlines
            [ "Unexpected response from the SMT solver:",
              "  Exptected: a list",
              "  Result: " ++ showsSExpr res ""
            ]
  where
    getAns expr =
      case expr of
        List [e, v] -> return (e, sexprToVal v)
        _ ->
          fail $
            unlines
              [ "Unexpected response from the SMT solver:",
                "  Expected: (expr val)",
                "  Result: " ++ showsSExpr expr ""
              ]

-- | Get the values of some constants in the current model.
-- A special case of 'getExprs'.
-- Only valid after a 'Sat' result.
getConsts :: Solver -> [String] -> IO [(String, Value)]
getConsts proc xs =
  do
    ans <- getExprs proc (map Atom xs)
    return [(x, e) | (Atom x, e) <- ans]

-- | Get the value of a single expression.
getExpr :: Solver -> SExpr -> IO Value
getExpr proc x =
  do
    [(_, v)] <- getExprs proc [x]
    return v

-- | Get the value of a single constant.
getConst :: Solver -> String -> IO Value
getConst proc x = getExpr proc (Atom x)

-- | Returns the names of the (named) formulas involved in a contradiction.
getUnsatCore :: Solver -> IO [String]
getUnsatCore s =
  do
    res <- command s $ List [Atom "get-unsat-core"]
    case res of
      List xs -> mapM fromAtom xs
      _ -> unexpected "a list of atoms" res
  where
    fromAtom x =
      case x of
        Atom a -> return a
        _ -> unexpected "an atom" x

    unexpected x e =
      fail $
        unlines
          [ "Unexpected response from the SMT Solver:",
            "  Expected: " ++ x,
            "  Result: " ++ showsSExpr e ""
          ]
