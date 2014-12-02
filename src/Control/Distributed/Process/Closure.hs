{-# LANGUAGE CPP #-}
-- | /Towards Haskell in the Cloud/ (Epstein et al., Haskell Symposium 2011)
-- proposes a new type construct called 'static' that characterizes values that
-- are known statically. Cloud Haskell uses the
-- 'Control.Distributed.Static.Static' implementation from
-- "Control.Distributed.Static". That module comes with its own extensive
-- documentation, which you should read if you want to know the details.  Here
-- we explain the Template Haskell support only.
--
-- [Static values]
--
-- Given a top-level (possibly polymorphic, but unqualified) definition
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
-- NOTE: If you get a type error from ghc along these lines
--
-- >  The exact Name `a_a30k' is not in scope
-- >       Probable cause: you used a unique name (NameU) in Template Haskell but did not bind it
--
-- then you need to enable the @ScopedTypeVariables@ language extension.
--
-- [Static serialization dictionaries]
--
-- Some Cloud Haskell primitives require static serialization dictionaries (**):
--
-- > call :: Serializable a => Static (SerializableDict a) -> NodeId -> Closure (Process a) -> Process a
--
-- Given some serializable type 'T' you can define
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
-- provided that 'T1' is serializable (*) (remember to pass 'f' to 'remotable').
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
-- (**) Even though 'call' is passed an explicit serialization
--      dictionary, we still need the 'Serializable' constraint because
--      'Static' is not the /true/ static. If it was, we could 'unstatic'
--      the dictionary and pattern match on it to bring the 'Typeable'
--      instance into scope, but unless proper 'static' support is added to
--      ghc we need both the type class argument and the explicit dictionary.
module Control.Distributed.Process.Closure
  ( -- * Serialization dictionaries (and their static versions)
    SerializableDict(..)
  , staticDecode
  , sdictUnit
  , sdictProcessId
  , sdictSendPort
  , sdictStatic
  , sdictClosure
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
    -- * Working with static values and closures (without Template Haskell)
  , RemoteRegister
  , MkTDict(..)
  , mkStaticVal
  , mkClosureValSingle
  , mkClosureVal
  , call'
#ifdef TemplateHaskellSupport
    -- * Template Haskell support for creating static values and closures
  , remotable
  , remotableDecl
  , mkStatic
  , mkClosure
  , mkStaticClosure
  , functionSDict
  , functionTDict
#endif
  ) where

import Control.Distributed.Process.Serializable (SerializableDict(..))
import Control.Distributed.Process.Internal.Closure.BuiltIn
  ( -- Static dictionaries and associated operations
    staticDecode
  , sdictUnit
  , sdictProcessId
  , sdictSendPort
  , sdictStatic
  , sdictClosure
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
import Control.Distributed.Process.Internal.Closure.Explicit
  (
    RemoteRegister
  , MkTDict(..)
  , mkStaticVal
  , mkClosureValSingle
  , mkClosureVal
  , call'
  )
#ifdef TemplateHaskellSupport
import Control.Distributed.Process.Internal.Closure.TH
  ( remotable
  , remotableDecl
  , mkStatic
  , functionSDict
  , functionTDict
  , mkClosure
  , mkStaticClosure
  )
#endif
