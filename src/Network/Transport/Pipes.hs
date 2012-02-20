{-# LANGUAGE BangPatterns, CPP, ScopedTypeVariables #-}

module Network.Transport.Pipes
  ( mkTransport
  ) where

import Control.Monad (when)
import Control.Concurrent.MVar
import Control.Concurrent (threadDelay, forkOS)
import Data.IntMap (IntMap)
-- import Data.ByteString.Char8 (ByteString)
import Data.Word
import qualified Data.IntMap as IntMap
import qualified Data.ByteString.Char8 as BS
-- import qualified Data.ByteString.Lazy.Char8 as BS

-- import Data.Binary (decode)
import Data.Serialize (encode,decode)
import Data.List (foldl')
import Network.Transport
import System.Random (randomIO)
import System.IO     (IOMode(ReadMode,AppendMode,WriteMode,ReadWriteMode), 
		      openFile, hClose, hPutStrLn, hPutStr, stderr, stdout)
import System.Posix.Files (createNamedPipe, unionFileModes, ownerReadMode, ownerWriteMode)

-- Option 1: low level unix routines:
-- Option 2: ByteString-provided IO routines
#define UNIXIO
#ifdef UNIXIO
-- Added in unix-2.5.1.0.  Let's not depend on this yet:
-- import qualified System.Posix.IO.ByteString as PIO
import qualified System.Posix.IO as PIO
import System.Posix.Types (Fd)
#else

#endif


-- An address is just a filename -- the named pipe.
data Addr = Addr String 
  deriving (Show,Read)

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
--      fd <- openFile filename AppendMode
--      mv <- onOSThread$ openFile filename WriteMode
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

--            fd <- readMVar mv
            dbgprint1$ "  (sending... got file descriptor) "
--            fd <- openFile filename AppendMode
            fd <- openFile filename WriteMode

-- TODO: Consider nonblocking opening of file to make things simpler.

            let finalmsg = BS.concat (encode msgsize : bss)
            dbgprint1$ "  Final send msg: " ++ show finalmsg
	    BS.hPut fd finalmsg
            hClose fd -- TEMP -- opening and closing on each send!
        }

--    mkTargetEnd :: Fd -> MVar () -> TargetEnd
    mkTargetEnd filename lock = TargetEnd
      { receive = do
          dbgprint2$ "Begin receive action..."
          -- This should only happen on a single process.  But it may
          -- happen on multiple threads so we grab a lock.
          takeMVar lock
#ifdef UNIXIO
--          fd <- PIO.openFd filename PIO.ReadOnly Nothing PIO.defaultFileFlags
          fd <- PIO.openFd filename PIO.ReadWrite Nothing PIO.defaultFileFlags
          let oneread n = do (s,cnt) <- PIO.fdRead fd (fromIntegral n)
			     return (BS.pack s, fromIntegral cnt)
#else
          fd <- openFile filename ReadMode
          let oneread n = do bs <- BS.hGet fd n; 
			     return (bs, BS.length bs)
#endif
          dbgprint2$ "  Attempt read header..."
          
	  let spinread :: Int -> IO BS.ByteString
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

-- dbgprint2 = hPutStrLn stdout
-- dbgprint1 = hPutStrLn stderr
dbgprint1 _ = return ()
dbgprint2 _ = return ()


-- Execute an action on its own OS thread.  Return an MVar to synchronize on.
onOSThread :: IO a -> IO (MVar a)
onOSThread action = do 
  mv <- newEmptyMVar
  forkOS (action >>= putMVar mv )
  return mv
