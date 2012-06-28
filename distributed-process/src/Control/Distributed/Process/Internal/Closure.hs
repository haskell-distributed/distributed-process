{-# LANGUAGE MagicHash #-}
module Control.Distributed.Process.Internal.Closure 
  ( -- * Runtime support
    initRemoteTable
  , resolveClosure
  ) where

import qualified Data.Map as Map (empty)
import Data.Accessor ((^.))
import Data.ByteString.Lazy (ByteString)
import Data.Binary (decode)
import Control.Distributed.Process.Internal.Types
  ( RemoteTable(RemoteTable)
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
import {-# SOURCE #-} qualified Control.Distributed.Process.Internal.Closure.BuiltIn as BuiltIn
  (remoteTable)

--------------------------------------------------------------------------------
-- Runtime support for closures                                               --
--------------------------------------------------------------------------------

-- | Initial (empty) remote-call meta data
initRemoteTable :: RemoteTable
initRemoteTable = BuiltIn.remoteTable (RemoteTable Map.empty Map.empty)

resolveClosure :: RemoteTable -> StaticLabel -> ByteString -> Maybe Dynamic
-- Built-in closures
resolveClosure rtable ClosureSend env = do
    rss <- rtable ^. remoteTableDict label
    rssSend rss `dynApply` toDyn pid 
  where
    (label, pid) = decode env :: (String, ProcessId)
resolveClosure rtable ClosureReturn env = do
    rss <- rtable ^. remoteTableDict label
    rssReturn rss `dynApply` toDyn arg 
  where
    (label, arg) = decode env :: (String, ByteString)
-- Generic closure combinators
resolveClosure rtable ClosureApply env = do 
    f <- resolveClosure rtable labelf envf
    x <- resolveClosure rtable labelx envx
    f `dynApply` x
  where
    (labelf, envf, labelx, envx) = decode env 
resolveClosure _rtable ClosureConst env = 
  return $ Dynamic (decode env) (unsafeCoerce# const)
resolveClosure _rtable ClosureUnit _env =
  return $ toDyn ()
-- Arrow combinators
resolveClosure _rtable CpId env =
    return $ Dynamic (decode env) (unsafeCoerce# cpId)
  where
    cpId :: forall a. a -> Process a
    cpId = return
resolveClosure _rtable CpComp  env =
    return $ Dynamic (decode env) (unsafeCoerce# cpComp)
  where
    cpComp :: forall a b c. (a -> Process b) -> (b -> Process c) -> a -> Process c
    cpComp p q a = p a >>= q 
resolveClosure _rtable CpFirst env =
    return $ Dynamic (decode env) (unsafeCoerce# cpFirst)
  where
    cpFirst :: forall a b c. (a -> Process b) -> (a, c) -> Process (b, c)
    cpFirst p (a, c) = do b <- p a ; return (b, c) 
resolveClosure _rtable CpSwap env =
    return $ Dynamic (decode env) (unsafeCoerce# cpSwap) 
  where
    cpSwap :: forall a b. (a, b) -> Process (b, a)
    cpSwap (a, b) = return (b, a) 
resolveClosure _rtable CpCopy env =
    return $ Dynamic (decode env) (unsafeCoerce# cpCopy)
  where
    cpCopy :: forall a. a -> Process (a, a)
    cpCopy a = return (a, a) 
resolveClosure _rtable CpLeft env =
    return $ Dynamic (decode env) (unsafeCoerce# cpLeft)
  where
    cpLeft :: forall a b c. (a -> Process b) -> Either a c -> Process (Either b c)
    cpLeft p (Left a)  = do b <- p a ; return (Left b) 
    cpLeft _ (Right c) = return (Right c) 
resolveClosure _rtable CpMirror env =
    return $ Dynamic (decode env) (unsafeCoerce# cpMirror)
  where
    cpMirror :: forall a b. Either a b -> Process (Either b a)
    cpMirror (Left a)  = return (Right a) 
    cpMirror (Right b) = return (Left b)
resolveClosure _rtable CpUntag env =
    return $ Dynamic (decode env) (unsafeCoerce# cpUntag)
  where
    cpUntag :: forall a. Either a a -> Process a
    cpUntag (Left a)  = return a
    cpUntag (Right a) = return a
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
