{-# LANGUAGE ExistentialQuantification  #-}

module Control.Distributed.Process.Platform.Internal.Common where

import Control.Distributed.Process (Process, die)
import Control.Distributed.Process.Platform.Internal.Types
import Control.Distributed.Process.Serializable
import Data.Typeable (Typeable, typeOf) --, splitTyConApp)

failTypeCheck :: forall a b . (Serializable a) => a -> Process b
failTypeCheck m = failUnexpectedType "FAILED_TYPE_CHECK :-" m

failUnexpectedType :: forall a b . (Serializable a) => String -> a -> Process b
failUnexpectedType s m = die $ TerminateOther $ s ++ showTypeRep m

showTypeRep :: forall a. (Typeable a) => a -> String
showTypeRep m = show $ typeOf m

