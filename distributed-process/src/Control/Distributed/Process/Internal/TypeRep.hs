-- | 'Binary' instances for 'TypeRep'
{-# OPTIONS_GHC -fno-warn-orphans #-}
module Control.Distributed.Process.Internal.TypeRep () where

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

