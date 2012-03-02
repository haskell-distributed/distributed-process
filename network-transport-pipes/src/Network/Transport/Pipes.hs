{-# LANGUAGE BangPatterns, CPP, ScopedTypeVariables, PackageImports #-}

----------------------------------------------------------------------------------------------------

-- WARNING -- This transport is not yet completed.  TODO:

--  * Add support for messages greater than 4096 bytes.
--  * debug ODD problem with CEREAL below

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
import qualified Data.ByteString.Char8 as BS
import Data.Time.Clock (getCurrentTime, diffUTCTime, UTCTime) -- Not in 6.10

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
import System.IO.Error (ioeGetHandle)
import System.Posix.Files (createNamedPipe, unionFileModes, ownerReadMode, ownerWriteMode)
import System.Posix.Types (Fd, ByteCount)
import System.Directory (doesFileExist, removeFile)
import System.Mem (performGC)

#define USE_UNIX_BYTESTRING
#ifdef USE_UNIX_BYTESTRING
import qualified "unix-bytestring" System.Posix.IO.ByteString as PIO
-- import qualified "unix-bytestring" System.Posix.IO.ByteString.Lazy as PIO
import System.Posix.IO as PIO (openFd, closeFd, -- append, exclusive, noctty, nonBlock, trunc,
			       OpenFileFlags(..), OpenMode(ReadOnly, WriteOnly))
-- (fromS,toS)  = (BS.pack, BS.unpack)
(fromS,toS)  = (BS.pack, BS.unpack)
fromBS = id
readit fd n = PIO.fdRead fd n
#else
import qualified System.Posix.IO            as PIO
(toS,fromS)  = (id,id)
fromBS = BS.unpack
readit fd n = do (s,_) <- PIO.fdRead fd n
		 return (BS.pack s)
#endif
-- readit :: Fd -> Int -> IO BS.ByteString
readit :: Fd -> ByteCount -> IO BS.ByteString

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
--  uid <- randomIO :: IO Word64
  -- For backwards compatibility we shouldn't assume a Random instance for Word64:
  uid <- randomIO :: IO Int

  lock <- newMVar ()
  let filename = "/tmp/pipe_"++show (abs uid)
  createNamedPipe filename $ unionFileModes ownerReadMode ownerWriteMode

  return Transport
    { newConnectionWith = \ _ -> do
	-- Here we protect from blocking other threads by running on a separate (OS) thread:
	-- Opening the file on the reader side should always succeed:
        mv <- onOSThread$ tryUntilNoIOErr "open pipe for read" $ 
--	      spinTillThere filename
	      PIO.openFd filename PIO.ReadOnly Nothing fileFlags

        return (mkSourceAddr filename, 
		mkTargetEnd mv lock)
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
      mv <- onOSThread$ tryUntilNoIOErr "open pipe for write" $ 
            -- The reader must connect first, the writer here spins with backoff.
            PIO.openFd filename PIO.WriteOnly Nothing fileFlags

      return $ 
      -- Write to the named pipe.  If the message is less than
      -- PIPE_BUF (4KB on linux) then this should be atomic, otherwise
      -- we have to do something more sophisticated.
        SourceEnd
        { send = \bsls -> do
	    -- ThreadSafe: This may happen on multiple processes/threads:
  	    -- We don't need to lock because the write is atomic (for <4096):
	    let msgsize :: Word32 = fromIntegral$ foldl' (\n s -> n + BS.length s) 0 bsls
            when (msgsize > 4096)$ -- TODO, look up PIPE_BUF in foreign code
	       error "Message larger than blocksize written atomically to a named pipe.  Unimplemented."
            -- Otherwise it's just a simple write:
	    -- We append the length as a header. TODO - REMOVE EXTRA COPY HERE:

            let hdrbss :: BS.ByteString
#ifdef CEREAL 
                hdrbss = encode msgsize
#else 
--                hdrbss = BS.fromChunks[encode msgsize]
                [hdrbss] = BS.toChunks (encode msgsize)
#endif

--            let finalmsg = BS.concat (encode msgsize : bss)
            let finalmsg = BS.concat (hdrbss : bsls)
                       
            fd <- readMVar mv -- Synchronize with file opening.
            ----------------------------------------
            cnt <- PIO.fdWrite fd (fromBS finalmsg) -- inefficient to use String here!
            unless (fromIntegral cnt == BS.length finalmsg) $ 
	      error$ "Failed to write message in one go, length: "++ show (BS.length finalmsg)
            ----------------------------------------
            return ()
	, closeSourceEnd = do
            fd <- readMVar mv 
            PIO.closeFd fd
        }

    mkTargetEnd :: MVar Fd -> MVar () -> TargetEnd
    mkTargetEnd mv lock = TargetEnd
      { receive = do
          fd <- readMVar mv -- Make sure Fd is there before

          -- This should only happen on a *single* process.  But it may
          -- happen on multiple threads so we grab a lock.

	  -- If we don't lock, we cannot atomically read the length
	  -- and THEN read the payload.  (A single read could be
	  -- atomic, but not two reads.)
          takeMVar lock

	  let spinread :: Int -> IO BS.ByteString
              spinread desired = do 

	       bs <- tryUntilNoIOErr "read pipe file descriptor"$ 
		     readit fd (fromIntegral desired)

	       case BS.length bs of 
                 n | n == desired -> return bs
                 -- Because we're in non-blocking mode we deal with failed reads thusly:
--		 0 -> do threadDelay (10*1000)
--		         spinread desired
                 0 -> error$ "receive: read zero bytes from pipe.  Even in non-blocking mode should have had an EAGAIN error instead."
                 l -> error$ "Inclomplete read expected either 0 bytes or complete msg ("++
		             show desired ++" bytes) got "++ show l ++ " bytes"

          hdr <- spinread sizeof_header
          let 
#ifdef CEREAL 
              decoded = decode hdr	  
#else 
              decoded = decode (BS.fromChunks [hdr])
#endif
          payload  <- case decoded of
		        Left err -> error$ "ERROR: "++ err
			Right size -> spinread (fromIntegral (size::Word32))

          putMVar lock () 
          return [payload] -- How terribly listy.
      , closeTargetEnd = do 
         fd <- readMVar mv
	 PIO.closeFd fd
      }

-- | Wait untila file is present, with backoff.
spinTillThere :: String -> IO ()
spinTillThere filename = mkBackoff >>= loop 
  where
   loop bkoff = do b <- doesFileExist filename
		   unless b $ do bkoff; loop bkoff

-- | Create a backoff action that waits successively longer between attempts.
mkBackoff :: IO (IO ())
mkBackoff = 
  do tref <- newIORef 1
     return$ do t <- readIORef tref
		writeIORef tref (min maxwait (2 * t))
		threadDelay t
 where 
   maxwait = 50 * 1000

-- | Try an IO action repeatedly (with backoff) until it succeeds without exception.
tryUntilNoIOErr :: String -> IO a -> IO a
tryUntilNoIOErr msg action = 
   do startTime <- getCurrentTime
      bkoff <- mkBackoff 
      loop startTime startTime bkoff
 where 
  loop start lastWarned bkoff = 
    handle (\ (e :: IOException) -> 
	     do lw <- maybeWarn start lastWarned
                bkoff 
--                BSS.hPutStr stderr$ BSS.pack$ "    got IO err: " ++ show e
	        -- case ioeGetHandle e of 
	        --   Nothing -> BSS.hPutStrLn stderr$ BSS.pack$ "  no hndl io err."
	        --   Just x  -> BSS.hPutStrLn stderr$ BSS.pack$ "  HNDL on io err!" ++ show x
	        loop start lw bkoff) $ 
	   action
  -- After how many milleseconds should we start warning?
  warn_lvl = 3000
  maybeWarn :: UTCTime -> UTCTime -> IO UTCTime
  maybeWarn start lastWarned = do
    now <- getCurrentTime
    let seconds     :: Double = fromRational $ toRational $ diffUTCTime now start
	sinceWarned :: Double = fromRational $ toRational $ diffUTCTime now lastWarned
    if (seconds * 1000 >= warn_lvl &&
	sinceWarned >= 1.0 ) then do
        BS.hPutStrLn stderr$ BS.pack$ "WARNING: have been trying an IO action ("++msg++
	                     ") for "++show seconds++ " seconds without success"
	return now
     else 
        return lastWarned

-- Execute an action on its own OS thread.  Return an MVar to synchronize on.
onOSThread :: IO a -> IO (MVar a)
onOSThread action = do 
  mv <- newEmptyMVar
  forkOS (action >>= putMVar mv )
  return mv
