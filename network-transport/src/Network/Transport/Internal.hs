-- | Internal functions
module Network.Transport.Internal ( -- * Encoders/decoders
                                    encodeInt32
                                  , decodeInt32
                                  , encodeInt16
                                  , decodeInt16
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
import Foreign.C (CInt(..), CShort(..))
import Foreign.ForeignPtr (withForeignPtr)
import Data.NotByteString (ByteString)
import qualified Data.NotByteString as BS (length)
import qualified Data.NotByteString.Internal as BSI ( unsafeCreate
                                                    , toForeignPtr
                                                    , inlinePerformIO)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Exception ( IOException
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

foreign import ccall unsafe "htonl" htonl :: CInt -> CInt
foreign import ccall unsafe "ntohl" ntohl :: CInt -> CInt
foreign import ccall unsafe "htons" htons :: CShort -> CShort
foreign import ccall unsafe "ntohs" ntohs :: CShort -> CShort

-- | Serialize 32-bit to network byte order 
encodeInt32 :: Enum a => a -> ByteString
encodeInt32 i32 = 
  BSI.unsafeCreate 4 $ \p ->
    pokeByteOff p 0 (htonl . fromIntegral . fromEnum $ i32)

-- | Deserialize 32-bit from network byte order 
-- Throws an IO exception if this is not a valid integer.
decodeInt32 :: Num a => ByteString -> a 
decodeInt32 bs 
  | BS.length bs /= 4 = throw $ userError "decodeInt32: Invalid length" 
  | otherwise         = BSI.inlinePerformIO $ do 
      let (fp, offset, _) = BSI.toForeignPtr bs 
      withForeignPtr fp $ \p -> do
        w32 <- peekByteOff p offset 
        return (fromIntegral . ntohl $ w32)

-- | Serialize 16-bit to network byte order 
encodeInt16 :: Enum a => a -> ByteString 
encodeInt16 i16 = 
  BSI.unsafeCreate 2 $ \p ->
    pokeByteOff p 0 (htons . fromIntegral . fromEnum $ i16)

-- | Deserialize 16-bit from network byte order 
-- Throws an IO exception if this is not a valid integer
decodeInt16 :: Num a => ByteString -> a
decodeInt16 bs 
  | BS.length bs /= 2 = throw $ userError "decodeInt16: Invalid length" 
  | otherwise         = BSI.inlinePerformIO $ do
      let (fp, offset, _) = BSI.toForeignPtr bs 
      withForeignPtr fp $ \p -> do
        w16 <- peekByteOff p offset
        return (fromIntegral . ntohs $ w16)

-- | Prepend a list of bytestrings with their total length
prependLength :: [ByteString] -> [ByteString]
prependLength bss = encodeInt32 (sum . map BS.length $ bss) : bss

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
