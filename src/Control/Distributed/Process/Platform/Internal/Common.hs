{-# LANGUAGE ExistentialQuantification  #-}

module Control.Distributed.Process.Platform.Internal.Common where

import Control.Distributed.Process
import Control.Distributed.Process.Platform.Internal.Types

explain :: String -> DiedReason -> TerminateReason
explain m r = TerminateOther (m ++ " (" ++ (show r) ++ ")")

