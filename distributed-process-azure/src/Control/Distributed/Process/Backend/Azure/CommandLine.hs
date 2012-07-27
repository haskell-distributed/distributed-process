import System.Environment (getArgs)
import Control.Distributed.Process.Backend.Azure 
  ( AzureParameters(azureSshUserName)
  , defaultAzureParameters
  , initializeBackend 
  , cloudServices 
  , CloudService(cloudServiceVMs)
  , VirtualMachine(vmName)
  , startOnVM
  )

main :: IO ()
main = do
  [subscriptionId, pathToCert, pathToKey, user] <- getArgs
  tryConnectToAzure subscriptionId pathToCert pathToKey user

tryConnectToAzure :: String -> String -> String -> String -> IO ()
tryConnectToAzure sid pathToCert pathToKey user = do
  params  <- defaultAzureParameters sid pathToCert pathToKey
  backend <- initializeBackend params { azureSshUserName = user }
  css     <- cloudServices backend 
  let ch = head [ vm | vm <- concatMap cloudServiceVMs css
                     , vmName vm == "CloudHaskell"  
                ]
  print ch                
  startOnVM backend ch
