{-# LANGUAGE BangPatterns, TemplateHaskell #-}

import Control.Monad
import Control.Applicative
import Control.Monad.IO.Class (liftIO)
import qualified Data.ByteString.Lazy as BSL
import Data.Binary (encode, decode)
import Remote

counter :: ProcessM ()
counter = go 0
  where
    go :: Int -> ProcessM ()
    go !n = do
      b <- expect
      case b of
        Nothing   -> go (n + 1)
        Just them -> send them n >> go 0

count :: Int -> ProcessId -> ProcessM ()
count n them = do
  us <- getSelfPid
  replicateM_ n $ send them (Nothing :: Maybe ProcessId)
  send them (Just us)
  n' <- expect
  liftIO $ print (n == n')

initialProcess :: String -> ProcessM ()
initialProcess "SERVER" = do
  us <- getSelfPid
  liftIO $ BSL.writeFile "counter.pid" (encode us)
  counter
initialProcess "CLIENT" = do
  n <- liftIO $ getLine
  them <- liftIO $ decode <$> BSL.readFile "counter.pid"
  count (read n) them

main :: IO ()
main = remoteInit (Just "config") [] initialProcess
