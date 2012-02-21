{-# LANGUAGE BangPatterns, CPP, ScopedTypeVariables, PackageImports #-}

----------------------------------------------------------------------------------------------------

-- WARNING -- This transport is not yet completed.  TODO:

--  * Add support for messages greater than 4096 bytes.
--  * debug ODD problem with CEREAL below
--  * switch to unix-bytestring after that package is updated for 7.4.1

----------------------------------------------------------------------------------------------------

module Network.Transport.Pipes
  ( mkTransport
  ) where

import Control.Monad (when, unless)
import Control.Exception (evaluate, throw, handle, fromException,
			  SomeException, IOException)
import Control.Concurrent.MVar
import Control.Concurrent (threadDelay, forkOS)
import Data.IntMap (IntMap)
-- import Data.ByteString.Char8 (ByteString)
import Data.Word
import Data.Int
import Data.IORef
import qualified Data.IntMap as IntMap
import qualified Data.ByteString.Char8 as BSS
import qualified Data.ByteString.Lazy.Char8 as BS

-- For some STRANGE reason this is not working with Data.Binary [2012.02.20]:
#define CEREAL
#ifdef CEREAL
import Data.Serialize (encode,decode) -- Uses strict BS
#else
import Data.Binary    (encode,decode) -- Uses lazy BS
#endif

import Data.List (foldl')
import Network.Transport
import System.Random (randomIO)
import System.IO     (IOMode(ReadMode,AppendMode,WriteMode,ReadWriteMode), 
		      openFile, hClose, hPutStrLn, hPutStr, stderr, stdout, hFlush)
import System.Posix.Files (createNamedPipe, unionFileModes, ownerReadMode, ownerWriteMode)
import System.Posix.Types (Fd)
import System.Directory (doesFileExist, removeFile)

-- define DEBUG
-- define USE_UNIX_BYTESTRING

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

fileFlags = 
 PIO.OpenFileFlags {
    PIO.append    = False,
    PIO.exclusive = False,
    PIO.noctty    = False,
    PIO.nonBlock  = True,
    -- In nonblocking mode opening for read will always succeed and
    -- opening for write must happen second.
    PIO.trunc     = False
  }
-- NOTE:
-- "The only open file status flags that can be meaningfully applied
--  to a pipe or FIFO are O_NONBLOCK and O_ASYNC. "


mkTransport :: IO Transport
mkTransport = do
  uid <- randomIO :: IO Word64
  lock <- newMVar ()
  let filename = "/tmp/pipe_"++show uid
  createNamedPipe filename $ unionFileModes ownerReadMode ownerWriteMode

  return Transport
    { newConnectionWith = \ _ -> do
        return (mkSourceAddr filename, 
		mkTargetEnd filename lock)
    , newMulticastWith = error "Pipes.hs: newMulticastWith not implemented yet"
    , deserialize = \bs -> return$ mkSourceAddr (BS.unpack bs)
    , closeTransport = removeFile filename
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

      -- Here we protect from blocking other threads by running on a separate (OS) thread:
      mv <- onOSThread$ tryUntilNoIOErr $ 
            -- The reader must connect first, the writer here spins with backoff.
	    PIO.openFd filename PIO.WriteOnly Nothing fileFlags

      return $ 
      -- Write to the named pipe.  If the message is less than
      -- PIPE_BUF (4KB on linux) then this should be atomic, otherwise
      -- we have to do something more sophisticated.
        SourceEnd
        { send = \bss -> do
	    -- ThreadSafe: This may happen on multiple processes/threads:
	    let msgsize :: Word32 = fromIntegral$ foldl' (\n s -> n + BS.length s) 0 bss
            when (msgsize > 4096)$ -- TODO, look up PIPE_BUF in foreign code
	       error "Message larger than blocksize written atomically to a named pipe.  Unimplemented."
            -- Otherwise it's just a simple write:
	    -- We append the length as a header. TODO - REMOVE EXTRA COPY HERE:
--            let finalmsg = BS.concat (encode msgsize : bss)
            let finalmsg = BS.concat ((BS.fromChunks[encode msgsize]) : bss)
                       
            fd <- readMVar mv -- Synchronnize with file opening.
            ----------------------------------------
            cnt <- PIO.fdWrite fd (fromBS finalmsg) -- inefficient to use String here!
            unless (fromIntegral cnt == BS.length finalmsg) $ 
	      error$ "Failed to write message in one go, length: "++ show (BS.length finalmsg)
            ----------------------------------------
            return ()
	, closeSourceEnd = error "Pipes.hs: closeSourceEnd not yet implemented"
        }

    mkTargetEnd :: String -> MVar () -> TargetEnd
    mkTargetEnd filename lock = TargetEnd
      { receive = do
          -- This should only happen on a single process.  But it may
          -- happen on multiple threads so we grab a lock.
          takeMVar lock

          spinTillThere filename
	  -- Opening the file on the reader side should always succeed:
          fd <- PIO.openFd filename PIO.ReadOnly Nothing fileFlags

          let oneread fd n = 
                  do bs <- tryUntilNoIOErr$ 
			   readit fd (fromIntegral n)
		     return (bs, BS.length bs)
        
	  let spinread :: Int64 -> IO BS.ByteString
              spinread desired = do 

	       bs <- tryUntilNoIOErr$ 
		     readit fd (fromIntegral desired)

	       case BS.length bs of 
                 n | n == desired -> return bs
		 0 -> do threadDelay (10*1000)
			 spinread desired
                 l -> error$ "Inclomplete read expected either 0 bytes or complete msg ("++
		             show desired ++" bytes) got "++ show l ++ " bytes"

          hdr <- spinread sizeof_header
#ifdef CEREAL 
          let decoded = decode (BSS.concat$ BS.toChunks hdr)
#else 
          let decoded = decode hdr	  
#endif
          payload  <- case decoded of
		        Left err -> error$ "ERROR: "++ err
			Right size -> spinread (fromIntegral (size::Word32))
          putMVar lock () 
          return [payload]
      , closeTargetEnd = error "Pipes.hs: closeTargetEnd not yet implemented"
      }

spinTillThere :: String -> IO ()
spinTillThere filename = mkBackoff >>= loop 
  where
   loop bkoff = do b <- doesFileExist filename
		   unless b $ do bkoff; loop bkoff

mkBackoff :: IO (IO ())
mkBackoff = 
  do tref <- newIORef 1
     return$ do t <- readIORef tref
		writeIORef tref (min maxwait (2 * t))
		threadDelay t
 where 
   maxwait = 50 * 1000

tryUntilNoIOErr :: IO a -> IO a
tryUntilNoIOErr action = mkBackoff >>= loop 
 where 
  loop bkoff = 
    handle (\ (e :: IOException) -> 
	     do bkoff 
	        loop bkoff) $ 
	   action

-- Execute an action on its own OS thread.  Return an MVar to synchronize on.
onOSThread :: IO a -> IO (MVar a)
onOSThread action = do 
  mv <- newEmptyMVar
  forkOS (action >>= putMVar mv )
  return mv
