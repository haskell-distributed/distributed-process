{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DeriveDataTypeable #-}

import System.Environment
import Control.Monad
import Control.Applicative
import Control.Distributed.Process
import Control.Distributed.Process.Node
import Network.Transport.TCP (createTransport, defaultTCPParameters)
import Data.Binary
import qualified Data.ByteString.Lazy as BSL
import Data.Typeable

data SizedList a = SizedList { size :: Int , elems :: [a] }
  deriving (Typeable)

instance Binary a => Binary (SizedList a) where
  put (SizedList sz xs) = put sz >> mapM_ put xs
  get = do
    sz <- get
    xs <- getMany sz
    return (SizedList sz xs)

-- Copied from Data.Binary
getMany :: Binary a => Int -> Get [a]
getMany = go []
 where
    go xs 0 = return $! reverse xs
    go xs i = do x <- get
                 x `seq` go (x:xs) (i-1)
{-# INLINE getMany #-}

nats :: Int -> SizedList Int
nats = \n -> SizedList n (aux n)
  where
    aux 0 = []
    aux n = n : aux (n - 1)

counter :: Process ()
counter = go 0
  where
    go :: Int -> Process ()
    go !n =
      receiveWait
        [ match $ \xs   -> go (n + size (xs :: SizedList Int))
        , match $ \them -> send them n >> go 0
        ]

count :: (Int, Int) -> ProcessId -> Process ()
count (packets, sz) them = do
  us <- getSelfPid
  replicateM_ packets $ send them (nats sz)
  send them us
  n' <- expect
  liftIO $ print (packets * sz, n' == packets * sz)

initialProcess :: String -> Process ()
initialProcess "SERVER" = do
  us <- getSelfPid
  liftIO $ BSL.writeFile "counter.pid" (encode us)
  counter
initialProcess "CLIENT" = do
  n <- liftIO getLine
  them <- liftIO $ decode <$> BSL.readFile "counter.pid"
  count (read n) them

main :: IO ()
main = do
  [role, host, port] <- getArgs
  Right transport <- createTransport host port defaultTCPParameters
  node <- newLocalNode transport initRemoteTable
  runProcess node $ initialProcess role
