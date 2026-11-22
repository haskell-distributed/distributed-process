{-# LANGUAGE CPP #-}
-- | /Towards Haskell in the Cloud/ (Epstein et al., Haskell Symposium 2011)
-- proposes a new type construct called 'static' that characterizes values that
-- are known statically. Cloud Haskell uses the 'GHC.StaticPtr.StaticPtr'
-- implementation provided by GHC, and the 'Control.Distributed.Static.Closure'
-- type from "Control.Distributed.Static". That module comes with its own
-- documentation, which you should read if you want to know the details. Here
-- we explain the Template Haskell support, which is a convenience: nothing in
-- Cloud Haskell requires it. Every module which uses the Template Haskell
-- functions below, or which uses @static@ directly, must enable the
-- @StaticPointers@ language extension.
--
-- [Static values]
--
-- Given a top-level (possibly polymorphic, but unqualified) definition
--
-- > f :: forall a1 .. an. T
-- > f = ...
--
-- you can create a static version of 'f' with a @static@ form:
--
-- > static f :: forall a1 .. an. (Typeable a1, .., Typeable an) => StaticPtr T
--
-- A @static@ form can also be given the type of a closure, with an empty
-- environment:
--
-- > static f :: forall a1 .. an. (Typeable a1, .., Typeable an) => Closure T
--
-- [Static serialization dictionaries]
--
-- Some Cloud Haskell primitives require static serialization dictionaries (**),
-- as a 'Closure':
--
-- > call :: Serializable a => Closure (SerializableDict a) -> NodeId -> Closure (Process a) -> Process a
--
-- Given some serializable type 'T' you can define
--
-- > sdictT :: Closure (SerializableDict T)
-- > sdictT = static SerializableDict
--
-- However, since these dictionaries are so frequently required Cloud Haskell
-- provides special support for them.  If @f :: T1 -> T2@ is a /monomorphic/
-- function, then
--
-- > $(functionSDict 'f) :: Closure (SerializableDict T1)
--
-- In addition, if @f :: T1 -> Process T2@, then
--
-- > $(functionTDict 'f) :: Closure (SerializableDict T2)
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
-- (You can also create closures manually--see the documentation of
-- "Control.Distributed.Static" for examples.)
--
-- [Example]
--
-- Here is a small self-contained example that uses closures and serialization
-- dictionaries. It makes use of the Control.Distributed.Process.SimpleLocalnet
-- Cloud Haskell backend.
--
-- > {-# LANGUAGE TemplateHaskell, StaticPointers #-}
-- > import System.Environment (getArgs)
-- > import Control.Distributed.Process
-- > import Control.Distributed.Process.Closure
-- > import Control.Distributed.Process.Backend.SimpleLocalnet
-- >
-- > isPrime :: Integer -> Process Bool
-- > isPrime n = return . (n `elem`) . takeWhile (<= n) . sieve $ [2..]
-- >   where
-- >     sieve :: [Integer] -> [Integer]
-- >     sieve (p : xs) = p : sieve [x | x <- xs, x `mod` p > 0]
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
-- >       backend <- initializeBackend host port
-- >       startMaster backend master
-- >     ["slave", host, port] -> do
-- >       backend <- initializeBackend host port
-- >       startSlave backend
--
-- [Notes]
--
-- (*) If 'T1' is not serializable you will get a type error in the generated
--     code.
--
-- (**) Even though 'call' is passed an explicit serialization
--      dictionary, we still need the 'Serializable' constraint because
--      a 'StaticPtr' cannot be inspected to bring the 'Typeable' instance into
--      scope.
module Control.Distributed.Process.Closure
  ( -- * Serialization dictionaries (and their static versions)
    SerializableDict(..)
  , sdictUnit
  , sdictProcessId
  , sdictSendPort
    -- * The CP type and associated combinators
  , CP
  , idCP
  , splitCP
  , returnCP
  , bindCP
  , seqCP
    -- * CP versions of Cloud Haskell primitives
  , cpLink
  , cpUnlink
  , cpRelay
  , cpSend
  , cpExpect
  , cpNewChan
#ifdef TemplateHaskellSupport
    -- * Template Haskell support for creating closures and dictionaries
  , mkClosure
  , functionSDict
  , functionTDict
#endif
  ) where

import Control.Distributed.Process.Serializable (SerializableDict(..))
import Control.Distributed.Process.Internal.Closure.BuiltIn
  ( -- Static dictionaries and associated operations
    sdictUnit
  , sdictProcessId
  , sdictSendPort
    -- The CP type and associated combinators
  , CP
  , idCP
  , splitCP
  , returnCP
  , bindCP
  , seqCP
    -- CP versions of Cloud Haskell primitives
  , cpLink
  , cpUnlink
  , cpRelay
  , cpSend
  , cpExpect
  , cpNewChan
  )
#ifdef TemplateHaskellSupport
import Control.Distributed.Process.Internal.Closure.TH
  ( functionSDict
  , functionTDict
  , mkClosure
  )
#endif
