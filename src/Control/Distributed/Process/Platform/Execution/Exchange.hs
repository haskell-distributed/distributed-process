{-# LANGUAGE DeriveDataTypeable    #-}
{-# LANGUAGE DeriveGeneric         #-}
{-# LANGUAGE StandaloneDeriving    #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE PatternGuards         #-}
{-# LANGUAGE RecordWildCards       #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE EmptyDataDecls        #-}
{-# LANGUAGE TemplateHaskell       #-}
{-# LANGUAGE ImpredicativeTypes    #-}
{-# LANGUAGE UndecidableInstances  #-}
{-# LANGUAGE MultiParamTypeClasses #-}

-----------------------------------------------------------------------------
-- |
-- Module      :  Control.Distributed.Process.Platform.Execution.Exchange
-- Copyright   :  (c) Tim Watson 2012 - 2014
-- License     :  BSD3 (see the file LICENSE)
--
-- Maintainer  :  Tim Watson <watson.timothy@gmail.com>
-- Stability   :  experimental
-- Portability :  non-portable (requires concurrency)
--
-----------------------------------------------------------------------------

module Control.Distributed.Process.Platform.Execution.Exchange
  ( Exchange
  , ExchangeType(..)
  , Message(..)
  , createMessage
  ) where

import Control.Distributed.Process.Platform.Execution.Exchange.Broadcast
  ( broadcastExchange
  , supervisedBroadcastExchange
  , broadcastClient
  , BroadcastExchange
  )
import Control.Distributed.Process.Platform.Execution.Exchange.Internal
  ( Exchange
  , ExchangeType(..)
  , Message(..)
  , createMessage
  )

