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
-- > $(mkStatic 'f) :: forall a1 .. an. (Typeable a1, .., Typeable an) => Static T
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
-- [Dealing with type class qualifiers]
-- 
-- Although 'mkStatic' supports polymorphic types, it does not support
-- qualified types. For instance, you cannot call 'mkStatic' on
--
-- > decode :: Serializable a => ByteString -> a
--
-- Instead, you will need to reify the type class dictionary. Cloud Haskell
-- comes with a reified version of 'Serializable':
--
-- > data SerializableDict a where
-- >   SerializableDict :: Serializable a => SerializableDict a
--
-- Using the reified dictionary you can define 
-- 
-- > decodeDict :: SerializableDict a -> ByteString -> a
-- > decodeDict SerializableDict = decode
--
-- where 'decodeDict' is a normal (unqualified) polymorphic value and hence
-- can be passed as an argument to remotable:
--
-- > $(mkStatic 'decodeDict) :: Typeable a => Static (SerializableDict a -> ByteString -> a)
--
-- [Composing static values]
--
-- The version of 'static' provided by this implementation of Cloud Haskell is
-- strictly more expressive than the one proposed in the paper, and additionally
-- supports 
--
-- > staticApply :: Static (a -> b) -> Static a -> Static b
--
-- This is extremely useful. For example, Cloud Haskell comes with
-- 'staticDecode' defined as 
--
-- > staticDecode :: Typeable a => Static (SerializableDict a) -> Static (ByteString -> a)
-- > staticDecode dict = $(mkStatic 'decodeDict) `staticApply` dict 
--
-- 'staticDecode' is used when defining closures (see below), and makes
-- essential use of 'staticApply'. 
--
-- Support for 'staticApply' also makes it possible to define a rich set of
-- combinators on 'static' values, a number of which are provided in this
-- module. 
--
-- [Static serialization dictionaries]
--
-- Many Cloud Haskell primitives (like 'staticDecode', above) require static
-- serialization dictionaries. In principle these dictionaries require nothing
-- special; for instance, given some serializable type 'T' you can define 
--
-- > sdictT :: SerializableDict T
-- > sdictT = SerializableDict
--
-- and then have
-- 
-- > $(mkStatic 'sdictT) :: Static (SerializableDict T)
--
-- However, since these dictionaries are so frequently required Cloud Haskell
-- provides special support for them.  When you call 'remotable' on a
-- /monomorphic/ function @f :: T1 -> T2@
-- 
-- > remotable ['f]
--
-- then a serialization dictionary is automatically created for you, which you
-- can access with
--
-- > $(functionSDict 'f) :: Static (SerializableDict T1)
--
-- In addition, if @f :: T1 -> Process T2@, then a second dictionary is created
--
-- > $(functionTDict 'f) :: Static (SerializableDict T2)
--
-- [Closures]
--
-- Suppose you have a process
--
-- > isPrime :: Integer -> Process Bool 
--
-- Then 
--
-- > $(mkClosure 'isPrime) :: Integer -> Closure (Process Bool)
--
-- which you can then 'call', for example, to have a remote node check if 
-- a number is prime.
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
-- The splice @$(mkClosure 'isPrime)@ above expands to (prettified a bit): 
-- 
-- > let decoder :: Static (ByteString -> Process Bool) 
-- >     decoder = $(mkStatic 'isPrime) 
-- >             `staticCompose`  
-- >               staticDecode $(functionSDict 'isPrime)
-- > in Closure decoder (encode n)
--
-- where 'staticCompose' is composition of static functions. Note that
-- 'mkClosure' makes use of the static serialization dictionary 
-- ('functionSDict') created by 'remotable'.
--
-- [Combinators on Closures]
--
-- Support for 'staticApply' (described above) also means that we can define
-- combinators on Closures, and we provide a number of them in this module,
-- the most important of which is 'cpBind'. Have a look at the implementation
-- of 'Control.Distributed.Process.call' for an example use.
--
-- [Example]
--
-- Here is a small self-contained example that uses closures and serialization
-- dictionaries. It makes use of the Control.Distributed.Process.SimpleLocalnet
-- Cloud Haskell backend.
--
-- > {-# LANGUAGE TemplateHaskell #-}
-- > import System.Environment (getArgs)
-- > import Control.Distributed.Process
-- > import Control.Distributed.Process.Closure
-- > import Control.Distributed.Process.Backend.SimpleLocalnet
-- > import Control.Distributed.Process.Node (initRemoteTable)
-- > 
-- > isPrime :: Integer -> Process Bool
-- > isPrime n = return . (n `elem`) . takeWhile (<= n) . sieve $ [2..]
-- >   where
-- >     sieve :: [Integer] -> [Integer]
-- >     sieve (p : xs) = p : sieve [x | x <- xs, x `mod` p > 0]
-- > 
-- > remotable ['isPrime]
-- > 
-- > master :: [NodeId] -> Process ()
-- > master [] = liftIO $ putStrLn "no slaves"
-- > master (slave:_) = do
-- >   isPrime79 <- call $(functionTDict 'isPrime) slave ($(mkClosure 'isPrime) (79 :: Integer))
-- >   liftIO $ print isPrime79 
-- > 
-- > main :: IO ()
-- > main = do
-- >   args <- getArgs
-- >   case args of
-- >     ["master", host, port] -> do
-- >       backend <- initializeBackend host port rtable 
-- >       startMaster backend master 
-- >     ["slave", host, port] -> do
-- >       backend <- initializeBackend host port rtable 
-- >       startSlave backend
-- >   where
-- >     rtable :: RemoteTable
-- >     rtable = __remoteTable initRemoteTable 
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
  ( -- * Creating static values
    remotable
  , mkStatic
    -- * Template-Haskell support for creating closures
  , mkClosure
  , functionSDict
  , functionTDict
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
  , functionTDict
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
