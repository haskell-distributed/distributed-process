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

resolveStatic :: RemoteTable -> Static a -> Maybe Dynamic
resolveStatic rtable (Static (StaticLabel string typ)) = do
  Dynamic _ val <- rtable ^. remoteTableLabel string
  return (Dynamic typ val)
resolveStatic rtable (Static (StaticApply static1 static2)) = do
  f <- resolveStatic rtable (Static static1)
  x <- resolveStatic rtable (Static static2)
  f `dynApply` x
resolveStatic _rtable (Static (StaticDuplicate static typ)) = 
  return $ Dynamic typ (unsafeCoerce# (Static static))

resolveClosure :: RemoteTable -> Static a -> ByteString -> Maybe Dynamic
resolveClosure rtable static env = do
  decoder <- resolveStatic rtable static
  decoder `dynApply` toDyn env
