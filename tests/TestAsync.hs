module Main where

import Test.Framework (Test, defaultMain, testGroup)
import qualified Network.Transport as NT
import Network.Transport.TCP
import TestAsyncChan
import TestAsyncSTM
import TestUtils

allAsyncTests :: NT.Transport -> IO [Test]
allAsyncTests transport = do
  chanTestGroup <- asyncChanTests transport
  stmTestGroup  <- asyncStmTests transport
  return [
       testGroup "AsyncChan" chanTestGroup
     , testGroup "AsyncSTM" stmTestGroup ]

main :: IO ()
main = testMain $ allAsyncTests
