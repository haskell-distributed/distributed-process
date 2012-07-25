-- Base
import Control.Monad (forM_)
import System.Environment (getArgs, getEnv)
import System.FilePath ((</>))
import System.Posix.Types (Fd)

-- SSL
import Network.Azure.ServiceManagement 
  ( azureSetup
  , hostedServices
  , hostedServiceProperties
  )

-- SSH
import Network.SSH.Client.LibSSH2 
  ( withSSH2
  , readAllChannel
  , retryIfNeeded
  , Session
  , Channel
  )
import Network.SSH.Client.LibSSH2.Foreign 
  ( initialize
  , exit
  , channelExecute
  )
import Codec.Binary.UTF8.String (decodeString)

main :: IO ()
main = do
  args <- getArgs
  case args of
    ["azure", subscriptionId, pathToCert, pathToKey] ->
      tryConnectToAzure subscriptionId pathToCert pathToKey
    ["command", user, host, port, cmd] -> 
      runCommand user host (read port) cmd
    _ ->
      putStrLn "Invalid command line arguments"

--------------------------------------------------------------------------------
-- Taken from libssh2/ssh-client                                              --
--------------------------------------------------------------------------------

runCommand :: String -> String -> Int -> String -> IO ()
runCommand login host port command =
  ssh login host port $ \fd s ch -> do
      _ <- retryIfNeeded fd s $ channelExecute ch command
      result <- readAllChannel fd ch
      let r = decodeString result
      print (length result)
      print (length r)
      putStrLn r

ssh :: String -> String -> Int -> (Fd -> Session -> Channel -> IO a) -> IO ()
ssh login host port actions = do
  _ <- initialize True
  home <- getEnv "HOME"
  let known_hosts = home </> ".ssh" </> "known_hosts"
      public = home </> ".ssh" </> "id_rsa.pub"
      private = home </> ".ssh" </> "id_rsa"
  _ <- withSSH2 known_hosts public private login host port $ actions
  exit

--------------------------------------------------------------------------------
-- Taken from tls-debug/src/SimpleClient.hs                                   --
--------------------------------------------------------------------------------

tryConnectToAzure :: String -> String -> String -> IO ()
tryConnectToAzure sid pathToCert pathToKey = do
  setup <- azureSetup sid pathToCert pathToKey
  services <- hostedServices setup
  mapM_ print services 
  forM_ services $ \service -> do
    props <- hostedServiceProperties setup service
    print props

