-- | Internal functions
module Network.Transport.Internal
  ( -- * Encoders/decoders
    encodeWord32
  , decodeWord32
  , encodeEnum32
  , decodeNum32
  , encodeWord16
  , decodeWord16
  , encodeEnum16
  , decodeNum16
  , prependLength
    -- * Miscellaneous abstractions
  , mapIOException
  , tryIO
  , tryToEnum
  , timeoutMaybe
  , asyncWhenCancelled
  -- * Replicated functionality from "base"
  , void
  , forkIOWithUnmask
    -- * Debugging
  , tlog
  ) where

#if ! MIN_VERSION_base(4,6,0)
import Prelude hiding (catch)
#endif

import Foreign.Storable (pokeByteOff, peekByteOff)
import Foreign.ForeignPtr (withForeignPtr)
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS (length)
import qualified Data.ByteString.Internal as BSI
  ( unsafeCreate
  , toForeignPtr
  , inlinePerformIO
  )
import Data.Word (Word32, Word16)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Exception
  ( IOException
  , SomeException
  , AsyncException
  , Exception
  , catch
  , try
  , throw
  , throwIO
  , mask_
  )
import Control.Concurrent (ThreadId, forkIO)
import Control.Concurrent.MVar (MVar, newEmptyMVar, takeMVar, putMVar)
import GHC.IO (unsafeUnmask)
import System.Timeout (timeout)
--import Control.Concurrent (myThreadId)

#ifdef mingw32_HOST_OS

foreign import stdcall unsafe "htonl" htonl :: Word32 -> Word32
foreign import stdcall unsafe "ntohl" ntohl :: Word32 -> Word32
foreign import stdcall unsafe "htons" htons :: Word16 -> Word16
foreign import stdcall unsafe "ntohs" ntohs :: Word16 -> Word16

#else

foreign import ccall unsafe "htonl" htonl :: Word32 -> Word32
foreign import ccall unsafe "ntohl" ntohl :: Word32 -> Word32
foreign import ccall unsafe "htons" htons :: Word16 -> Word16
foreign import ccall unsafe "ntohs" ntohs :: Word16 -> Word16

#endif

-- | Serialize 32-bit to network byte order
encodeWord32 :: Word32 -> ByteString
encodeWord32 w32 =
  BSI.unsafeCreate 4 $ \p ->
    pokeByteOff p 0 (htonl w32)

-- | Deserialize 32-bit from network byte order
-- Throws an IO exception if this is not exactly 32 bits.
decodeWord32 :: ByteString -> Word32
decodeWord32 bs
  | BS.length bs /= 4 = throw $ userError "decodeWord32: not 4 bytes"
  | otherwise         = BSI.inlinePerformIO $ do
      let (fp, offset, _) = BSI.toForeignPtr bs
      withForeignPtr fp $ \p -> ntohl <$> peekByteOff p offset

-- | Serialize 16-bit to network byte order
encodeWord16 :: Word16 -> ByteString
encodeWord16 w16 =
  BSI.unsafeCreate 2 $ \p ->
    pokeByteOff p 0 (htons w16)

-- | Deserialize 16-bit from network byte order
-- Throws an IO exception if this is not exactly 16 bits.
decodeWord16 :: ByteString -> Word16
decodeWord16 bs
  | BS.length bs /= 2 = throw $ userError "decodeWord16: not 2 bytes"
  | otherwise         = BSI.inlinePerformIO $ do
      let (fp, offset, _) = BSI.toForeignPtr bs
      withForeignPtr fp $ \p -> ntohs <$> peekByteOff p offset

-- | Encode an Enum in 32 bits by encoding its signed Int equivalent (beware
-- of truncation, an Enum may contain more than 2^32 points).
encodeEnum32 :: Enum a => a -> ByteString
encodeEnum32 = encodeWord32 . fromIntegral . fromEnum

-- | Decode any Num type from 32 bits by using fromIntegral to convert from
--   a Word32.
decodeNum32 :: Num a => ByteString -> a
decodeNum32 = fromIntegral . decodeWord32

-- | Encode an Enum in 16 bits by encoding its signed Int equivalent (beware
-- of truncation, an Enum may contain more than 2^16 points).
encodeEnum16 :: Enum a => a -> ByteString
encodeEnum16 = encodeWord16 . fromIntegral . fromEnum

-- | Decode any Num type from 16 bits by using fromIntegral to convert from
-- a Word16.
decodeNum16 :: Num a => ByteString -> a
decodeNum16 = fromIntegral . decodeWord16

-- | Prepend a list of bytestrings with their total length
prependLength :: [ByteString] -> [ByteString]
prependLength bss = encodeWord32 (fromIntegral . sum . map BS.length $ bss) : bss

-- | Translate exceptions that arise in IO computations
mapIOException :: Exception e => (IOException -> e) -> IO a -> IO a
mapIOException f p = catch p (throwIO . f)

-- | Like 'try', but lifted and specialized to IOExceptions
tryIO :: MonadIO m => IO a -> m (Either IOException a)
tryIO = liftIO . try

-- | Logging (for debugging)
tlog :: MonadIO m => String -> m ()
tlog _ = return ()
{-
tlog msg = liftIO $ do
  tid <- myThreadId
  putStrLn $ show tid ++ ": "  ++ msg
-}

-- | Not all versions of "base" export 'void'
void :: Monad m => m a -> m ()
void p = p >> return ()

-- | This was introduced in "base" some time after 7.0.4
forkIOWithUnmask :: ((forall a . IO a -> IO a) -> IO ()) -> IO ThreadId
forkIOWithUnmask io = forkIO (io unsafeUnmask)

-- | Safe version of 'toEnum'
tryToEnum :: (Enum a, Bounded a) => Int -> Maybe a
tryToEnum = go minBound maxBound
  where
    go :: Enum b => b -> b -> Int -> Maybe b
    go lo hi n = if fromEnum lo <= n && n <= fromEnum hi then Just (toEnum n) else Nothing

-- | If the timeout value is not Nothing, wrap the given computation with a
-- timeout and it if times out throw the specified exception. Identity
-- otherwise.
timeoutMaybe :: Exception e => Maybe Int -> e -> IO a -> IO a
timeoutMaybe Nothing  _ f = f
timeoutMaybe (Just n) e f = do
  ma <- timeout n f
  case ma of
    Nothing -> throwIO e
    Just a  -> return a

-- | @asyncWhenCancelled g f@ runs f in a separate thread and waits for it
-- to complete. If f throws an exception we catch it and rethrow it in the
-- current thread. If the current thread is interrupted before f completes,
-- we run the specified clean up handler (if f throws an exception we assume
-- that no cleanup is necessary).
asyncWhenCancelled :: forall a. (a -> IO ()) -> IO a -> IO a
asyncWhenCancelled g f = mask_ $ do
    mvar <- newEmptyMVar
    forkIO $ try f >>= putMVar mvar
    -- takeMVar is interruptible (even inside a mask_)
    catch (takeMVar mvar) (exceptionHandler mvar) >>= either throwIO return
  where
    exceptionHandler :: MVar (Either SomeException a)
                     -> AsyncException
                     -> IO (Either SomeException a)
    exceptionHandler mvar ex = do
      forkIO $ takeMVar mvar >>= either (const $ return ()) g
      throwIO ex
