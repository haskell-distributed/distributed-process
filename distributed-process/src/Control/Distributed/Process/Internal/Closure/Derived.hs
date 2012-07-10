-- | Derived (TH generated) closures
module Control.Distributed.Process.Internal.Closure.Derived
  ( remoteTable
    -- * Process primitives
  , linkClosure
  , unlinkClosure
    -- * Generic combinators
  , closureApply
  , closureConst
  , closureUnit
    -- * Arrow combinators for processes
  , CP
  , cpIntro
  , cpElim
  , cpId
  , cpComp
  , cpFirst
  , cpSwap
  , cpSecond
  , cpPair
  , cpCopy
  , cpFanOut
  , cpLeft
  , cpMirror
  , cpRight
  , cpEither
  , cpUntag
  , cpFanIn
    -- * Derived process operators
  , cpBind
  , cpSeq
    -- * Serialization dictionaries
  , serializableDictUnit
  ) where

import Prelude hiding (lookup)
import Data.Typeable (Typeable)
import Data.Tuple (swap)
import Control.Applicative ((<$>))
import Control.Monad ((>=>))
import Control.Distributed.Process.Internal.Types
  ( Closure(..)
  , Process
  , RemoteTable
  , SerializableDict(..)
  , ProcessId
  )
import Control.Distributed.Process.Internal.TypeRep () -- Binary instances
import Control.Distributed.Process.Internal.Closure.TH (remotable, mkClosure)
import Control.Distributed.Process.Internal.Primitives 
  ( link
  , unlink
  )
import Control.Distributed.Process.Internal.Closure.BuiltIn (closureApply)

--------------------------------------------------------------------------------
-- TH stuff                                                                   --
--------------------------------------------------------------------------------

idUnit :: () -> ()
idUnit = id

returnProcess :: a -> Process a
returnProcess = return

kleisliComposeProcess :: (a -> Process b) -> (b -> Process c) -> a -> Process c
kleisliComposeProcess = (>=>) 

firstProcess :: (a -> Process b) -> (a, c) -> Process (b, c)
firstProcess f (a, c) = f a >>= \b -> return (b, c)

swapProcess :: (a, b) -> Process (b, a)
swapProcess = return . swap  

copyProcess :: a -> Process (a, a)
copyProcess x = return (x, x)

leftProcess :: (a -> Process b) -> Either a c -> Process (Either b c)
leftProcess f (Left a)  = Left  <$> f a
leftProcess _ (Right b) = Right <$> return b

mirrorProcess :: Either a b -> Process (Either b a)
mirrorProcess (Left x)  = Right <$> return x 
mirrorProcess (Right y) = Left  <$> return y 

untagProcess :: Either a a -> Process a
untagProcess (Left x)  = return x
untagProcess (Right y) = return y

serializableDictUnit :: SerializableDict ()
serializableDictUnit = SerializableDict

remotable [ 'const
          , 'idUnit
          , 'returnProcess
          , 'kleisliComposeProcess
          , 'firstProcess
          , 'swapProcess
          , 'copyProcess
          , 'leftProcess
          , 'mirrorProcess
          , 'untagProcess
          , 'link
          , 'unlink
          , 'serializableDictUnit
          ]

remoteTable :: RemoteTable -> RemoteTable
remoteTable = __remoteTable

--------------------------------------------------------------------------------
-- Process primitives                                                         --
--------------------------------------------------------------------------------

-- | Closure version of 'link'
linkClosure :: ProcessId -> Closure (Process ())
linkClosure = $(mkClosure 'link)

-- | Closure version of 'unlink'
unlinkClosure :: ProcessId -> Closure (Process ())
unlinkClosure = $(mkClosure 'unlink)

--------------------------------------------------------------------------------
-- Generic closure combinators                                                -- 
--------------------------------------------------------------------------------

closureConst :: (Typeable a, Typeable b) => Closure (a -> b -> a)
closureConst = $(mkClosure 'const) 

closureUnit :: Closure ()
closureUnit = $(mkClosure 'idUnit) () 

--------------------------------------------------------------------------------
-- Arrow combinators for processes                                            -- 
--------------------------------------------------------------------------------

type CP a b = Closure (a -> Process b)

cpIntro :: (Typeable a, Typeable b)
        => Closure (Process b) -> CP a b 
cpIntro = closureApply closureConst 

cpElim :: Typeable a 
       => CP () a -> Closure (Process a)
cpElim = flip closureApply closureUnit 

cpId :: Typeable a => CP a a 
cpId = $(mkClosure 'returnProcess) 

cpComp :: (Typeable a, Typeable b, Typeable c) => CP a b -> CP b c -> CP a c
cpComp f g = $(mkClosure 'kleisliComposeProcess) `closureApply` f `closureApply` g 

cpFirst :: (Typeable a, Typeable b, Typeable c) => CP a b -> CP (a, c) (b, c)
cpFirst = closureApply $(mkClosure 'firstProcess) 

cpSwap :: (Typeable a, Typeable b) => CP (a, b) (b, a)
cpSwap = $(mkClosure 'swapProcess) 

cpSecond :: (Typeable a, Typeable b, Typeable c) => CP a b -> CP (c, a) (c, b)
cpSecond f = cpSwap `cpComp` cpFirst f `cpComp` cpSwap

cpPair :: (Typeable a, Typeable a', Typeable b, Typeable b')
       => CP a b -> CP a' b' -> CP (a, a') (b, b')
cpPair f g = cpFirst f `cpComp` cpSecond g

cpCopy :: Typeable a => CP a (a, a)
cpCopy = $(mkClosure 'copyProcess)

cpFanOut :: (Typeable a, Typeable b, Typeable c) 
         => CP a b -> CP a c -> CP a (b, c)
cpFanOut f g = cpCopy `cpComp` (f `cpPair` g)         

cpLeft :: (Typeable a, Typeable b, Typeable c) 
       => CP a b -> CP (Either a c) (Either b c)
cpLeft = closureApply $(mkClosure 'leftProcess) 

cpMirror :: (Typeable a, Typeable b) => CP (Either a b) (Either b a)
cpMirror = $(mkClosure 'mirrorProcess) 

cpRight :: (Typeable a, Typeable b, Typeable c) 
        => CP a b -> CP (Either c a) (Either c b)
cpRight f = cpMirror `cpComp` cpLeft f `cpComp` cpMirror 

cpEither :: (Typeable a, Typeable a', Typeable b, Typeable b')
         => CP a b -> CP a' b' -> CP (Either a a') (Either b b')
cpEither f g = cpLeft f `cpComp` cpRight g

cpUntag :: Typeable a => CP (Either a a) a
cpUntag = $(mkClosure 'untagProcess) 

cpFanIn :: (Typeable a, Typeable b, Typeable c) 
        => CP a c -> CP b c -> CP (Either a b) c
cpFanIn f g = (f `cpEither` g) `cpComp` cpUntag 

--------------------------------------------------------------------------------
-- Some derived operators for processes                                       -- 
--------------------------------------------------------------------------------

cpBind :: (Typeable a, Typeable b) 
       => Closure (Process a) -> Closure (a -> Process b) -> Closure (Process b)
cpBind x f = cpElim $ cpIntro x `cpComp` f

cpSeq :: Closure (Process ()) -> Closure (Process ()) -> Closure (Process ())
cpSeq p q = p `cpBind` cpIntro q
