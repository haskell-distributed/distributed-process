{-# LANGUAGE MagicHash #-}
module Control.Distributed.Process.Internal.Closure.Resolution (resolveClosure) where

import Data.Accessor ((^.))
import Data.ByteString.Lazy (ByteString)
import Control.Distributed.Process.Internal.Types
  ( RemoteTable
  , remoteTableLabel
  , Static(Static)
  , StaticLabel(..)
  )
import Control.Distributed.Process.Internal.Dynamic
  ( Dynamic(Dynamic)
  , toDyn
  , dynApply
  , unsafeCoerce#
  )
import Control.Distributed.Process.Internal.TypeRep () -- Binary instances  

resolveStatic :: RemoteTable -> StaticLabel -> Maybe Dynamic
resolveStatic rtable (StaticLabel string typ) = do
  Dynamic _ val <- rtable ^. remoteTableLabel string
  return (Dynamic typ val)
resolveStatic rtable (StaticApply static1 static2) = do
  f <- resolveStatic rtable static1
  x <- resolveStatic rtable static2
  f `dynApply` x
resolveStatic _rtable (StaticDuplicate static typ) = 
  return $ Dynamic typ (unsafeCoerce# (Static static))

resolveClosure :: RemoteTable -> StaticLabel -> ByteString -> Maybe Dynamic
resolveClosure rtable static env = do
  decoder <- resolveStatic rtable static
  decoder `dynApply` toDyn env
