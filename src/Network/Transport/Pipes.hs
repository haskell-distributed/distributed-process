{-# LANGUAGE BangPatterns, CPP #-}

module Network.Transport.Pipes
  ( mkTransport
  ) where

import Control.Monad (when)
import Control.Concurrent.MVar
import Control.Concurrent (threadDelay)
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
import System.IO     (IOMode(ReadMode,AppendMode), openFile, hClose)
import System.Posix.Files (createNamedPipe, unionFileModes, ownerReadMode, ownerWriteMode)

-- Option 1: low level unix routines:
-- Option 2: ByteString-provided IO routines
#if UNIXIO
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
#if UNIXIO
  pipe <- PIO.openFd filename PIO.ReadOnly Nothing PIO.defaultFileFlags
#else 
  pipe <- openFile filename ReadMode
#endif

  return Transport
    { newConnectionWith = \ _ -> do
        return (mkSourceAddr filename, 
		mkTargetEnd pipe lock)
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
      return $ 
      -- Write to the named pipe.  If the message is less than
      -- PIPE_BUF (4KB on linux) then this should be atomic, otherwise
      -- we have to do something more sophisticated.
        SourceEnd
        { send = \bss -> do
            putStrLn$ "SENDING ... "++ show bss

	    -- This may happen on multiple processes/threads:
	    let msgsize = foldl' (\n s -> n + BS.length s) 0 bss
            when (msgsize > 4096)$ -- TODO, look up PIPE_BUF in foreign code
	       error "Message larger than blocksize written atomically to a named pipe.  Unimplemented."
            -- Otherwise it's just a simple write:
	    -- We append the length as a header. TODO - REMOVE EXTRA COPY HERE:
            fd <- openFile filename AppendMode
	    BS.hPut fd (BS.concat (encode msgsize : bss))
            hClose fd -- TEMP -- opening and closing on each send!
        }

--    mkTargetEnd :: Fd -> MVar () -> TargetEnd
    mkTargetEnd fd lock = TargetEnd
      { receive = do
          -- This should only happen on a single process.  But it may
          -- happen on multiple threads so we grab a lock.
          takeMVar lock
#ifdef UNIXIO
          (bytes,cnt) <- PIO.fdRead fd sizeof_header
#else
          putStrLn$ "  Attempt read header..."
          
	  let rdloop = do 
               putStr "."
               hdr <- BS.hGet fd sizeof_header
	       case BS.length hdr of 
                 n | n == sizeof_header -> return hdr
		 0 -> do threadDelay (10*1000)
			 rdloop 
                 l -> error$ "Inclomplete read of msg header, only "++ show l ++ " bytes"
          hdr <- rdloop
          putStrLn$ "  Got header "++ show hdr ++ " attempt read payload"
          payload <- case decode hdr of
		      Left err -> error$ "ERROR: "++ err
		      Right size -> BS.hGet fd size
          putStrLn$ "  Got payload "++ show payload
#endif
          putMVar lock () 
          return [payload]
      }

