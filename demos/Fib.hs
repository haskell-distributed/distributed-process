{-# LANGUAGE TemplateHaskell #-}
import System.Environment (getArgs)
import System.Random (randomIO)
import Control.Monad (forM)
import Control.Monad.IO.Class (liftIO)
import Control.Distributed.Process
  ( Process
  , NodeId
  , SendPort
  , newChan
  , sendChan
  , spawn
  , receiveChan
  , spawnLocal
  )
import Control.Distributed.Process.Backend.Azure
import Control.Distributed.Process.Closure
  ( remotable
  , remotableDecl
  , mkClosure
  )

randomElement :: [a] -> IO a
randomElement xs = do
  ix <- randomIO
  return (xs !! (ix `mod` length xs))

remotableDecl [
    [d| dfib :: ([NodeId], SendPort Integer, Integer) -> Process () ;
        dfib (_, reply, 0) = sendChan reply 0
        dfib (_, reply, 1) = sendChan reply 1
        dfib (nids, reply, n) = do
          nid1 <- liftIO $ randomElement nids
          nid2 <- liftIO $ randomElement nids
          (sport, rport) <- newChan
          _ <- spawn nid1 $ $(mkClosure 'dfib) (nids, sport, n - 2)
          _ <- spawn nid2 $ $(mkClosure 'dfib) (nids, sport, n - 1)
          n1 <- receiveChan rport
          n2 <- receiveChan rport
          sendChan reply $ n1 + n2
      |]
  ]

remoteFib :: ([NodeId], Integer) -> Backend -> Process ()
remoteFib (nids, n) _backend = do
  (sport, rport) <- newChan
  _ <- spawnLocal $ dfib (nids, sport, n)
  fib_n <- receiveChan rport
  mapM_ terminateNode nids
  remoteSend fib_n

remotable ['remoteFib]

printResult :: LocalProcess ()
printResult = do
  result <- localExpect :: LocalProcess Integer
  liftIO $ print result

main :: IO ()
main = do
  args <- getArgs
  case args of
    "onvm":args' -> onVmMain (__remoteTable . __remoteTableDecl) args'
    [sid, x509, pkey, user, cloudService, n] -> do
      params <- defaultAzureParameters sid x509 pkey
      let params' = params { azureSshUserName = user }
      backend <- initializeBackend params' cloudService
      vms <- findVMs backend
      nids <- forM vms $ \vm -> spawnNodeOnVM backend vm "8080"
      callOnVM backend (head vms) "8081" $
        ProcessPair ($(mkClosure 'remoteFib) (nids, read n :: Integer))
                    printResult
    _ ->
      error "Invalid command line arguments"
