-- | Internal functions
module Network.Transport.Internal ( -- * Encoders/decoders
                                    encodeInt32
                                  , decodeInt32
                                  , encodeInt16
                                  , decodeInt16
                                  , prependLength
                                    -- * Miscellaneous abstractions
                                  , mapExceptionIO
                                  , tryIO
                                  , tryToEnum
                                    -- * Debugging
                                  , tlog
                                  ) where

import Prelude hiding (catch)
import Foreign.Storable (pokeByteOff, peekByteOff)
import Foreign.C (CInt(..), CShort(..))
import Foreign.ForeignPtr (withForeignPtr)
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS (length)
import qualified Data.ByteString.Internal as BSI (unsafeCreate, toForeignPtr, inlinePerformIO)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Exception (IOException, Exception, catch, try, throw)
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
decodeInt32 :: Num a => ByteString -> Maybe a 
decodeInt32 bs | BS.length bs /= 4 = Nothing 
decodeInt32 bs = Just . BSI.inlinePerformIO $ do 
  let (fp, _, _) = BSI.toForeignPtr bs 
  withForeignPtr fp $ \p -> do
    w32 <- peekByteOff p 0 
    return (fromIntegral . ntohl $ w32)

-- | Serialize 16-bit to network byte order 
encodeInt16 :: Enum a => a -> ByteString 
encodeInt16 i16 = 
  BSI.unsafeCreate 2 $ \p ->
    pokeByteOff p 0 (htons . fromIntegral . fromEnum $ i16)

-- | Deserialize 16-bit from network byte order 
decodeInt16 :: Num a => ByteString -> Maybe a
decodeInt16 bs | BS.length bs /= 2 = Nothing 
decodeInt16 bs = Just . BSI.inlinePerformIO $ do
  let (fp, _, _) = BSI.toForeignPtr bs 
  withForeignPtr fp $ \p -> do
    w16 <- peekByteOff p 0 
    return (fromIntegral . ntohs $ w16)

-- | Prepend a list of bytestrings with their total length
prependLength :: [ByteString] -> [ByteString]
prependLength bss = encodeInt32 (sum . map BS.length $ bss) : bss

-- | Translate exceptions that arise in IO computations
mapExceptionIO :: (Exception e1, Exception e2) => (e1 -> e2) -> IO a -> IO a
mapExceptionIO f p = catch p (throw . f)

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

-- | Safe version of 'toEnum'
tryToEnum :: forall a. (Enum a, Bounded a) => Int -> Maybe a 
tryToEnum n = if fromEnum (minBound :: a) <= n && n <= fromEnum (maxBound :: a) then Just (toEnum n) else Nothing 
