-- | Internal functions
module Network.Transport.Internal ( -- * Encoders/decoders
                                    encodeInt32
                                  , decodeInt32
                                  , encodeInt16
                                  , decodeInt16
                                  , prependLength
                                    -- * Miscellaneous abstractions
                                  , failWith
                                  , failWithIO
                                  , tryIO
                                  , whileM
                                    -- * Debugging
                                  , tlog
                                  , loopInvariant
                                  ) where

import Prelude hiding (catch)
import Foreign.Storable (pokeByteOff, peekByteOff)
import Foreign.C (CInt(..), CShort(..))
import Foreign.ForeignPtr (withForeignPtr)
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS (length)
import qualified Data.ByteString.Internal as BSI (unsafeCreate, toForeignPtr, inlinePerformIO)
import Control.Applicative ((<$>))
import Control.Monad (MonadPlus, guard)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.Error (MonadError, throwError)
import Control.Exception (IOException, catch, try)
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
decodeInt32 :: Enum a => ByteString -> Maybe a 
decodeInt32 bs | BS.length bs /= 4 = Nothing 
decodeInt32 bs = Just . BSI.inlinePerformIO $ do 
  let (fp, _, _) = BSI.toForeignPtr bs 
  withForeignPtr fp $ \p -> do
    w32 <- peekByteOff p 0 
    return (toEnum . fromIntegral . ntohl $ w32)

-- | Serialize 16-bit to network byte order 
encodeInt16 :: Enum a => a -> ByteString 
encodeInt16 i16 = 
  BSI.unsafeCreate 2 $ \p ->
    pokeByteOff p 0 (htons .fromIntegral . fromEnum $ i16)

-- | Deserialize 16-bit from network byte order 
decodeInt16 :: Enum a => ByteString -> Maybe a
decodeInt16 bs | BS.length bs /= 2 = Nothing 
decodeInt16 bs = Just . BSI.inlinePerformIO $ do
  let (fp, _, _) = BSI.toForeignPtr bs 
  withForeignPtr fp $ \p -> do
    w16 <- peekByteOff p 0 
    return (toEnum . fromIntegral . ntohs $ w16)

-- | Prepend a list of bytestrings with their total length
prependLength :: [ByteString] -> [ByteString]
prependLength bss = encodeInt32 (sum . map BS.length $ bss) : bss

-- | Convert a "failing operation" into one that fails with a specific error 
failWith :: (MonadError e m) => e -> Maybe a -> m a
failWith err Nothing  = throwError err
failWith _   (Just x) = return x

-- | Try the specific I/O operation, and fail with the given error 
-- when an exception occurs
failWithIO :: (MonadIO m, MonadError e m) => (IOException -> e) -> IO a -> m a
failWithIO f io = do
    ma <- liftIO $ catch (Right <$> io) handleIOException
    case ma of
      Left err -> throwError (f err)
      Right a  -> return a
  where
    handleIOException :: IOException -> IO (Either IOException a)
    handleIOException = return . Left 

-- | Like 'try', but specialized to IOExceptions
tryIO :: IO a -> IO (Either IOException a)
tryIO = try

-- | Logging (for debugging)
tlog :: String -> IO ()
tlog _ = return ()
{-
tlog msg = do
  tid <- myThreadId
  putStrLn $ show tid ++ ": "  ++ msg
-}

-- | Loop invariant (like 'guard')
loopInvariant :: MonadPlus m => m Bool -> m ()
loopInvariant = (>>= guard)

-- | While-loop
whileM :: Monad m => m Bool -> m a -> m ()
whileM cond body = go
  where
    go = do
      b <- cond
      if b then body >> go else return ()
