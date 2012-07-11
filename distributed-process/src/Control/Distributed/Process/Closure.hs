-- | Implementation of 'Closure' that works around the absence of 'static'.
--
-- [User-defined monomorphic closures]
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
-- In general, given a monomorphic function @f :: T1 -> T2@ the corresponding 
-- function @$(mkClosure 'f)@ will have type @T1 -> Closure T2@.
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
-- [User-defined polymorphic closures]
--
-- Suppose we have a polymorphic function
--
-- > first :: forall a b. (a, b) -> a
-- > first (x, _) = x
--
-- Then the Template Haskell splice
--
-- > remotable ['first]
-- 
-- creates a function
--
-- > $(mkClosure 'first) :: forall a b. (Typeable a, Typeable b)
-- >                     => Closure (a -> b -> a)
--
-- In general, given a polymorphic function @f :: forall a1 .. an. T@ the 
-- corresponding function @$(mkClosure 'f)@ will have type 
-- @forall a1 .. an. (Typeable a1, .., Typeable an) => Closure T@.
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
-- [Serializable Dictionaries]
--
-- Some functions (such as 'sendClosure' or 'returnClosure') require an
-- explicit (reified) serializable dictionary. To create such a dictionary do
--
-- > sdictInt :: SerializableDict Int
-- > sdictInt = SerializableDict 
-- 
-- and then pass @'sdictInt@ to 'remotable'. This will fail if the
-- type is not serializable.
module Control.Distributed.Process.Closure 
  ( -- * User-defined closures
    remotable
  , mkStatic
  , mkClosure
  , functionSDict
    -- * Static functionals
  , staticConst
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
  , SerializableDict(..)
  , staticApply
  , sdictUnit
  , sdictUnit__static
  , sdictProcessId
  , sdictProcessId__static
  ) where 

import Control.Distributed.Process.Internal.Types 
  ( SerializableDict(..)
  , staticApply
  )
import Control.Distributed.Process.Internal.Closure.TH 
  ( remotable
  , mkStatic
  , functionSDict
  )
import Control.Distributed.Process.Internal.Closure.Static
  ( -- Static functionals
    staticConst
  , staticCompose
  , staticFirst
  , staticSecond
  , staticSplit
    -- Creating closures
  , staticDecode
  , staticClosure
  , toClosure
    -- Serialization dictionaries (and their static versions)
  , sdictUnit
  , sdictUnit__static
  , sdictProcessId
  , sdictProcessId__static
  )
import Control.Distributed.Process.Internal.Closure.MkClosure (mkClosure)
import Control.Distributed.Process.Internal.Closure.Derived 
  ( -- Closure versions of CH primitives
    cpLink
  , cpUnlink
  , cpSend
  , cpExpect
    -- @Closure (Process a)@ as a not-quite-monad
  , cpReturn 
  , cpBind
  , cpSeq
  )
