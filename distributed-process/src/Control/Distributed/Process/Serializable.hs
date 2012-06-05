module Control.Distributed.Process.Serializable 
  ( Serializable
  , encodeFingerprint
  , fingerprint
  , Fingerprint
  ) where

import Data.Binary (Binary)
import Data.Typeable (Typeable(..))
import Data.Typeable.Internal (TypeRep(TypeRep))
import GHC.Fingerprint.Type (Fingerprint(Fingerprint))
import Data.ByteString (ByteString)
import qualified Data.ByteString.Internal as BSI (unsafeCreate)
import Foreign.Storable (pokeByteOff)

class (Binary a, Typeable a) => Serializable a
instance (Binary a, Typeable a) => Serializable a

-- | Encode type representation as a bytestring
encodeFingerprint :: Fingerprint -> ByteString
encodeFingerprint (Fingerprint hi lo) = 
  -- Since all CH nodes will run precisely the same binary, we don't have to
  -- worry about cross-arch issues here (like endianness)
  BSI.unsafeCreate 16 $ \p -> do
    pokeByteOff p 0 hi
    pokeByteOff p 8 lo

fingerprint :: Typeable a => a -> Fingerprint
fingerprint a = let TypeRep fp _ _ = typeOf a in fp
