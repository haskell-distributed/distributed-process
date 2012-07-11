-- | Derived (TH generated) closures
{-# LANGUAGE MagicHash #-}
module Control.Distributed.Process.Internal.Closure.Derived 
  ( -- * Static functionals
    staticConst
  , staticCompose
  , staticFirst
  , staticSecond
  , staticSplit
    -- * Creating closures
  , staticDecode
  , staticClosure
  , toClosure
    -- * Closure versions of CH primitives
  , cpLink
  , cpUnlink
  , cpSend
  , cpExpect
    -- * @Closure (Process a)@ as a not-quite-monad
  , cpReturn 
  , cpBind
  , cpSeq
    -- * Serialization dictionaries (and their static versions)
  , sdictUnit
  , sdictUnit__static
  , sdictProcessId
  , sdictProcessId__static
    -- * Runtime support
  , __remoteTable
  ) where

import Data.Binary (encode, decode)
import Data.ByteString.Lazy (ByteString, empty)
import Data.Typeable (Typeable, typeOf, TypeRep, typeRepTyCon, TyCon)
import Control.Applicative ((<$>))
import Control.Monad (join)
import Control.Distributed.Process.Serializable (Serializable)
import Control.Distributed.Process.Internal.Types
  ( Closure(Closure)
  , SerializableDict(SerializableDict)
  , Static(Static)
  , StaticLabel
  , Process
  , staticApply
  , ProcessId
  , LocalNode(remoteTable)
  , procMsg
  )
import Control.Distributed.Process.Internal.Primitives 
  ( link
  , unlink
  , send
  , expect
  )
import Control.Distributed.Process.Internal.Closure.TH (remotable, mkStatic)
import Control.Distributed.Process.Internal.MessageT (getLocalNode)
import Control.Distributed.Process.Internal.Closure.Resolution (resolveClosure)
import Control.Distributed.Process.Internal.Dynamic 
  ( Dynamic(Dynamic)
  , dynBind
  , unsafeCoerce#
  , dynTypeRep
  )
import qualified Control.Arrow as Arrow (first, second, (***))

--------------------------------------------------------------------------------
-- Setup: A number of functions that we will pass to 'remotable'              --
--------------------------------------------------------------------------------

---- Type specializations of monadic operations on Processes -------------------

returnProcess :: a -> Process a
returnProcess = return

bindProcess :: Process a -> (a -> Process b) -> Process b
bindProcess = (>>=) 

joinProcess :: Process (Process a) -> Process a
joinProcess = join

---- Functionals ---------------------------------------------------------------

compose :: (b -> c) -> (a -> b) -> a -> c
compose = (.)

first :: (a -> b) -> (a, c) -> (b, c)
first = Arrow.first 

second :: (a -> b) -> (c, a) -> (c, b)
second = Arrow.second

split :: (a -> b) -> (a' -> b') -> (a, a') -> (b, b')
split = (Arrow.***)

---- Variations on standard or CH functions with an explicit dictionary arg ----

decodeDict :: SerializableDict a -> ByteString -> a
decodeDict SerializableDict = decode

sendDict :: SerializableDict a -> ProcessId -> a -> Process ()
sendDict SerializableDict = send

expectDict :: SerializableDict a -> Process a
expectDict SerializableDict = expect

---- Serialization dictionaries ------------------------------------------------

-- | Serialization dictionary for '()' 
--
-- Use @$(mkStatic sdictUnit)@ (instead of 'sdictUnit__static') 
-- to refer to the static dictionary.
sdictUnit :: SerializableDict ()
sdictUnit = SerializableDict

-- | Serialization dictionary for 'ProcessId' 
--
-- Use @$(mkStatic sdictProcessId)@ (instead of 'sdictProcessId__static') 
-- to refer to the static dictionary.
sdictProcessId :: SerializableDict ProcessId
sdictProcessId = SerializableDict

-- | Specialized serialization dictionary required in 'cpBind'
sdictBind :: SerializableDict (((StaticLabel, ByteString), (StaticLabel, ByteString)), TypeRep)
sdictBind = SerializableDict

---- Some specialised processes necessary to implement the combinators ---------

unClosure :: (StaticLabel, ByteString) -> Process Dynamic
unClosure (label, env) = do
  rtable <- remoteTable <$> procMsg getLocalNode 
  case resolveClosure rtable label env of
    Nothing  -> fail "Derived.unClosure: resolveClosure failed"
    Just dyn -> return dyn

unDynamic :: (Process Dynamic, TypeRep) -> Process a
unDynamic (pdyn, typ) = do
  Dynamic typ' val <- pdyn
  if typ == typ'
    then return (unsafeCoerce# val)
    else fail $ "unDynamic: cannot match " 
             ++ show typ' 
             ++ " against expected type " 
             ++ show typ

bindDyn :: (Process Dynamic, Process Dynamic) -> Process Dynamic
bindDyn (px, pf) = do
    x <- px
    f <- pf
    case dynBind tyConProcess bindProcess x f of
      Just dyn -> return dyn
      Nothing  -> fail $ "bindDyn: could not bind " 
                      ++ show (dynTypeRep x) 
                      ++ " to " 
                      ++ show (dynTypeRep f)
  where
    tyConProcess :: TyCon
    tyConProcess = typeRepTyCon (typeOf (undefined :: Process ()))

---- Finally, the call to remotable --------------------------------------------

remotable [ -- Monadic operations
            'returnProcess
          , 'bindProcess
          , 'joinProcess
            -- Functionals (predefined)
          , 'const
            -- Functionals (defined above)
          , 'compose
          , 'first
          , 'second
          , 'split
            -- CH primitives 
          , 'link
          , 'unlink
             -- Explicit dictionaries
          , 'decodeDict
          , 'sendDict
          , 'expectDict
            -- Serialization dictionaries
          , 'sdictUnit
          , 'sdictProcessId
          , 'sdictBind
            -- Specialized processes
          , 'unClosure
          , 'unDynamic
          , 'bindDyn
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
toClosure dict x = Closure decoder (encode x) 
  where
    decoder :: Static (ByteString -> a)
    decoder = $(mkStatic 'decodeDict) `staticApply` dict

--------------------------------------------------------------------------------
-- Closure versions of CH primitives                                          --
--------------------------------------------------------------------------------

-- | Closure version of 'link'
cpLink :: ProcessId -> Closure (Process ())
cpLink pid = Closure decoder (encode pid)
  where
    decoder :: Static (ByteString -> Process ())
    decoder = $(mkStatic 'link)
            `staticCompose`
              ($(mkStatic 'decodeDict) `staticApply` $(mkStatic 'sdictProcessId))

-- | Closure version of 'unlink'
cpUnlink :: ProcessId -> Closure (Process ())
cpUnlink pid = Closure decoder (encode pid)
  where
    decoder :: Static (ByteString -> Process ())
    decoder = $(mkStatic 'unlink)
            `staticCompose`
              ($(mkStatic 'decodeDict) `staticApply` $(mkStatic 'sdictProcessId))

-- | Closure version of 'send'
cpSend :: forall a. Typeable a 
       => Static (SerializableDict a) -> ProcessId -> Closure (a -> Process ())
cpSend dict pid = Closure decoder (encode pid)
  where
    decoder :: Static (ByteString -> a -> Process ())
    decoder = ($(mkStatic 'sendDict) `staticApply` dict)
            `staticCompose` 
              ($(mkStatic 'decodeDict) `staticApply` $(mkStatic 'sdictProcessId)) 

-- | Closure version of 'expect'
cpExpect :: Typeable a => Static (SerializableDict a) -> Closure (Process a)
cpExpect dict = staticClosure ($(mkStatic 'expectDict) `staticApply` dict)

--------------------------------------------------------------------------------
-- (Closure . Process) as a not-quite-monad                                   --
--------------------------------------------------------------------------------

-- | Not-quite-monadic 'return'
cpReturn :: forall a. Serializable a 
         => Static (SerializableDict a) -> a -> Closure (Process a)
cpReturn dict x = Closure decoder (encode x)
  where
    decoder :: Static (ByteString -> Process a)
    decoder = $(mkStatic 'returnProcess) 
            `staticCompose`
              ($(mkStatic 'decodeDict) `staticApply` dict)

-- | Not-quite-monadic bind ('>>=')
cpBind :: forall a b. Typeable b
       => Closure (Process a) -> Closure (a -> Process b) -> Closure (Process b)
cpBind (Closure (Static xlabel) xenv) (Closure (Static flabel) fenv) = 
    let env :: (((StaticLabel, ByteString), (StaticLabel, ByteString)), TypeRep)
        env = (((xlabel, xenv), (flabel, fenv)), typeOf (undefined :: Process b))
    in Closure decoder (encode env)
  where
    decoder :: Static (ByteString -> Process b)
    decoder = aux8
            `staticCompose`
              aux7
            `staticCompose`
              aux6
            `staticCompose`
              aux1

    aux1 :: Static (ByteString -> (((StaticLabel, ByteString), (StaticLabel, ByteString)), TypeRep))
    aux1 = $(mkStatic 'decodeDict) `staticApply` $(mkStatic 'sdictBind)

    aux2 :: Static ((StaticLabel, ByteString) -> Process Dynamic)
    aux2 = $(mkStatic 'unClosure)

    aux3 :: Static (((StaticLabel, ByteString), (StaticLabel, ByteString)) -> (Process Dynamic, Process Dynamic))
    aux3 = aux2 `staticSplit` aux2

    aux4 :: Static ((Process Dynamic, Process Dynamic) -> Process Dynamic)
    aux4 = $(mkStatic 'bindDyn) 

    aux5 :: Static (((StaticLabel, ByteString), (StaticLabel, ByteString)) -> Process Dynamic)
    aux5 = aux4 `staticCompose` aux3 

    aux6 :: Static ((((StaticLabel, ByteString), (StaticLabel, ByteString)), TypeRep) -> (Process Dynamic, TypeRep))
    aux6 = staticFirst `staticApply` aux5 

    aux7 :: Static ((Process Dynamic, TypeRep) -> Process (Process b))
    aux7 = $(mkStatic 'unDynamic)

    aux8 :: Static (Process (Process b) -> Process b)
    aux8 = $(mkStatic 'joinProcess)
  
cpIntro :: forall a b. (Typeable a, Typeable b)
        => Closure (Process b) -> Closure (a -> Process b)
cpIntro (Closure static env) = Closure decoder env 
  where
    decoder :: Static (ByteString -> a -> Process b)
    decoder = staticConst `staticCompose` static
    
-- | Monadic sequencing ('>>')
cpSeq :: Closure (Process ()) -> Closure (Process ()) -> Closure (Process ())
cpSeq p q = p `cpBind` cpIntro q
