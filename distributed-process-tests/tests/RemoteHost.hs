{-# LANGUAGE ScopedTypeVariables #-}

import Control.Monad
import Control.Distributed.Process hiding (catch)
import Control.Distributed.Process.Node
-- NB: we import the test suite module here, so we can take advantage of static
-- pointers to simplify the test suite considerably..
import Control.Distributed.Process.Tests.RemoteNodes hiding (remoteTable)
import qualified Control.Distributed.Process.Tests.RemoteNodes as R (remoteTable)
import Control.Exception (catch, SomeException)
import Network.Transport.TCP
  ( createTransport
  , defaultTCPParameters
  , defaultTCPAddr
  , TCPParameters(..)
  )

initialProcess :: Process ()
initialProcess = do
  self <- getSelfPid
  register "distributed-process-tests" self
  receiveWait [ matchIf (== self) (const $ return ()) ]

main :: IO ()
main = do
  nt <- createTransport (defaultTCPAddr "127.0.0.1" "10516" )
                        (defaultTCPParameters { tcpNoDelay = True })
  case nt of
    Right transport -> do node <- newLocalNode transport $ R.remoteTable initRemoteTable
                          catch (void $ runProcess node initialProcess)
                                (\(e :: SomeException) -> putStrLn $ "ERROR: " ++ show e)
    _               -> error "Unable to initialise network-transport"
