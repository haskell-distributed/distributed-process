-- | Static values and Closures
--
-- [Static values]
--
-- /Towards Haskell in the Cloud/ (Epstein et al., Haskell Symposium 2011) 
-- proposes a new type construct called 'static' that characterizes values that
-- are known statically. There is no support for 'static' in ghc yet, however,
-- so we emulate it using Template Haskell. Given a top-level definition
--
-- > f :: forall a1 .. an. T
-- > f = ...
--
-- you can use a Template Haskell splice to create a static version of 'f':
-- 
-- > $(mkStatic 'f) :: forall a1 .. an. Static T
-- 
-- Every module that you write that contains calls to 'mkStatic' needs to
-- have a call to 'remotable':
--
-- > remotable [ 'f, 'g, ... ]
--
-- where you must pass every function (or other value) that you pass as an 
-- argument to 'mkStatic'. The call to 'remotable' will create a definition
--
-- > __remoteTable :: RemoteTable -> RemoteTable
--
-- which can be used to construct the 'RemoteTable' used to initialize
-- Cloud Haskell. You should have (at most) one call to 'remotable' per module,
-- and compose all created functions when initializing Cloud Haskell:
--
-- > let rtable :: RemoteTable 
-- >     rtable = M1.__remoteTable
-- >            . M2.__remoteTable
-- >            . ...
-- >            . Mn.__remoteTable
-- >            $ initRemoteTable 
--
-- [Composing static values]
--
-- We generalize the notion of 'static' as described in the paper, and also
-- provide
--
-- > staticApply :: Static (a -> b) -> Static a -> Static b
--
-- This makes it possible to define a rich set of combinators on 'static'
-- values, a number of which are provided in this module.
--
-- [Closures]
--
-- Suppose you have a process
--
-- > factorial :: Int -> Process Int
--
-- Then you can use the supplied Template Haskell function 'mkClosure' to define
--
-- > factorialClosure :: Int -> Closure (Process Int)
-- > factorialClosure = $(mkClosure 'factorial)
--
-- You can then pass 'factorialClosure n' to 'spawn', for example, to have a
-- remote node compute a factorial number.
--
-- In general, if you have a /monomorphic/ function
--
-- > f :: T1 -> T2
-- 
-- then
--
-- > $(mkClosure 'f) :: T1 -> Closure T2
--
-- provided that 'T1' is serializable (*).
--
-- [Creating closures manually]
--
-- You don't /need/ to use 'mkClosure', however.  Closures are defined exactly
-- as described in /Towards Haskell in the Cloud/:
-- 
-- > data Closure a = Closure (Static (ByteString -> a)) ByteString
--
-- The splice @$(mkClosure 'factorial)@ above expands to (prettified a bit): 
-- 
-- > factorialClosure :: Int -> Closure (Process Int)
-- > factorialClosure n = Closure decoder (encode n)
-- >   where
-- >     decoder :: Static (ByteString -> Process Int)
-- >     decoder = $(mkStatic 'factorial) 
-- >             `staticCompose`  
-- >               staticDecode $(functionSDict 'factorial)
--
-- 'mkStatic' we have already seen:
--
-- > $(mkStatic 'factorial) :: Static (Int -> Process Int)
--
-- 'staticCompose' is function composition on static functions. 'staticDecode'
-- has type (**)
--
-- > staticDecode :: Typeable a 
-- >              => Static (SerializableDict a) -> Static (ByteString -> a)
--
-- and gives you a static decoder, given a static Serializable dictionary.
-- 'SerializableDict' is a reified type class dictionary, and defined simply as
-- 
-- > data SerializableDict a where
-- >   SerializableDict :: Serializable a => SerializableDict a
--
-- That means that for any serialziable type 'T', you can define
--
-- > sdictForMyType :: SerializableDict T
-- > sdictForMyType = SerializableDict
--
-- and then use
--
-- > $(mkStatic 'sdictForMyType) :: Static (SerializableDict T)
--
-- to obtain a static serializable dictionary for 'T' (make sure to pass
-- 'sdictForMyType' to 'remotable'). 
-- 
-- However, since these serialization dictionaries are so frequently required,
-- when you call 'remotable' on a monomorphic function @f : T1 -> T2@
-- 
-- > remotable ['f]
--
-- then a serialization dictionary is automatically created for you, which you
-- can access with
--
-- > $(functionDict 'f) :: Static (SerializableDict T1)
--
-- This is the dictionary that 'mkClosure' uses.
--
-- [Combinators on Closures]
--
-- Support for 'staticApply' (described above) also means that we can define
-- combinators on Closures, and we provide a number of them in this module,
-- the most important of which is 'cpBind'. Have a look at the implementation
-- of 'Control.Distributed.Process.call' for an example use.
--
-- [Notes]
--
-- (*) If 'T1' is not serializable you will get a type error in the generated
--     code. Unfortunately, the Template Haskell infrastructure cannot check
--     a priori if 'T1' is serializable or not due to a bug in the Template
--     Haskell libraries (<http://hackage.haskell.org/trac/ghc/ticket/7066>)
--
-- (**) Even though 'staticDecode' is passed an explicit serialization 
--      dictionary, we still need the 'Typeable' constraint because 
--      'Static' is not the /true/ static. If it was, we could 'unstatic'
--      the dictionary and pattern match on it to bring the 'Typeable'
--      instance into scope, but unless proper 'static' support is added to
--      ghc we need both the type class argument and the explicit dictionary. 
module Control.Distributed.Process.Closure 
  ( -- * User-defined closures
    remotable
  , mkStatic
  , mkClosure
  , functionSDict
    -- * Primitive operations on static values
  , staticApply
  , staticDuplicate
    -- * Static functionals
  , staticConst
  , staticFlip
  , staticFst
  , staticSnd
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
  , SerializableDict(..)
  , sdictUnit
  , sdictProcessId
  , sdictSendPort
    -- * Definition of CP and the generalized arrow combinators
  , CP
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
  ) where 

import Control.Distributed.Process.Internal.Types 
  ( SerializableDict(..)
  , staticApply
  , staticDuplicate
  )
import Control.Distributed.Process.Internal.Closure.TH 
  ( remotable
  , mkStatic
  , functionSDict
  )
import Control.Distributed.Process.Internal.Closure.Static
  ( -- Static functionals
    staticConst
  , staticFlip
  , staticFst
  , staticSnd
  , staticCompose
  , staticFirst
  , staticSecond
  , staticSplit
    -- Static constants
  , staticUnit
    -- Creating closures
  , staticDecode
  , staticClosure
  , toClosure
    -- Serialization dictionaries (and their static versions)
  , sdictUnit
  , sdictProcessId
  , sdictSendPort
  )
import Control.Distributed.Process.Internal.Closure.MkClosure (mkClosure)
import Control.Distributed.Process.Internal.Closure.CP
  ( -- Definition of CP and the generalized arrow combinators
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
    -- Closure versions of CH primitives
  , cpLink
  , cpUnlink
  , cpSend
  , cpExpect
  , cpNewChan
    -- @Closure (Process a)@ as a not-quite-monad
  , cpReturn 
  , cpBind
  , cpSeq
  )
