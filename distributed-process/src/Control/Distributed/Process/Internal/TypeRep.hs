-- | 'Binary' instances for 'TypeRep', and 'TypeRep' equality (bug workaround)
{-# OPTIONS_GHC -fno-warn-orphans #-}
module Control.Distributed.Process.Internal.TypeRep (compareTypeRep) where

import Control.Applicative ((<$>), (<*>))
import Data.Binary (Binary(get, put))
import Data.Typeable.Internal (TypeRep(..), TyCon(..))
import GHC.Fingerprint.Type (Fingerprint(..))

instance Binary Fingerprint where
  put (Fingerprint hi lo) = put hi >> put lo
  get = Fingerprint <$> get <*> get 

instance Binary TypeRep where
  put (TypeRep fp tyCon ts) = put fp >> put tyCon >> put ts
  get = TypeRep <$> get <*> get <*> get

instance Binary TyCon where
  put (TyCon hash package modul name) = put hash >> put package >> put modul >> put name
  get = TyCon <$> get <*> get <*> get <*> get

-- | Compare two type representations
--
-- For base >= 4.6 this compares fingerprints, but older versions of base
-- have a bug in the fingerprint construction 
-- (<http://hackage.haskell.org/trac/ghc/ticket/5692>)
compareTypeRep :: TypeRep -> TypeRep -> Bool
#if ! MIN_VERSION_base(4,6,0)
compareTypeRep (TypeRep _ con ts) (TypeRep _ con' ts') 
  = con == con' && all (uncurry compareTypeRep) (zip ts ts')
#else
compareTypeRep = (==)
#endif
