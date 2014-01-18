{-# LANGUAGE DeriveDataTypeable  #-}
{-# LANGUAGE DeriveGeneric       #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving  #-}

-- | If you don't know exactly what this module is for and precisely
-- how to use the types within, you should move on, quickly!
--
module Control.Distributed.Process.Platform.Internal.Unsafe
  ( -- * Copying non-serializable data
    PCopy()
  , pCopy
  , matchP
  , matchChanP
  , pUnwrap
    -- * Arbitrary (unmanaged) message streams
  , InputStream(Null)
  , newInputStream
  , matchInputStream
  , InvalidBinaryShim(..)
  ) where

import Control.Concurrent.STM (STM, atomically)
import Control.Exception (throwIO)
import Control.Distributed.Process
  ( matchAny
  , matchChan
  , matchSTM
  , handleMessage
  , unsafeSendChan
  , sendChan
  , liftIO
  , Match
  , SendPort
  , ReceivePort
  , Message
  , Process
  )
import Control.Distributed.Process.Serializable
import Control.Distributed.Process.Platform.Internal.Types
  ( Routable(..)
  )
import Data.Binary
import Control.DeepSeq (NFData)
import Data.Typeable (Typeable)
import GHC.Generics

data InvalidBinaryShim = InvalidBinaryShim
  deriving (Typeable, Show, Eq)

-- NB: PCopy is a shim, allowing us to copy a pointer to otherwise
-- non-serializable data directly to another local process'
-- mailbox with no serialisation or even deepseq evaluation
-- required. We disallow remote queries (i.e., from other nodes)
-- and thus the Binary instance below is never used (though it's
-- required by the type system) and will in fact generate errors if
-- you attempt to use it at runtime. In other words, if you attempt
-- to make a @Message@ out of this, you'd better make sure you're
-- calling @unsafeCreateUnencodedMessage@, otherwise BOOM. You have
-- been warned.
--
data PCopy a = PCopy !a
  deriving (Typeable, Generic)
instance (NFData a) => NFData (PCopy a) where

instance (Typeable a) => Binary (PCopy a) where
  put _ = error "InvalidBinaryShim"
  get   = error "InvalidBinaryShim"

pCopy :: (Typeable a) => a -> PCopy a
pCopy = PCopy

-- | Matches on @PCopy m@ and returns the /m/ within.
-- This potentially allows us to bypass serialization (and the type constraints
-- it enforces) for local message passing (i.e., with @UnencodedMessage@ data),
-- since PCopy is just a shim.
matchP :: (Typeable m) => Match (Maybe m)
matchP = matchAny pUnwrap

pUnwrap :: (Typeable m) => Message -> Process (Maybe m)
pUnwrap m = handleMessage m (\(PCopy m' :: PCopy m) -> return m')

-- | Matches on a @TypedChannel (PCopy a)@.
matchChanP :: (Typeable m) => ReceivePort (PCopy m) -> Match m
matchChanP rp = matchChan rp (\(PCopy m' :: PCopy m) -> return m')

-- | A generic input channel that can read from either a ReceivePort or
-- an arbitrary STM action. Used internally when we want to allow internal
-- clients to completely bypass regular messaging primitives, which is
-- a rare but occaisionally useful thing.
--
data InputStream a = ReadChan (ReceivePort a) | ReadSTM (STM a) | Null
  deriving (Typeable)

-- | Create a new 'InputStream'.
newInputStream :: forall a. (Typeable a)
               => Either (ReceivePort a) (STM a)
               -> InputStream a
newInputStream (Left rp)   = ReadChan rp
newInputStream (Right stm) = ReadSTM stm

-- | Constructs a @Match@ for a given 'InputChannel'.
matchInputStream :: InputStream a -> Match a
matchInputStream (ReadChan rp) = matchChan rp return
matchInputStream (ReadSTM stm) = matchSTM stm return

