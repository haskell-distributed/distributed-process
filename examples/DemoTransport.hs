{-# LANGUAGE NamedFieldPuns #-}
module Main where

import Network.Transport 
import qualified Network.Transport.MVar  
import qualified Network.Transport.Pipes 
import Network.Transport.TCP (mkTransport, TCPConfig (..))

import Control.Concurrent
import Control.Monad

-- import qualified Data.ByteString.Lazy.Char8 as BS
import qualified Data.ByteString.Char8 as BS

import Data.IORef
import Debug.Trace

-------------------------------------------

{- Run a demo above with one of these tranpsort shorthands like this:
   tcp >>= demo0
 -}
tcp   = mkTCPOff 8080
mvar  = return Network.Transport.MVar.mkTransport
pipes = return Network.Transport.Pipes.mkTransport

tcp   :: IO (IO Transport)
mvar  :: IO (IO Transport)
pipes :: IO (IO Transport)

-------------------------------------------
-- Example programs using backend directly


-- | Check if multiple messages can be sent on the same connection.
demo0 :: IO Transport -> IO ()
demo0 mktrans = do
  trans <- mktrans

  (sourceAddr, targetEnd) <- newConnection trans

  forkIO $ logServer "logServer" targetEnd
  threadDelay 100000

  sourceEnd <- connect sourceAddr

  mapM_ (\n -> send sourceEnd [BS.pack ("hello " ++ show n)]) [1 .. 10]
  threadDelay 100000

  closeTransport trans


-- | Check endpoint serialization and deserialization.
demo1 :: IO Transport -> IO ()
demo1 mktrans = do
  trans <- mktrans

  (sourceAddr, targetEnd) <- newConnection trans

  forkIO $ logServer "logServer" targetEnd
  threadDelay 100000

  sourceEnd <- connect sourceAddr

  -- This use of Just is slightly naughty
  let Just sourceAddr' = deserialize trans (serialize sourceAddr)
  sourceEnd' <- connect sourceAddr'

  send sourceEnd  [BS.pack "hello 1"]
  send sourceEnd' [BS.pack "hello 2"]
  threadDelay 100000
  closeTransport trans


-- | Check that messages can be sent before receive is set up.
demo2 :: IO Transport -> IO ()
demo2 mktrans = do
  trans <- mktrans

  (sourceAddr, targetEnd) <- newConnection trans
  sourceEnd <- connect sourceAddr

  forkIO $ send sourceEnd [BS.pack "hello 1"]
  threadDelay 100000

  forkIO $ logServer "logServer" targetEnd
  threadDelay 100000
  closeTransport trans


-- | Check that two different transports can be created.
demo3 :: IO Transport -> IO ()
demo3 mktrans = do
  trans1 <- mktrans 
  trans2 <- mktrans 

  (sourceAddr1, targetEnd1) <- newConnection trans1
  (sourceAddr2, targetEnd2) <- newConnection trans2

  threadId1 <- forkIO $ logServer "logServer1" targetEnd1
  threadId2 <- forkIO $ logServer "logServer2" targetEnd2

  sourceEnd1 <- connect sourceAddr1
  sourceEnd2 <- connect sourceAddr2

  send sourceEnd1 [BS.pack "hello1"]
  send sourceEnd2 [BS.pack "hello2"]

  threadDelay 100000
  putStrLn "demo3: Time, up, killing threads & closing transports.." 
  killThread threadId1
  killThread threadId2
  putStrLn "demo3: Threads killed." 
  closeTransport trans1
  closeTransport trans2
  putStrLn "demo3: Done." 


-- | Check that two different connections on the same transport can be created.
demo4 :: IO Transport -> IO ()
demo4 mktrans = do
  trans <- mktrans

  (sourceAddr1, targetEnd1) <- newConnection trans
  (sourceAddr2, targetEnd2) <- newConnection trans

  threadId1 <- forkIO $ logServer "logServer1" targetEnd1
  threadId2 <- forkIO $ logServer "logServer2" targetEnd2

  sourceEnd1 <- connect sourceAddr1
  sourceEnd2 <- connect sourceAddr2

  send sourceEnd1 [BS.pack "hello1"]
  send sourceEnd2 [BS.pack "hello2"]

  threadDelay 100000

  putStrLn "demo4: Time, up, killing threads & closing transports.." 
  killThread threadId1
  killThread threadId2
  putStrLn "demo4: Threads killed." 
  closeTransport trans
  putStrLn "demo4: Done." 



--------------------------------------------------------------------------------

logServer :: String -> TargetEnd -> IO ()
logServer name targetEnd = forever $ do
  x <- receive targetEnd
  trace (name ++ " rcvd: " ++ show x) $ return ()

mkTCPOff off = do 
  cntr <- newIORef 0
  return$ do cnt <- readIORef cntr
	     writeIORef cntr (cnt+1)
	     mkTransport (TCPConfig undefined "127.0.0.1" (show (off + cnt)))

--------------------------------------------------------------------------------

runWAllTranports :: (IO Transport -> IO ()) -> Int -> IO ()
runWAllTranports demo offset = do
   putStrLn "------------------------------------------------------------"
{-
   putStrLn "   MVAR transport:"
   mvar >>= demo
   putStrLn "\n   TCP transport:"   
   tcp >>= demo
-}
   putStrLn "\n   PIPES transport:"
   pipes >>= demo
   putStrLn "\n"


main = do 
   putStrLn "Demo0:"
   runWAllTranports demo0 0
   putStrLn "Demo1:"
   runWAllTranports demo1 10
   putStrLn "Demo2:"
   runWAllTranports demo2 20
   putStrLn "Demo3:"
   runWAllTranports demo3 30
   putStrLn "Demo4:"
   runWAllTranports demo4 40

   threadDelay (300 * 1000)
   putStrLn "Done with all demos!"
