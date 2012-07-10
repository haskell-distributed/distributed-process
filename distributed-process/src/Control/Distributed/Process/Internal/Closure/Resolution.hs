{-# LANGUAGE MagicHash #-}
module Control.Distributed.Process.Internal.Closure.Resolution (resolveClosure) where

import Data.Accessor ((^.))
import Data.ByteString.Lazy (ByteString)
import Data.Binary (decode)
import Data.Typeable (TypeRep)
import Control.Applicative ((<$>))
import Control.Distributed.Process.Internal.Types
  ( RemoteTable
  , remoteTableLabel
  , remoteTableDict
  , StaticLabel(..)
  , ProcessId
  , RuntimeSerializableSupport(..)
  )
import Control.Distributed.Process.Internal.Dynamic
  ( Dynamic(Dynamic)
  , toDyn
  , dynApply
  )
import Control.Distributed.Process.Internal.TypeRep () -- Binary instances  

resolveClosure :: RemoteTable -> StaticLabel -> ByteString -> Maybe Dynamic
-- Generic closure combinators
resolveClosure rtable ClosureApply env = do 
    f <- resolveClosure rtable labelf envf
    x <- resolveClosure rtable labelx envx
    f `dynApply` x
  where
    (labelf, envf, labelx, envx) = decode env 
-- Built-in closures
resolveClosure rtable ClosureSend env = do
    rss <- rtable ^. remoteTableDict typ 
    rssSend rss `dynApply` toDyn pid 
  where
    (typ, pid) = decode env :: (TypeRep, ProcessId)
resolveClosure rtable ClosureReturn env = do
    rss <- rtable ^. remoteTableDict typ 
    rssReturn rss `dynApply` toDyn arg 
  where
    (typ, arg) = decode env :: (TypeRep, ByteString)
resolveClosure rtable ClosureExpect env = 
    rssExpect <$> rtable ^. remoteTableDict typ
  where
    typ = decode env :: TypeRep
-- User defined closures
resolveClosure rtable (UserStatic label) env = do
  val <- rtable ^. remoteTableLabel label 
  dynApply val (toDyn env)
resolveClosure rtable (PolyStatic label) env = do
  Dynamic _ val <- rtable ^. remoteTableLabel label
  return (Dynamic (decode env) val)
