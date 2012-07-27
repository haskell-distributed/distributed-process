import System.Environment (getArgs, getEnv)
import System.FilePath ((</>))
import System.Posix.Types (Fd)
import Control.Distributed.Process.Backend.Azure 
  ( defaultAzureParameters
  , initializeBackend 
  , findVMs
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
-- Azure tests                                                                -- 
--------------------------------------------------------------------------------

tryConnectToAzure :: String -> String -> String -> IO ()
tryConnectToAzure sid pathToCert pathToKey = do
  params  <- defaultAzureParameters sid pathToCert pathToKey
  backend <- initializeBackend params
  vms     <- findVMs backend 
  mapM_ print vms 
