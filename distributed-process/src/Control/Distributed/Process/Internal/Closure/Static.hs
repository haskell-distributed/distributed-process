-- | Combinators on static values 
{-# LANGUAGE MagicHash #-}
module Control.Distributed.Process.Internal.Closure.Static
  ( -- * Static functionals
    staticConst
  , staticCompose
  , staticFirst
  , staticSecond
  , staticSplit
    -- * Static constants
  , staticUnit
    -- * Creating closures
  , staticDecode
  , staticClosure
  , toClosure
    -- * Serialization dictionaries (and their static versions)
  , sdictUnit
  , sdictProcessId
    -- * Runtime support
  , __remoteTable
  ) where

import Data.Binary (encode, decode)
import Data.ByteString.Lazy (ByteString, empty)
import Data.Typeable (Typeable)
import Control.Distributed.Process.Serializable (Serializable)
import Control.Distributed.Process.Internal.Types
  ( Closure(Closure)
  , SerializableDict(SerializableDict)
  , Static
  , staticApply
  , ProcessId
  )
import Control.Distributed.Process.Internal.Closure.TH (remotable, mkStatic)
import qualified Control.Arrow as Arrow (first, second, (***))

--------------------------------------------------------------------------------
-- Setup: A number of functions that we will pass to 'remotable'              --
--------------------------------------------------------------------------------

---- Functionals ---------------------------------------------------------------

compose :: (b -> c) -> (a -> b) -> a -> c
compose = (.)

first :: (a -> b) -> (a, c) -> (b, c)
first = Arrow.first 

second :: (a -> b) -> (c, a) -> (c, b)
second = Arrow.second

split :: (a -> b) -> (a' -> b') -> (a, a') -> (b, b')
split = (Arrow.***)

---- Constants -----------------------------------------------------------------

unit :: ()
unit = ()

---- Variations on standard or CH functions with an explicit dictionary arg ----

decodeDict :: SerializableDict a -> ByteString -> a
decodeDict SerializableDict = decode

---- Serialization dictionaries ------------------------------------------------

sdictUnit_ :: SerializableDict ()
sdictUnit_ = SerializableDict

sdictProcessId_ :: SerializableDict ProcessId
sdictProcessId_ = SerializableDict

---- Finally, the call to remotable --------------------------------------------

remotable [ -- Functionals (predefined)
            'const
            -- Functionals (defined above)
          , 'compose
          , 'first
          , 'second
          , 'split
            -- Constants
          , 'unit
            -- Explicit dictionaries
          , 'decodeDict
            -- Serialization dictionaries
          , 'sdictUnit_
          , 'sdictProcessId_
          ]

--------------------------------------------------------------------------------
-- Static versions of the functionals                                         -- 
-- (We give these explicit names because they are useful outside this module) --
--------------------------------------------------------------------------------

-- | Static version of 'const'
staticConst :: (Typeable a, Typeable b) => Static (a -> b -> a)
staticConst = $(mkStatic 'const)

-- | Static version of ('Prelude..')
staticCompose :: (Typeable a, Typeable b, Typeable c) 
              => Static (b -> c) -> Static (a -> b) -> Static (a -> c)
staticCompose f x = $(mkStatic 'compose) `staticApply` f `staticApply` x 

-- | Static version of 'Control.Arrow.first'
staticFirst :: (Typeable a, Typeable b, Typeable c)
            => Static ((a -> b) -> (a, c) -> (b, c))
staticFirst = $(mkStatic 'first)

-- | Static version of 'Control.Arrow.second'
staticSecond :: (Typeable a, Typeable b, Typeable c)
             => Static ((a -> b) -> (c, a) -> (c, b))
staticSecond = $(mkStatic 'second)

-- | Static version of ('Control.Arrow.***')
staticSplit :: (Typeable a, Typeable b, Typeable c, Typeable d) 
            => Static (a -> c) -> Static (b -> d) -> Static ((a, b) -> (c, d))
staticSplit f g = $(mkStatic 'split) `staticApply` f `staticApply` g 

--------------------------------------------------------------------------------
-- Constants                                                                  --
--------------------------------------------------------------------------------

-- | Static version of '()'
staticUnit :: Static ()
staticUnit = $(mkStatic 'unit)

--------------------------------------------------------------------------------
-- Dictionaries                                                               --
--------------------------------------------------------------------------------

-- | Serialization dictionary for '()' 
sdictUnit :: Static (SerializableDict ())
sdictUnit = $(mkStatic 'sdictUnit_)

-- | Serialization dictionary for 'ProcessId' 
sdictProcessId :: Static (SerializableDict ProcessId)
sdictProcessId = $(mkStatic 'sdictProcessId_)

--------------------------------------------------------------------------------
-- Creating closures                                                          --
--------------------------------------------------------------------------------

staticDecode :: Typeable a => Static (SerializableDict a) -> Static (ByteString -> a)
staticDecode dict = $(mkStatic 'decodeDict) `staticApply` dict 

staticClosure :: forall a. Typeable a => Static a -> Closure a
staticClosure static = Closure decoder empty
  where
    decoder :: Static (ByteString -> a)
    decoder = staticConst `staticApply` static 

toClosure :: forall a. Serializable a 
          => Static (SerializableDict a) -> a -> Closure a
toClosure dict x = Closure (staticDecode dict) (encode x) 
