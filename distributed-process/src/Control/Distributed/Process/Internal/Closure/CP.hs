-- | Combinator for process closures 
{-# LANGUAGE MagicHash #-}
module Control.Distributed.Process.Internal.Closure.CP
  ( -- * Definition of CP and the generalized arrow combinators
    CP
  , cpIntro
  , cpElim
  , cpId
  , cpComp
  , cpFirst
  , cpSecond
  , cpSplit
  , cpCancelL
  , cpCancelR
    -- * Closure versions of CH primitives
  , cpLink
  , cpUnlink
  , cpSend
  , cpExpect
  , cpNewChan
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
import Data.Typeable.Internal (TypeRep(..))
import Control.Applicative ((<$>))
import Control.Monad ((>=>))
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
  , SendPort
  , ReceivePort
  )
import Control.Distributed.Process.Internal.Primitives 
  ( link
  , unlink
  , send
  , expect
  , newChan
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
  , staticFlip
  , staticFst
  , staticSnd
  , sdictProcessId
  )
import Control.Distributed.Process.Internal.Closure.MkClosure (mkClosure)
import Control.Distributed.Process.Internal.Dynamic 
  ( Dynamic(Dynamic)
  , unsafeCoerce#
  , dynTypeRep
  , dynKleisli
  )

--------------------------------------------------------------------------------
-- Setup: A number of functions that we will pass to 'remotable'              --
--------------------------------------------------------------------------------

---- Type specializations of monadic operations on Processes -------------------

returnProcess :: a -> Process a
returnProcess = return

bindProcess :: Process a -> (a -> Process b) -> Process b
bindProcess = (>>=) 

kleisliProcess :: (a -> Process b) -> (b -> Process c) -> a -> Process c
kleisliProcess = (>=>)

parJoinProcess :: Process (a -> Process b) -> a -> Process b
parJoinProcess proc a = proc >>= ($ a)

---- Variations on standard or CH functions with an explicit dictionary arg ----

sendDict :: SerializableDict a -> ProcessId -> a -> Process ()
sendDict SerializableDict = send

expectDict :: SerializableDict a -> Process a
expectDict SerializableDict = expect

newChanDict :: SerializableDict a -> Process (SendPort a, ReceivePort a)
newChanDict SerializableDict = newChan

---- Serialization dictionaries ------------------------------------------------

-- | Specialized serialization dictionary required in 'cpBind'
sdictComp :: SerializableDict (ByteString, ByteString)
sdictComp = SerializableDict

---- Some specialised processes necessary to implement the combinators ---------

-- | Resolve a closure
unClosure :: Static a -> ByteString -> Process Dynamic
unClosure (Static label) env = do
  rtable <- remoteTable <$> procMsg getLocalNode 
  case resolveClosure rtable label env of
    Nothing  -> fail "Derived.unClosure: resolveClosure failed"
    Just dyn -> return dyn

-- | Work around a bug in Typeable
-- (http://hackage.haskell.org/trac/ghc/ticket/5692)
compareWithoutFingerprint :: TypeRep -> TypeRep -> Bool
compareWithoutFingerprint (TypeRep _ con ts) (TypeRep _ con' ts') 
  = con == con' && all (uncurry compareWithoutFingerprint) (zip ts ts')

-- | Remove a 'Dynamic' constructor, provided that the recorded type matches the
-- type of the first static argument (the value of that argument is not used)
unDynamic :: Static a -> Process Dynamic -> Process a
unDynamic (Static label) pdyn = do
  Dynamic typ val <- pdyn
  if compareWithoutFingerprint typ (typeOfStaticLabel label) -- typ == typeOfStaticLabel label 
    then return (unsafeCoerce# val)
    else fail $ "unDynamic: cannot match " 
             ++ show typ
             ++ " against expected type " 
             ++ show (typeOfStaticLabel label)

-- | Dynamic kleisli composition
--
-- The first argument stops remotable from trying to generate a SerializableDict
-- for (Process Dynamic, Process Dynamic)
kleisliCompDyn :: () -> (Process Dynamic, Process Dynamic) -> Process Dynamic
kleisliCompDyn () (pf, pg) = do
    f <- pf -- a -> Process b
    g <- pg -- b -> Process c
    case dynKleisli tyConProcess kleisliProcess f g of
      Just dyn -> return dyn
      Nothing  -> fail $ "kleisliCompDyn: could not compose "
                      ++ show (dynTypeRep f)
                      ++ " with "
                      ++ show (dynTypeRep g)
  where
    tyConProcess :: TyCon
    tyConProcess = typeRepTyCon (typeOf (undefined :: Process ()))

cpFirstAux :: (a -> Process b) -> (a, c) -> Process (b, c)
cpFirstAux f (a, c) = f a >>= \b -> return (b, c) 

cpSecondAux :: (a -> Process b) -> (c, a) -> Process (c, b)
cpSecondAux f (c, a) = f a >>= \b -> return (c, b) 

---- Finally, the call to remotable --------------------------------------------

remotable [ -- Monadic operations
            'returnProcess
          , 'bindProcess
          , 'parJoinProcess
            -- CH primitives 
          , 'link
          , 'unlink
            -- Explicit dictionaries
          , 'sendDict
          , 'expectDict
          , 'newChanDict
            -- Serialization dictionaries
          , 'sdictComp
            -- Specialized processes
          , 'unClosure
          , 'unDynamic
          , 'kleisliCompDyn
          , 'cpFirstAux
          , 'cpSecondAux
          ]

--------------------------------------------------------------------------------
-- Some derived static functions                                              --
--------------------------------------------------------------------------------

staticUndynamic :: Typeable a => Static (Process Dynamic -> Process a)
staticUndynamic = 
  $(mkStatic 'unDynamic) `staticApply` staticDuplicate (staticTypeOf (undefined :: a))

staticKleisliCompDyn :: Static ((Process Dynamic, Process Dynamic) -> Process Dynamic)
staticKleisliCompDyn = $(mkStatic 'kleisliCompDyn) `staticApply` staticUnit 

--------------------------------------------------------------------------------
-- Definition of CP and the generalized arrow combinators                     --
--------------------------------------------------------------------------------

-- | 'CP a b' represents the closure of a process parameterized by 'a' and
-- returning 'b'. 'CP a b' forms a (restricted) generalized arrow
-- (<http://www.cs.berkeley.edu/~megacz/garrows/>)
type CP a b = Closure (a -> Process b)

-- | 'CP' introduction form 
cpIntro :: forall a b. (Typeable a, Typeable b)
        => Closure (Process b) -> Closure (a -> Process b)
cpIntro (Closure static env) = Closure decoder env 
  where
    decoder :: Static (ByteString -> a -> Process b)
    decoder = staticConst `staticCompose` static

-- | 'CP' elimination form
cpElim :: forall a. Typeable a => CP () a -> Closure (Process a)
cpElim (Closure static env) = Closure decoder env
  where
    decoder :: Static (ByteString -> Process a)
    decoder = staticFlip static `staticApply` staticUnit 

-- | Identity ('Closure' version of 'return')
cpId :: Typeable a => CP a a
cpId = staticClosure $(mkStatic 'returnProcess)

-- | Left-to-right composition ('Closure' version of '>=>')
cpComp :: forall a b c. (Typeable a, Typeable b, Typeable c)
       => CP a b -> CP b c -> CP a c
cpComp (Closure fstatic fenv) (Closure gstatic genv) =
    Closure decoder (encode (fenv, genv))
  where
    decoder :: Static (ByteString -> a -> Process c)
    decoder = $(mkStatic 'parJoinProcess)
            `staticCompose`
              staticUndynamic
            `staticCompose`
              staticKleisliCompDyn
            `staticCompose`
              (staticUnclosure fstatic `staticSplit` staticUnclosure gstatic)
            `staticCompose`
              staticDecode $(mkStatic 'sdictComp)    

-- | First
cpFirst :: forall a b c. (Typeable a, Typeable b, Typeable c)
        => CP a b -> CP (a, c) (b, c)
cpFirst (Closure static env) = Closure decoder env
  where
    decoder :: Static (ByteString -> (a, c) -> Process (b, c))
    decoder = $(mkStatic 'cpFirstAux) `staticCompose` static

-- | Second 
cpSecond :: forall a b c. (Typeable a, Typeable b, Typeable c)
        => CP a b -> CP (c, a) (c, b)
cpSecond (Closure static env) = Closure decoder env
  where
    decoder :: Static (ByteString -> (c, a) -> Process (c, b))
    decoder = $(mkStatic 'cpSecondAux) `staticCompose` static

-- | Split (Like 'Control.Arrow.***')
cpSplit :: (Typeable a, Typeable b, Typeable c, Typeable d)
        => CP a c -> CP b d -> CP (a, b) (c, d)
cpSplit f g = cpFirst f `cpComp` cpSecond g

-- | Left cancellation
cpCancelL :: Typeable a => CP ((), a) a
-- Closure (((), a) -> Process a)
cpCancelL = staticClosure ($(mkStatic 'returnProcess) `staticCompose` staticSnd) 

-- | Right cancellation
cpCancelR :: Typeable a => CP (a, ()) a
cpCancelR = staticClosure ($(mkStatic 'returnProcess) `staticCompose` staticFst)

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
              staticDecode sdictProcessId 

-- | Closure version of 'expect'
cpExpect :: Typeable a => Static (SerializableDict a) -> Closure (Process a)
cpExpect dict = staticClosure ($(mkStatic 'expectDict) `staticApply` dict)

-- | Closure version of 'newChan'
cpNewChan :: Typeable a 
          => Static (SerializableDict a) 
          -> Closure (Process (SendPort a, ReceivePort a))
cpNewChan dict = staticClosure ($(mkStatic 'newChanDict) `staticApply` dict)

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

-- | Not-quite-monadic bind ('>>=')
cpBind :: forall a b. (Typeable a, Typeable b)
       => Closure (Process a) -> Closure (a -> Process b) -> Closure (Process b)
cpBind x f = cpElim (cpIntro x `cpComp` f)

-- | Monadic sequencing ('>>')
cpSeq :: Closure (Process ()) -> Closure (Process ()) -> Closure (Process ())
cpSeq p q = p `cpBind` cpIntro q
