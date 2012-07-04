-- | Implementation of 'Closure' that works around the absence of 'static'.
--
-- [Built-in closures]
--
-- We offer a number of standard commonly useful closures.
--
-- [Closure combinators]
--
-- Closures combinators allow to create closures from other closures. For
-- example, 'spawnSupervised' is defined as follows:
--
-- > spawnSupervised :: NodeId 
-- >                 -> Closure (Process ()) 
-- >                 -> Process (ProcessId, MonitorRef)
-- > spawnSupervised nid proc = do
-- >   us   <- getSelfPid
-- >   them <- spawn nid (linkClosure us `cpSeq` proc) 
-- >   ref  <- monitor them
-- >   return (them, ref)
--
-- [User-defined closures]
--
-- Suppose we have a monomorphic function
--
-- > addInt :: Int -> Int -> Int
-- > addInt x y = x + y
--
-- Then the Template Haskell splice
--
-- > remotable ['addInt]
-- 
-- creates a function 
--
-- > $(mkClosure 'addInt) :: Int -> Closure (Int -> Int)
-- 
-- which can be used to partially apply 'addInt' and turn it into a 'Closure',
-- which can be sent across the network. Closures can be deserialized with 
--
-- > unClosure :: Typeable a => Closure a -> Process a
--
-- In general, given a monomorphic function @f :: a -> b@ the corresponding 
-- function @$(mkClosure 'f)@ will have type @a -> Closure b@.
--
-- The call to 'remotable' will also generate a function
--
-- > __remoteTable :: RemoteTable -> RemoteTable
--
-- which can be used to construct the 'RemoteTable' used to initialize
-- Cloud Haskell. You should have (at most) one call to 'remotable' per module,
-- and compose all created functions when initializing Cloud Haskell:
--
-- > let rtable = M1.__remoteTable
-- >            . M2.__remoteTable
-- >            . ...
-- >            . Mn.__remoteTable
-- >            $ initRemoteTable 
--
-- See Section 6, /Faking It/, of /Towards Haskell in the Cloud/ for more info. 
--
-- [Serializable Dictionaries]
--
-- Some functions (such as 'sendClosure' or 'returnClosure') require an
-- explicit (reified) serializable dictionary. To create such a dictionary do
--
-- > serializableDictInt :: SerializableDict Int
-- > serializableDictInt = SerializableDict 
-- 
-- and then pass @'serializableDictInt@ to 'remotable'. This will fail if the
-- type is not serializable.
module Control.Distributed.Process.Closure 
  ( -- * User-defined closures
    remotable
  , mkClosure
  , SerializableDict(..)
    -- * Built-in closures
  , linkClosure
  , unlinkClosure
  , sendClosure
  , returnClosure
  , expectClosure
    -- * Generic closure combinators
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
  , cpApply
    -- * Derived combinators for processes
  , cpBind
  , cpSeq
  ) where 

import Control.Distributed.Process.Internal.Types (SerializableDict(..))
import Control.Distributed.Process.Internal.Closure.TH (remotable, mkClosure)
import Control.Distributed.Process.Internal.Closure.BuiltIn 
  ( linkClosure
  , unlinkClosure
  , sendClosure
  , returnClosure
  , expectClosure
  )
import Control.Distributed.Process.Internal.Closure.Combinators 
  ( -- Generic combinators
    closureApply
  , closureConst
  , closureUnit
    -- Arrow combinators for processes
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
  , cpApply
    -- Derived process operators
  , cpBind
  , cpSeq
  )
