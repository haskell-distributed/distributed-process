-- | Internal functions
module Network.Transport.Internal ( -- * Encoders/decoders
                                    encodeInt32
                                  , decodeInt32
                                  , encodeInt16
                                  , decodeInt16
                                    -- * Miscellaneous abstractions
                                  , maybeToErrorT
                                  ) where

import Data.Int (Int16, Int32)
import Foreign.Storable (pokeByteOff, peekByteOff)
import Foreign.C (CInt(..), CShort(..))
import Foreign.ForeignPtr (withForeignPtr)
import Data.ByteString (ByteString)
import qualified Data.ByteString.Internal as BSI (create, toForeignPtr)
import Control.Monad.Error (ErrorT, Error, throwError)

foreign import ccall unsafe "htonl" htonl :: CInt -> CInt
foreign import ccall unsafe "ntohl" ntohl :: CInt -> CInt
foreign import ccall unsafe "htons" htons :: CShort -> CShort
foreign import ccall unsafe "ntohs" ntohs :: CShort -> CShort

-- | Serialize 32-bit to network byte order 
encodeInt32 :: Int32 -> IO ByteString
encodeInt32 i32 = 
  BSI.create 4 $ \p ->
    pokeByteOff p 0 (htonl (fromIntegral i32))

-- | Deserialize 32-bit from network byte order 
decodeInt32 :: ByteString -> IO Int32
decodeInt32 bs = 
  let (fp, _, _) = BSI.toForeignPtr bs in 
  withForeignPtr fp $ \p -> do
    w32 <- peekByteOff p 0 
    return (fromIntegral (ntohl w32))

-- | Serialize 16-bit to network byte order 
encodeInt16 :: Int16 -> IO ByteString
encodeInt16 i16 = 
  BSI.create 2 $ \p ->
    pokeByteOff p 0 (htons (fromIntegral i16))

-- | Deserialize 16-bit from network byte order 
decodeInt16 :: ByteString -> IO Int16
decodeInt16 bs = 
  let (fp, _, _) = BSI.toForeignPtr bs in 
  withForeignPtr fp $ \p -> do
    w16 <- peekByteOff p 0 
    return (fromIntegral (ntohs w16))

-- | Convert maybe to an ErrorT value 
maybeToErrorT :: (Monad m, Error a) => a -> Maybe b -> ErrorT a m b
maybeToErrorT err Nothing  = throwError err
maybeToErrorT _   (Just x) = return x
