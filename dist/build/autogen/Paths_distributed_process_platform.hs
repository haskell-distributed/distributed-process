module Paths_distributed_process_platform (
    version,
    getBinDir, getLibDir, getDataDir, getLibexecDir,
    getDataFileName
  ) where

import qualified Control.Exception as Exception
import Data.Version (Version(..))
import System.Environment (getEnv)
catchIO :: IO a -> (Exception.IOException -> IO a) -> IO a
catchIO = Exception.catch


version :: Version
version = Version {versionBranch = [0,1,0], versionTags = []}
bindir, libdir, datadir, libexecdir :: FilePath

bindir     = "/Users/t4/Library/Haskell/ghc-7.4.2/lib/distributed-process-platform-0.1.0/bin"
libdir     = "/Users/t4/Library/Haskell/ghc-7.4.2/lib/distributed-process-platform-0.1.0/lib"
datadir    = "/Users/t4/Library/Haskell/ghc-7.4.2/lib/distributed-process-platform-0.1.0/share"
libexecdir = "/Users/t4/Library/Haskell/ghc-7.4.2/lib/distributed-process-platform-0.1.0/libexec"

getBinDir, getLibDir, getDataDir, getLibexecDir :: IO FilePath
getBinDir = catchIO (getEnv "distributed_process_platform_bindir") (\_ -> return bindir)
getLibDir = catchIO (getEnv "distributed_process_platform_libdir") (\_ -> return libdir)
getDataDir = catchIO (getEnv "distributed_process_platform_datadir") (\_ -> return datadir)
getLibexecDir = catchIO (getEnv "distributed_process_platform_libexecdir") (\_ -> return libexecdir)

getDataFileName :: FilePath -> IO FilePath
getDataFileName name = do
  dir <- getDataDir
  return (dir ++ "/" ++ name)
