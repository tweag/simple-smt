{-# LANGUAGE OverloadedStrings #-}

module SimpleSMT.Tests.SExpr (tests) where

import Control.Monad (zipWithM_)
import qualified Data.ByteString.Lazy.Char8 as LBS
import Data.List (unfoldr)
import qualified SimpleSMT.SExpr as SExpr
import qualified SimpleSMT.Tests.Sources as Src
import Test.Tasty
import Test.Tasty.HUnit

tests :: TestTree
tests =
  testGroup
    "SExpr"
    [ testGroup
        "Parsing"
        [ -- testParser "from Strings" $ unfoldr SExpr.readSExpr,
          -- ^^ TODO Either fix it or abandon SExpressions
          testParser "from ByteStrings" $ unfoldr SExpr.parseSExpr . LBS.pack
        ]
    ]

testParser :: String -> (String -> [SExpr.SExpr]) -> TestTree
testParser name parse = testGroup name $ do
  source <- Src.sources
  return $
    testCase (Src.name source) $ do
      let expecteds = Src.parse source
          gots = parse $ Src.content source
      zipWithM_
        ( \expected got ->
            assertBool
              ("  parsed:   '" ++ show got ++ "\n  expected: '" ++ show expected)
              $ expected == got
        )
        expecteds
        gots
      let numExpected = length expecteds
          numGot = length gots
      assertBool
        ( "parsed "
            ++ show numGot
            ++ " expressions but expected "
            ++ show numExpected
        )
        $ numExpected == numGot
