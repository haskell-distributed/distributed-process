{-# LANGUAGE DeriveDataTypeable  #-}
{-# LANGUAGE UndecidableInstances  #-}
{-# LANGUAGE FlexibleInstances  #-}
{-# LANGUAGE ScopedTypeVariables  #-}
{-# LANGUAGE GADTs  #-}
module Control.Distributed.Process.Serializable
  ( Serializable
  , encodeFingerprint
  , decodeFingerprint
  , fingerprint
  , sizeOfFingerprint
  , Fingerprint
  , showFingerprint
  , SerializableDict(SerializableDict)
  , TypeableDict(TypeableDict)
  ) where

import Data.Binary (Binary)

import Data.Typeable (Typeable, typeRepFingerprint, typeOf)

import Numeric (showHex)
import Control.Exception (throw)
import GHC.Fingerprint.Type (Fingerprint(..))
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Internal as BSI ( unsafeCreate, toForeignPtr )
import Foreign.Storable (pokeByteOff, peekByteOff, sizeOf)
import Foreign.ForeignPtr (withForeignPtr)
import System.IO.Unsafe (unsafePerformIO)

-- | Reification of 'Serializable' (see "Control.Distributed.Process.Closure")
data SerializableDict a where
    SerializableDict :: Serializable a => SerializableDict a
  deriving (Typeable)

-- | Reification of 'Typeable'.
data TypeableDict a where
    TypeableDict :: Typeable a => TypeableDict a
  deriving (Typeable)

-- | Objects that can be sent across the network
class (Binary a, Typeable a) => Serializable a
instance (Binary a, Typeable a) => Serializable a

-- | Encode type representation as a bytestring
encodeFingerprint :: Fingerprint -> ByteString
encodeFingerprint fp =
  -- Since all CH nodes will run precisely the same binary, we don't have to
  -- worry about cross-arch issues here (like endianness)
  BSI.unsafeCreate sizeOfFingerprint $ \p -> pokeByteOff p 0 fp

-- | Decode a bytestring into a fingerprint. Throws an IO exception on failure
decodeFingerprint :: ByteString -> Fingerprint
decodeFingerprint bs
  | BS.length bs /= sizeOfFingerprint =
      throw $ userError "decodeFingerprint: Invalid length"
  | otherwise = unsafePerformIO $ do
      let (fp, offset, _) = BSI.toForeignPtr bs
      withForeignPtr fp $ \p -> peekByteOff p offset

-- | Size of a fingerprint
sizeOfFingerprint :: Int
sizeOfFingerprint = sizeOf (undefined :: Fingerprint)

-- | The fingerprint of the typeRep of the argument
fingerprint :: Typeable a => a -> Fingerprint
fingerprint = typeRepFingerprint . typeOf

-- | Show fingerprint (for debugging purposes)
showFingerprint :: Fingerprint -> ShowS
showFingerprint (Fingerprint hi lo) =
  showString "(" . showHex hi . showString "," . showHex lo . showString ")"
