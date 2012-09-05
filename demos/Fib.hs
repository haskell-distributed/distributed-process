{-# LANGUAGE TemplateHaskell #-}
import System.Environment (getArgs)
import System.Random (randomIO)
import Data.Binary (encode)
import Data.ByteString.Lazy (ByteString)
import Control.Monad (forM)
import Control.Monad.IO.Class (liftIO)
import Control.Distributed.Process
  ( Process
  , NodeId
  , SendPort
  , newChan
  , sendChan
  , Closure
  , spawn
  , receiveChan
  , spawnLocal
  )
import Control.Distributed.Process.Closure 
  ( SerializableDict(SerializableDict)
  , staticDecode
  )
import Control.Distributed.Process.Backend.Azure 
import Control.Distributed.Static 
  ( Static
  , staticLabel
  , closure
  , RemoteTable
  , registerStatic
  , staticCompose
  )
import Data.Rank1Dynamic (toDynamic)  
import Control.Distributed.Process.Closure (remotable, mkClosure)
import qualified Language.Haskell.TH as TH

randomElement :: [a] -> IO a
randomElement xs = do
  ix <- randomIO
  return (xs !! (ix `mod` length xs))

f :: [TH.Name] -> TH.Q [TH.Dec]
f = remotable

remotableDec :: [TH.Dec] -> TH.Q [TH.Dec]
remotableDec = undefined

remotableDec [ [d| f :: Int  |] ]

main :: IO ()
main = undefined

--------------------------------------------------------------------------------
-- Auxiliary                                                                  --
--------------------------------------------------------------------------------



{-

--------------------------------------------------------------------------------
-- Distributed Fibonacci                                                      --
--------------------------------------------------------------------------------

dfib :: ([NodeId], Integer, SendPort Integer) -> Process () 
dfib (_, 0, reply) = sendChan reply 0
dfib (_, 1, reply) = sendChan reply 1
dfib (nids, n, reply) = do
  nid1 <- liftIO $ randomElement nids
  nid2 <- liftIO $ randomElement nids
  (sport, rport) <- newChan
  spawn nid1 $ dfibClosure nids (n - 2) sport
  spawn nid2 $ dfibClosure nids (n - 1) sport
  n1 <- receiveChan rport
  n2 <- receiveChan rport
  sendChan reply $ n1 + n2

remoteFib :: ([NodeId], Integer) -> Backend -> Process ()
remoteFib (nids, n) _backend = do
  (sport, rport) <- newChan
  spawnLocal $ dfib (nids, n, sport)
  fib_n <- receiveChan rport
  remoteSend fib_n

printResult :: LocalProcess ()
printResult = do
  result <- localExpect :: LocalProcess Integer
  liftIO $ print result 

main :: IO ()
main = do
  args <- getArgs
  case args of
    "onvm":args' -> onVmMain __remoteTable args'
    [sid, x509, pkey, user, cloudService, n] -> do
      params <- defaultAzureParameters sid x509 pkey 
      let params' = params { azureSshUserName = user }
      backend <- initializeBackend params' cloudService
      vms <- findVMs backend
      nids <- forM vms $ \vm -> spawnNodeOnVM backend vm "8080"
      callOnVM backend (head vms) "8081" $ 
        ProcessPair (remoteFibClosure nids (read n)) printResult 
    _ ->
      error "Invalid command line arguments"

--------------------------------------------------------------------------------
-- Static plumping                                                            --
--------------------------------------------------------------------------------

dfibStatic :: Static (([NodeId], Integer, SendPort Integer) -> Process ())
dfibStatic = staticLabel "dfib"

dfibDict :: Static (SerializableDict ([NodeId], Integer, SendPort Integer))
dfibDict = staticLabel "dfibDict"

dfibClosure :: [NodeId] -> Integer -> SendPort Integer -> Closure (Process ())
dfibClosure nids n reply = closure decoder (encode (nids, n, reply))
  where
    decoder :: Static (ByteString -> Process ())
    decoder = dfibStatic `staticCompose` staticDecode dfibDict 

remoteFibStatic :: Static (([NodeId], Integer) -> Backend -> Process ()) 
remoteFibStatic = staticLabel "remoteFib"

remoteFibDict :: Static (SerializableDict ([NodeId], Integer))
remoteFibDict = staticLabel "remoteFibDict"

remoteFibClosure :: [NodeId] -> Integer -> RemoteProcess ()
remoteFibClosure nids n = closure decoder (encode (nids, n))
  where
    decoder :: Static (ByteString -> Backend -> Process ())
    decoder = remoteFibStatic `staticCompose` staticDecode remoteFibDict 

__remoteTable :: RemoteTable -> RemoteTable
__remoteTable = 
    registerStatic "dfib"          (toDynamic dfib)
  . registerStatic "dfibDict"      (toDynamic (SerializableDict :: SerializableDict ([NodeId], Integer, SendPort Integer)))
  . registerStatic "remoteFib"     (toDynamic remoteFib)
  . registerStatic "remoteFibDict" (toDynamic (SerializableDict :: SerializableDict ([NodeId], Integer)))

-}
