{-# LANGUAGE BangPatterns, CPP, ScopedTypeVariables, PackageImports #-}

module Network.Transport.Pipes
  ( mkTransport
  ) where

import Control.Monad (when, unless)
import Control.Concurrent.MVar
import Control.Concurrent (threadDelay, forkOS)
import Data.IntMap (IntMap)
-- import Data.ByteString.Char8 (ByteString)
import Data.Word
import Data.Int
import Data.IORef
import qualified Data.IntMap as IntMap
-- import qualified Data.ByteString.Char8 as BS
import qualified Data.ByteString.Lazy.Char8 as BS

import Data.Binary (encode,decode)
-- import Data.Serialize (encode,decode)
import Data.List (foldl')
import Network.Transport
import System.Random (randomIO)
import System.IO     (IOMode(ReadMode,AppendMode,WriteMode,ReadWriteMode), 
		      openFile, hClose, hPutStrLn, hPutStr, stderr, stdout)
import System.Posix.Files (createNamedPipe, unionFileModes, ownerReadMode, ownerWriteMode)
import System.Posix.Types (Fd)

#ifdef USE_UNIX_BYTESTRING
import qualified "unix-bytestring" System.Posix.IO.ByteString as PIO
import System.Posix.IO as PIO (openFd, defaultFileFlags, OpenMode(ReadWrite, WriteOnly)) 
(fromS,toS)  = (BS.pack, BS.unpack)
(fromBS,toBS) = (id,id)
readit fd n = PIO.fdRead fd n
#else
import qualified System.Posix.IO            as PIO
(toS,fromS)  = (id,id)
(fromBS,toBS) = (BS.unpack, BS.pack)
readit fd n = do (s,_) <- PIO.fdRead fd n
		 return (BS.pack s)
#endif

----------------------------------------------------------------------------------------------------

-- The msg header consists of just a length field represented as a Word32
sizeof_header = 4

mkTransport :: IO Transport
mkTransport = do
  uid <- randomIO :: IO Word64
  lock <- newMVar ()
  let filename = "/tmp/pipe_"++show uid
  createNamedPipe filename $ unionFileModes ownerReadMode ownerWriteMode

  dbgprint1$ "  Created pipe at location: "++ filename

  return Transport
    { newConnectionWith = \ _ -> do
        dbgprint1$ "  Creating new connection"
        return (mkSourceAddr filename, 
		mkTargetEnd filename lock)
    , newMulticastWith = error "Pipes.hs: newMulticastWith not implemented yet"
    , deserialize = \bs -> return$ mkSourceAddr (BS.unpack bs)
    }
  where
    mkSourceAddr :: String -> SourceAddr
    mkSourceAddr filename = SourceAddr
      { connectWith = \_ -> mkSourceEnd filename
      , serialize   = BS.pack filename
      }

    mkSourceEnd :: String -> IO SourceEnd
    mkSourceEnd filename = do
      -- Initiate but do not block on file opening:
      -- Note: Linux fifo semantics are NOT to block on open-RW, but this is not Posix standard.
      --
      -- We may protect from blocking other threads by running on a separate (OS) thread:
--      mv <- onOSThread$ PIO.openFd filename PIO.ReadWrite Nothing PIO.defaultFileFlags
--      fd <- PIO.openFd filename PIO.ReadWrite Nothing PIO.defaultFileFlags
      fd <- PIO.openFd filename PIO.WriteOnly Nothing PIO.defaultFileFlags

      return $ 
      -- Write to the named pipe.  If the message is less than
      -- PIPE_BUF (4KB on linux) then this should be atomic, otherwise
      -- we have to do something more sophisticated.
        SourceEnd
        { send = \bss -> do
            dbgprint1$ "SENDING ... "++ show bss

	    -- This may happen on multiple processes/threads:
	    let msgsize :: Word32 = fromIntegral$ foldl' (\n s -> n + BS.length s) 0 bss
            when (msgsize > 4096)$ -- TODO, look up PIPE_BUF in foreign code
	       error "Message larger than blocksize written atomically to a named pipe.  Unimplemented."
            -- Otherwise it's just a simple write:
	    -- We append the length as a header. TODO - REMOVE EXTRA COPY HERE:
            let finalmsg = BS.concat (encode msgsize : bss)
            dbgprint1$ "  Final send msg: " ++ show finalmsg
           
            -- OPTION 2: Speculative file opening, plus this synchronnization:
--            fd <- readMVar mv
            ----------------------------------------
            cnt <- PIO.fdWrite fd (fromBS finalmsg) -- inefficient to use String here!
            unless (fromIntegral cnt == BS.length finalmsg) $ 
	      error$ "Failed to write message in one go, length: "++ show (BS.length finalmsg)
            ----------------------------------------

            return ()
        }

    mkTargetEnd :: String -> MVar () -> TargetEnd
    mkTargetEnd filename lock = TargetEnd
      { receive = do
          dbgprint2$ "Begin receive action..."
          -- This should only happen on a single process.  But it may
          -- happen on multiple threads so we grab a lock.
          takeMVar lock

          mv <- onOSThread$ PIO.openFd filename PIO.ReadWrite Nothing PIO.defaultFileFlags
	  fd <- takeMVar mv
          let oneread :: Int64 -> IO (BS.ByteString, Int64)
	      oneread n = do bs <- readit fd (fromIntegral n)
			     return (bs, BS.length bs)
          dbgprint2$ "  Attempt read header..."
        
	  let spinread :: Int64 -> IO BS.ByteString
              spinread desired = do 
--               hPutStr stderr "."
               (bytes,len) <- oneread desired
	       case len of 
                 n | n == desired -> return bytes
		 0 -> do threadDelay (10*1000)
			 spinread desired
                 l -> error$ "Inclomplete read expected either 0 bytes or complete msg ("++
		             show desired ++" bytes) got "++ show l ++ " bytes"

          hdr <- spinread sizeof_header
          dbgprint2$ "  Got header "++ show hdr ++ " attempt read payload"
          payload  <- case decode hdr of
		        Left err -> error$ "ERROR: "++ err
			Right size -> spinread (fromIntegral (size::Word32))
          dbgprint2$ "  Got payload "++ show payload

          putMVar lock () 
          return [payload]
      }

#ifdef DEBUG
dbgprint2 = hPutStrLn stdout
dbgprint1 = hPutStrLn stderr
#else
dbgprint1 _ = return ()
dbgprint2 _ = return ()
#endif


-- Execute an action on its own OS thread.  Return an MVar to synchronize on.
onOSThread :: IO a -> IO (MVar a)
onOSThread action = do 
  mv <- newEmptyMVar
  forkOS (action >>= putMVar mv )
  return mv
-- [2012.02.19] This didn't seem to help.
