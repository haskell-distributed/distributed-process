{-# LANGUAGE Arrows #-}
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
    List AzureOptions
  | Start AzureOptions SshOptions String
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

startParser :: Parser Command
startParser = Start 
  <$> azureOptionsParser
  <*> sshOptionsParser
  <*> strOption ( long "vm"
                & metavar "VM"
                & help "Virtual machine name"
                )

commandParser :: Parser Command
commandParser = subparser
  ( command "list"  (info listParser 
      (progDesc "List Azure cloud services"))
  & command "start" (info startParser
      (progDesc "Start a new Cloud Haskell node"))
  )

--------------------------------------------------------------------------------
-- Main                                                                       -- 
--------------------------------------------------------------------------------

main :: IO ()
main = do 
    cmd <- execParser opts
    case cmd of
      List azureOpts -> do
        params <- azureParameters azureOpts Nothing
        backend <- initializeBackend params 
        css <- cloudServices backend
        mapM_ print css
      Start azureOpts sshOpts name -> do
        params <- azureParameters azureOpts (Just sshOpts)
        backend <- initializeBackend params
        css <- cloudServices backend
        let ch = head [ vm | vm <- concatMap cloudServiceVMs css
                           , vmName vm == name 
                      ]
        print ch                
        startOnVM backend ch
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
