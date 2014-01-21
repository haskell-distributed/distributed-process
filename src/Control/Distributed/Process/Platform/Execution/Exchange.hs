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
-- [Message Exchanges]
--
-- The concept of a /message exchange/ is borrowed from the world of
-- messaging and enterprise integration. The /exchange/ acts like a kind of
-- mailbox, accepting inputs from /producers/ and forwarding these messaages
-- to one or more /consumers/, depending on the implementation's semantics.
--
-- This module provides some basic types of message exchange and exposes an API
-- for defining your own custom /exchange types/.
--
-- [Broadcast Exchanges]
--
-- The broadcast exchange type, started via 'broadcastExchange', forward their
-- inputs to all registered consumers (as the name suggests). This exchange type
-- is highly optimised for local (intra-node) traffic and provides two different
-- kinds of client binding, one which causes messages to be delivered directly
-- to the client's mailbox (viz 'bindToBroadcaster'), the other providing a
-- separate stream of messages that can be obtained using the @expect@ and
-- @receiveX@ family of messaging primitives (and thus composed with other forms
-- of input selection, such as typed channels and selective reads on the process
-- mailbox).
--
-- /Important:/ When a @ProcessId@ is registered via 'bindToBroadcaster', only
-- the payload of the 'Message' (i.e., the underlying @Serializable@ datum) is
-- forwarded to the consumer, /not/ the whole 'Message' itself.
--
-- [Router Exchanges]
--
-- The /router/ API provides a means to selectively route messages to one or
-- more clients, depending on the content of the 'Message'. Two modes of binding
-- (and client selection) are provided out of the box, one of which matches the
-- message 'key', the second of which matches on a name and value from the
-- 'headers'. Alternative mechanisms for content based routing can be derived
-- by modifying the 'BindingSelector' expression passed to 'router'
--
-- See 'messageKeyRouter' and 'headerContentRouter' for the built-in routing
-- exchanges, and 'router' for the extensible routing API.
--
-- [Custom Exchange Types]
--
-- Both the /broadcast/ and /router/ exchanges are implemented as custom
-- /exchange types/. The mechanism for defining custom exchange behaviours
-- such as these is very simple. Raw exchanges are started by evaluating
-- 'startExchange' with a specific 'ExchangeType' record. This type is
-- parameterised by the internal /state/ it holds, and defines two API callbacks
-- in its 'configureEx' and 'routeEx' fields. The former is evaluated whenever a
-- client process evaluates 'configureExchange', the latter whenever a client
-- evaluates 'post' or 'postMessage'. The 'configureEx' callback takes a raw
-- @Message@ (from "Control.Distributed.Process") and is responsible for
-- decoding the message and updating its own state (if required). It is via
-- this callback that custom exchange types can receive information about
-- clients and handle it in thier own way. The 'routeEx' callback is evaluated
-- with the exchange type's own internal state and the 'Message' originally
-- sent to the exchange process (via 'post') and is responsible for delivering
-- the message to its clients in whatever way makes sense for that exchange
-- type.
--
-----------------------------------------------------------------------------

module Control.Distributed.Process.Platform.Execution.Exchange
  ( -- * Fundamental API
    Exchange()
  , Message(..)
    -- * Starting/Running an Exchange
  , startExchange
  , startSupervisedExchange
  , runExchange
    -- * Client Facing API
  , post
  , postMessage
  , configureExchange
  , createMessage
    -- * Broadcast Exchange
  , broadcastExchange
  , supervisedBroadcastExchange
  , broadcastClient
  , bindToBroadcaster
  , BroadcastExchange
    -- * Routing (Content Based)
  , HeaderName
  , Binding(..)
  , Bindable
  , BindingSelector
  , RelayType(..)
    -- * Starting a Router
  , router
  , supervisedRouter
    -- * Routing (Publishing) API
  , route
  , routeMessage
    -- * Routing via message/binding keys
  , messageKeyRouter
  , bindKey
    -- * Routing via message headers
  , headerContentRouter
  , bindHeader
    -- * Defining Custom Exchange Types
  , ExchangeType(..)
  , applyHandlers
  ) where

import Control.Distributed.Process.Platform.Execution.Exchange.Broadcast
  ( broadcastExchange
  , supervisedBroadcastExchange
  , broadcastClient
  , bindToBroadcaster
  , BroadcastExchange
  )
import Control.Distributed.Process.Platform.Execution.Exchange.Internal
  ( Exchange()
  , Message(..)
  , ExchangeType(..)
  , startExchange
  , startSupervisedExchange
  , runExchange
  , post
  , postMessage
  , configureExchange
  , createMessage
  , applyHandlers
  )
import Control.Distributed.Process.Platform.Execution.Exchange.Router
  ( HeaderName
  , Binding(..)
  , Bindable
  , BindingSelector
  , RelayType(..)
  , router
  , supervisedRouter
  , route
  , routeMessage
  , messageKeyRouter
  , bindKey
  , headerContentRouter
  , bindHeader
  )

