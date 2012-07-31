{-# LANGUAGE Arrows #-}
import System.Environment (getArgs)
import System.Exit (exitSuccess, exitFailure)
import Control.Monad (unless)
import Control.Distributed.Process.Backend.Azure 
  ( AzureParameters(azureSshUserName)
  , defaultAzureParameters
  , initializeBackend 
  , cloudServices 
  , CloudService(cloudServiceVMs)
  , VirtualMachine(vmName)
  , Backend(copyToVM, checkMD5)
  )
import Control.Arrow (returnA)
import Control.Applicative ((<$>), (<*>))
import Options.Applicative 
  ( Parser
  , strOption
  , long
  , (&)
  , metavar
  , help
  , subparser
  , command
  , info
  , progDesc 
  , execParser
  , helper
  , fullDesc
  , header
  , switch
  )
import Options.Applicative.Arrows (runA, asA)

--------------------------------------------------------------------------------
-- Command line options                                                       --
--------------------------------------------------------------------------------

data AzureOptions = AzureOptions {
    subscriptionId :: String
  , pathToCert     :: FilePath
  , pathToKey      :: FilePath
  }
  deriving Show

data SshOptions = SshOptions {
    remoteUser :: String
  }
  deriving Show

data Command = 
    List { 
        azureOptions   :: AzureOptions 
      }
  | CopyTo { 
        azureOptions   :: AzureOptions 
      , sshOptions     :: SshOptions 
      , virtualMachine :: String 
      }
  | CheckMD5 {
        azureOptions   :: AzureOptions
      , sshOptions     :: SshOptions 
      , virtualMachine :: String
      , status         :: Bool
      } 
  deriving Show

azureOptionsParser :: Parser AzureOptions
azureOptionsParser = AzureOptions 
  <$> strOption ( long "subscription-id"
                & metavar "SID" 
                & help "Azure subscription ID"
                )
  <*> strOption ( long "certificate"
                & metavar "CERT"
                & help "X509 certificate"
                )
  <*> strOption ( long "private"
                & metavar "PRI"
                & help "Private key in PKCS#1 format"
                )

sshOptionsParser :: Parser SshOptions
sshOptionsParser = SshOptions 
  <$> strOption ( long "user"
                & metavar "USER"
                & help "Remove SSH username"
                )

listParser :: Parser Command
listParser = List <$> azureOptionsParser

copyToParser :: Parser Command
copyToParser = CopyTo 
  <$> azureOptionsParser
  <*> sshOptionsParser
  <*> strOption ( long "vm"
                & metavar "VM"
                & help "Virtual machine name"
                )

checkMD5Parser :: Parser Command
checkMD5Parser = CheckMD5 
  <$> azureOptionsParser
  <*> sshOptionsParser
  <*> strOption ( long "vm"
                & metavar "VM"
                & help "Virtual machine name"
                )
  <*> switch ( long "status"
             & help "Don't output anything, status code shows success"
             )

commandParser :: Parser Command
commandParser = subparser
  ( command "list"  (info listParser 
      (progDesc "List Azure cloud services"))
  & command "install" (info copyToParser
      (progDesc "Install the executable on a virtual machine"))
  & command "md5" (info checkMD5Parser 
      (progDesc "Check if the remote and local MD5 hash match"))
  )

--------------------------------------------------------------------------------
-- Main                                                                       -- 
--------------------------------------------------------------------------------

main :: IO ()
main = do 
    cmd <- execParser opts
    case cmd of
      List {} -> do
        params <- azureParameters (azureOptions cmd) Nothing
        backend <- initializeBackend params 
        css <- cloudServices backend
        mapM_ print css
      CopyTo {} -> do
        params <- azureParameters (azureOptions cmd) (Just (sshOptions cmd))
        backend <- initializeBackend params
        css <- cloudServices backend
        let ch = head [ vm | vm <- concatMap cloudServiceVMs css
                           , vmName vm == virtualMachine cmd 
                      ]
        print ch                
        copyToVM backend ch
      CheckMD5 {} -> do
        params <- azureParameters (azureOptions cmd) (Just (sshOptions cmd))
        backend <- initializeBackend params
        css <- cloudServices backend
        let ch = head [ vm | vm <- concatMap cloudServiceVMs css
                           , vmName vm == virtualMachine cmd 
                      ]
        match <- checkMD5 backend ch
        if match
          then do
            unless (status cmd) $ 
              putStrLn "Local and remote MD5 hash match"
            exitSuccess
          else do
            unless (status cmd) $ 
              putStrLn "Local and remote MD5 hash do NOT match"
            exitFailure
  where
    opts = info (helper <*> commandParser)
      ( fullDesc 
      & header "Cloud Haskell backend for Azure"
      )

azureParameters :: AzureOptions -> Maybe SshOptions -> IO AzureParameters
azureParameters opts Nothing = 
  defaultAzureParameters (subscriptionId opts)
                         (pathToCert opts)
                         (pathToKey opts)
azureParameters opts (Just sshOpts) = do
  params <- defaultAzureParameters (subscriptionId opts)
                         (pathToCert opts)
                         (pathToKey opts)
  return params { 
      azureSshUserName = remoteUser sshOpts
    }
