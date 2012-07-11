-- | Derived (TH generated) closures
{-# LANGUAGE MagicHash #-}
module Control.Distributed.Process.Internal.Closure.Derived 
  ( -- * Closure versions of CH primitives
    cpLink
  , cpUnlink
  , cpSend
  , cpExpect
    -- * @Closure (Process a)@ as a not-quite-monad
  , cpReturn 
  , cpBind
  , cpSeq
    -- * Runtime support
  , __remoteTable
  ) where

import Data.Binary (encode)
import Data.ByteString.Lazy (ByteString)
import Data.Typeable (Typeable, typeOf, typeRepTyCon, TyCon)
import Control.Applicative ((<$>))
import Control.Monad (join)
import Control.Distributed.Process.Serializable (Serializable)
import Control.Distributed.Process.Internal.Types
  ( Closure(Closure)
  , SerializableDict(SerializableDict)
  , Static(Static)
  , Process
  , staticApply
  , staticDuplicate
  , staticTypeOf
  , typeOfStaticLabel
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
import Control.Distributed.Process.Internal.Closure.Static 
  ( staticCompose
  , staticDecode
  , staticClosure
  , staticSplit
  , staticConst
  , staticUnit
  , sdictProcessId
  , sdictProcessId__static
  )
import Control.Distributed.Process.Internal.Closure.MkClosure (mkClosure)
import Control.Distributed.Process.Internal.Dynamic 
  ( Dynamic(Dynamic)
  , dynBind
  , unsafeCoerce#
  , dynTypeRep
  )

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

---- Variations on standard or CH functions with an explicit dictionary arg ----

sendDict :: SerializableDict a -> ProcessId -> a -> Process ()
sendDict SerializableDict = send

expectDict :: SerializableDict a -> Process a
expectDict SerializableDict = expect

---- Serialization dictionaries ------------------------------------------------

-- | Specialized serialization dictionary required in 'cpBind'
sdictBind :: SerializableDict (ByteString, ByteString)
sdictBind = SerializableDict

---- Some specialised processes necessary to implement the combinators ---------

-- | Resolve a closure
unClosure :: Static a -> ByteString -> Process Dynamic
unClosure (Static label) env = do
  rtable <- remoteTable <$> procMsg getLocalNode 
  case resolveClosure rtable label env of
    Nothing  -> fail "Derived.unClosure: resolveClosure failed"
    Just dyn -> return dyn

-- | Remove a 'Dynamic' constructor, provided that the recorded type matches the
-- type of the first static argument (the value of that argument is not used)
unDynamic :: Static a -> Process Dynamic -> Process a
unDynamic (Static label) pdyn = do
  Dynamic typ val <- pdyn
  if typ == typeOfStaticLabel label 
    then return (unsafeCoerce# val)
    else fail $ "unDynamic: cannot match " 
             ++ show typ
             ++ " against expected type " 
             ++ show (typeOfStaticLabel label)

-- | Dynamic bind
--
-- The first argument stops remotable from trying to generate a SerializableDict
-- for (Process Dynamic, Process Dynamic)
bindDyn :: () -> (Process Dynamic, Process Dynamic) -> Process Dynamic
bindDyn () (px, pf) = do
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
            -- CH primitives 
          , 'link
          , 'unlink
            -- Explicit dictionaries
          , 'sendDict
          , 'expectDict
            -- Serialization dictionaries
          , 'sdictBind
            -- Specialized processes
          , 'unClosure
          , 'unDynamic
          , 'bindDyn
          ]

--------------------------------------------------------------------------------
-- Closure versions of CH primitives                                          --
--------------------------------------------------------------------------------

-- | Closure version of 'link'
cpLink :: ProcessId -> Closure (Process ())
cpLink = $(mkClosure 'link)

-- | Closure version of 'unlink'
cpUnlink :: ProcessId -> Closure (Process ())
cpUnlink = $(mkClosure 'unlink)

-- | Closure version of 'send'
cpSend :: forall a. Typeable a 
       => Static (SerializableDict a) -> ProcessId -> Closure (a -> Process ())
cpSend dict pid = Closure decoder (encode pid)
  where
    decoder :: Static (ByteString -> a -> Process ())
    decoder = ($(mkStatic 'sendDict) `staticApply` dict)
            `staticCompose` 
              staticDecode $(mkStatic 'sdictProcessId)

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
              staticDecode dict


staticUnclosure :: Typeable a 
                => Static a -> Static (ByteString -> Process Dynamic)
staticUnclosure s = 
  $(mkStatic 'unClosure) `staticApply` staticDuplicate s 

staticUndynamic :: Typeable a => Static (Process Dynamic -> Process a)
staticUndynamic = 
  $(mkStatic 'unDynamic) `staticApply` staticDuplicate (staticTypeOf (undefined :: a))

staticBindDyn :: Static ((Process Dynamic, Process Dynamic) -> Process Dynamic)
staticBindDyn = $(mkStatic 'bindDyn) `staticApply` staticUnit 

-- | Not-quite-monadic bind ('>>=')
cpBind :: forall a b. (Typeable a, Typeable b)
       => Closure (Process a) -> Closure (a -> Process b) -> Closure (Process b)
cpBind (Closure xstatic xenv) (Closure fstatic fenv) = 
    Closure decoder (encode (xenv, fenv))
  where
    decoder :: Static (ByteString -> Process b)
    decoder = $(mkStatic 'joinProcess)
            `staticCompose`
              staticUndynamic 
            `staticCompose`
              staticBindDyn 
            `staticCompose`
              (staticUnclosure xstatic `staticSplit` staticUnclosure fstatic) 
            `staticCompose`
              staticDecode $(mkStatic 'sdictBind)   

cpIntro :: forall a b. (Typeable a, Typeable b)
        => Closure (Process b) -> Closure (a -> Process b)
cpIntro (Closure static env) = Closure decoder env 
  where
    decoder :: Static (ByteString -> a -> Process b)
    decoder = staticConst `staticCompose` static
    
-- | Monadic sequencing ('>>')
cpSeq :: Closure (Process ()) -> Closure (Process ()) -> Closure (Process ())
cpSeq p q = p `cpBind` cpIntro q
