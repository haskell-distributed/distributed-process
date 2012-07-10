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
  , Process
  , Closure(Closure)
  , Static(Static)
  , RuntimeSerializableSupport(..)
  )
import Control.Distributed.Process.Internal.Dynamic
  ( Dynamic(Dynamic)
  , toDyn
  , dynApp
  , dynApply
  , unsafeCoerce#
  )
import Control.Distributed.Process.Internal.TypeRep () -- Binary instances  

resolveClosure :: RemoteTable -> StaticLabel -> ByteString -> Maybe Dynamic
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
-- Generic closure combinators
resolveClosure rtable ClosureApply env = do 
    f <- resolveClosure rtable labelf envf
    x <- resolveClosure rtable labelx envx
    f `dynApply` x
  where
    (labelf, envf, labelx, envx) = decode env 
resolveClosure rtable CpApply env =
    return $ Dynamic typApply (unsafeCoerce# cpApply)
  where
    cpApply :: forall a b. (Closure (a -> Process b), a) -> Process b 
    cpApply (Closure (Static flabel) fenv, x) = do
      let Just f = resolveClosure rtable flabel fenv
          Dynamic typResult val = f `dynApp` Dynamic typA (unsafeCoerce# x) 
      if typResult == typProcB 
        then unsafeCoerce# val
        else error $ "Type error in cpApply: "
                  ++ "mismatch between " ++ show typResult 
                  ++ " and " ++ show typProcB

    (typApply, typA, typProcB) = decode env

-- User defined closures
resolveClosure rtable (UserStatic label) env = do
  val <- rtable ^. remoteTableLabel label 
  dynApply val (toDyn env)
resolveClosure rtable (PolyStatic label) env = do
  Dynamic _ val <- rtable ^. remoteTableLabel label
  return (Dynamic (decode env) val)
