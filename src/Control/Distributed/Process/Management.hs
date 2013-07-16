{-# LANGUAGE DeriveDataTypeable         #-}
{-# LANGUAGE DeriveGeneric              #-}
{-# LANGUAGE StandaloneDeriving         #-}
{-# LANGUAGE ExistentialQuantification  #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE PatternGuards              #-}
{-# LANGUAGE RecordWildCards            #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE UndecidableInstances       #-}

-----------------------------------------------------------------------------
-- |
-- Module      :  Control.Distributed.Process.Management
-- Copyright   :  (c) Well-Typed / Tim Watson
-- License     :  BSD3 (see the file LICENSE)
--
-- Maintainer  :  Tim Watson <watson.timothy@gmail.com>
-- Stability   :  experimental
-- Portability :  non-portable (requires concurrency)
--
-- /Management Extensions/ for Cloud Haskell.
--
-- This module provides a standard API for monitoring and/or responding to
-- system events in a Cloud Haskell node.
--
-- [Architecture Overview]
--
-- /Management Extensions/ can be used by infrastructure or application code
-- to provide access to runtime instrumentation data, expose control planes
-- and/or provide remote access to external clients.
--
-- The management infrastructure is broken down into three components, which
-- roughly correspond to the modules it exposes:
--
-- 1. @Agent@ - registration and management of /Management Agents/
-- 2. @Instrumentation@ - provides an API for publishing /instrumentation data/
-- 3. @Remote@ - provides an API for remote management and administration
--
--
--
-----------------------------------------------------------------------------
module Control.Distributed.Process.Management where

import Control.Applicative ((<$>))
import Control.Distributed.Process.Internal.Types
  ( Process
  , ProcessId
  , Message
  , LocalProcess(..)
  , LocalNode(..)
  , MxEventBus(..)
  , unsafeCreateUnencodedMessage
  )
import Control.Distributed.Process.Management.Bus (publishEvent)
import Control.Distributed.Process.Serializable (Serializable)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Reader (ask)

-- | Publishes an arbitrary @Serializable@ message to the management event bus.
-- Note that /no attempt is made to force the argument/, therefore it is very
-- important that you do not pass unevaluated thunks that might crash the
-- receiving process via this API, since /all/ registered agents will gain
-- access to the data structure once it is broadcast by the agent controller.
mxNotify :: (Serializable a) => a -> Process ()
mxNotify msg = do
  bus <- localEventBus . processNode <$> ask
  liftIO $ publishEvent bus $ unsafeCreateUnencodedMessage msg

mxAgent :: (Message -> Process ()) -> Process ProcessId
mxAgent handler = do
  node <- processNode <$> ask
  pid <- liftIO $ mxNew (localEventBus node) handler
  -- registerAgent pid
  return pid

