{-# LANGUAGE ExistentialQuantification  #-}

module Control.Distributed.Process.Platform.Internal.Common where

import Control.Distributed.Process (Process, die)
import Control.Distributed.Process.Platform.Internal.Types
import Data.Typeable (Typeable, typeOf)

failTypeCheck :: Process b
failTypeCheck = failUnexpectedType "FAILED_TYPE_CHECK :-"

failUnexpectedType :: String -> Process b
failUnexpectedType s = die $ TerminateOther s

showTypeRep :: forall a. (Typeable a) => a -> String
showTypeRep m = show $ typeOf m

