{-# LANGUAGE CPP #-}
{-# LANGUAGE DeriveDataTypeable   #-}
{-# LANGUAGE DeriveGeneric        #-}
{-# LANGUAGE ScopedTypeVariables  #-}
{-# LANGUAGE RecordWildCards      #-}
{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE FlexibleInstances    #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE ConstrainedClassMethods #-}

-----------------------------------------------------------------------------
-- |
-- Module      :  Control.Distributed.Process.Extras.SystemLog
-- Copyright   :  (c) Tim Watson 2013 - 2017
-- License     :  BSD3 (see the file LICENSE)
--
-- Maintainer  :  Tim Watson <watson.timothy@gmail.com>
-- Stability   :  experimental
-- Portability :  non-portable (requires concurrency)
--
-- This module provides a general purpose logging facility, implemented as a
-- distributed-process /Management Agent/. To start the logging agent on a
-- running node, evaluate 'systemLog' with the relevant expressions to handle
-- logging textual messages, a cleanup operation (if required), initial log
-- level and a formatting expression.
--
-- We export a working example in the form of 'systemLogFile', which logs
-- to a text file using buffered I/O. Its implementation is very simple, and
-- should serve as a demonstration of how to use the API:
--
-- > systemLogFile :: FilePath -> LogLevel -> LogFormat -> Process ProcessId
-- > systemLogFile path lvl fmt = do
-- >   h <- liftIO $ openFile path AppendMode
-- >   liftIO $ hSetBuffering h LineBuffering
-- >   systemLog (liftIO . hPutStrLn h) (liftIO (hClose h)) lvl fmt
--
-----------------------------------------------------------------------------

-- TODO - REWRITE THIS WITHOUT USING THE MX API, SINCE THAT's POINTLESS>>>>>>>.

module Control.Distributed.Process.Extras.SystemLog
  ( -- * Types exposed by this module
    LogLevel(..)
  , LogFormat
  , LogClient
  , LogChan
  , LogText
  , ToLog(..)
  , Logger(..)
    -- * Mx Agent Configuration / Startup
  , mxLogId
  , systemLog
  , client
  , logChannel
  , addFormatter
    -- * systemLogFile
  , systemLogFile
    -- * Logging Messages
  , report
  , debug
  , info
  , notice
  , warning
  , error
  , critical
  , alert
  , emergency
  , sendLog
  ) where

import Control.DeepSeq (NFData(..))
import Control.Distributed.Process hiding (catch)
import Control.Distributed.Process.Management
  ( MxEvent(MxConnected, MxDisconnected, MxLog, MxUser)
  , MxAgentId(..)
  , mxAgentWithFinalize
  , mxSink
  , mxReady
  , mxReceive
  , liftMX
  , mxGetLocal
  , mxSetLocal
  , mxUpdateLocal
  , mxNotify
  )
import Control.Distributed.Process.Extras
  ( Resolvable(..)
  , Routable(..)
  , Addressable
  )
import Control.Distributed.Process.Serializable
import Control.Exception (SomeException)
import Control.Monad.Catch (catch)
import Data.Binary
import Data.Typeable (Typeable)
import GHC.Generics

import Prelude hiding (error, Read)

import System.IO
  ( IOMode(AppendMode)
  , BufferMode(..)
  , openFile
  , hClose
  , hPutStrLn
  , hSetBuffering
  )
import Text.Read (Read)

data LogLevel =
    Debug
  | Info
  | Notice
  | Warning
  | Error
  | Critical
  | Alert
  | Emergency
  deriving (Typeable, Generic, Eq,
            Read, Show, Ord, Enum)
instance Binary LogLevel where
instance NFData LogLevel where rnf x = x `seq` ()

data SetLevel = SetLevel !LogLevel
  deriving (Typeable, Generic)
instance Binary SetLevel where
instance NFData SetLevel where rnf x = x `seq` ()

newtype AddFormatter = AddFormatter (Closure (Message -> Process (Maybe String)))
  deriving (Typeable, Generic, NFData)
instance Binary AddFormatter

data LogState =
  LogState { output     :: !(String -> Process ())
           , cleanup    :: !(Process ())
           , level      :: !LogLevel
           , format     :: !(String -> Process String)
           , formatters :: ![Message -> Process (Maybe String)]
           }

data LogMessage =
    LogMessage !String  !LogLevel
  | LogData    !Message !LogLevel
  deriving (Typeable, Generic, Show)
instance Binary LogMessage where
instance NFData LogMessage where rnf x = x `seq` ()

type LogFormat = String -> Process String

type LogChanT = ()

newtype LogChan = LogChan LogChanT
instance Routable LogChan where
  sendTo       _ = mxNotify
  unsafeSendTo _ = mxNotify

type LogText = String

newtype LogClient = LogClient { agent :: ProcessId }
instance Resolvable LogClient where
  resolve = return . Just . agent
instance Routable LogClient

class ToLog m where
  toLog :: (Serializable m) => m -> Process (LogLevel -> LogMessage)
  toLog = return . LogData . unsafeWrapMessage

instance ToLog LogText where
  toLog = return . LogMessage

instance ToLog Message where
  toLog = return . LogData

class Logger a where
  logMessage :: a -> LogMessage -> Process ()

instance Logger LogClient where
  logMessage = sendTo

instance Logger LogChan where
  logMessage _ = mxNotify

logProcessName :: String
logProcessName = "service.systemlog"

mxLogId :: MxAgentId
mxLogId = MxAgentId logProcessName

logChannel :: LogChan
logChannel = LogChan ()

report :: (Logger l)
       => (l -> LogText -> Process ())
       -> l
       -> String
       -> Process ()
report f l = f l

client :: Process (Maybe LogClient)
client = resolve logProcessName >>= return . maybe Nothing (Just . LogClient)

debug :: (Logger l, Serializable m, ToLog m) => l -> m -> Process ()
debug l m = sendLog l m Debug

info :: (Logger l, Serializable m, ToLog m) => l -> m -> Process ()
info l m = sendLog l m Info

notice :: (Logger l, Serializable m, ToLog m) => l -> m -> Process ()
notice l m = sendLog l m Notice

warning :: (Logger l, Serializable m, ToLog m) => l -> m -> Process ()
warning l m = sendLog l m Warning

error :: (Logger l, Serializable m, ToLog m) => l -> m -> Process ()
error l m = sendLog l m Error

critical :: (Logger l, Serializable m, ToLog m) => l -> m -> Process ()
critical l m = sendLog l m Critical

alert :: (Logger l, Serializable m, ToLog m) => l -> m -> Process ()
alert l m = sendLog l m Alert

emergency :: (Logger l, Serializable m, ToLog m) => l -> m -> Process ()
emergency l m = sendLog l m Emergency

sendLog :: (Logger l, Serializable m, ToLog m) => l -> m -> LogLevel -> Process ()
sendLog a m lv = toLog m >>= \m' -> logMessage a $ m' lv

addFormatter :: (Addressable r)
             => r
             -> Closure (Message -> Process (Maybe String))
             -> Process ()
addFormatter r clj = sendTo r $ AddFormatter clj

-- | Start a system logger that writes to a file.
--
-- This is a /very basic/ file logging facility, that uses /regular/ buffered
-- file I/O (i.e., @System.IO.hPutStrLn@ et al) under the covers. The handle
-- is closed appropriately if/when the logging process terminates.
--
-- See @Control.Distributed.Process.Management.mxAgentWithFinalize@ for futher
-- details about management agents that use finalizers.
--
systemLogFile :: FilePath -> LogLevel -> LogFormat -> Process ProcessId
systemLogFile path lvl fmt = do
  h <- liftIO $ openFile path AppendMode
  liftIO $ hSetBuffering h LineBuffering
  systemLog (liftIO . hPutStrLn h) (liftIO (hClose h)) lvl fmt

-- | Start a /system logger/ process as a management agent.
--
systemLog :: (String -> Process ()) -- ^ This expression does the actual logging
          -> (Process ())  -- ^ An expression used to clean up any residual state
          -> LogLevel      -- ^ The initial 'LogLevel' to use
          -> LogFormat     -- ^ An expression used to format logging messages/text
          -> Process ProcessId
systemLog o c l f = go $ LogState o c l f defaultFormatters
  where
    go :: LogState -> Process ProcessId
    go st =
      mxAgentWithFinalize mxLogId st [
            -- these are the messages we're /really/ interested in
            (mxSink $ \(m :: LogMessage) ->
                case m of
                  (LogMessage msg lvl) ->
                    mxGetLocal >>= outputMin lvl msg >> mxReceive
                  (LogData dat lvl) -> handleRawMsg dat lvl)

            -- complex messages rely on properly registered formatters
          , (mxSink $ \(ev :: MxEvent) ->
                case ev of
                  (MxUser msg) -> handleRawMsg msg Debug
                  -- we treat trace/log events like regular log events at
                  -- a Debug level (only)
                  (MxLog  str) -> mxGetLocal >>= outputMin Debug str >> mxReceive
                  _            -> handleEvent ev >> mxReceive)

            -- command message handling
          , (mxSink $ \(SetLevel lvl) ->
                mxGetLocal >>= \st' -> mxSetLocal st' { level = lvl } >> mxReceive)
          , (mxSink $ \(AddFormatter f') -> do
                fmt <- liftMX $ catch (unClosure f' >>= return . Just)
                                      (\(_ :: SomeException) -> return Nothing)
                case fmt of
                  Nothing -> mxReady
                  Just mf -> do
                    mxUpdateLocal (\s -> s { formatters = mf:formatters s })
                    mxReceive)
        ] runCleanup

    runCleanup = liftMX . cleanup =<< mxGetLocal

    handleRawMsg dat' lvl' = do
      st <- mxGetLocal
      msg <- formatMsg dat' st
      case msg of
        Just str -> outputMin lvl' str st >> mxReceive
        Nothing  -> mxReceive  -- we cannot format a Message, so we ignore it

    handleEvent (MxConnected    _ ep) =
          mxGetLocal >>= outputMin Notice
                                   ("Endpoint: " ++ show ep ++ " Disconnected")
    handleEvent (MxDisconnected _ ep) =
          mxGetLocal >>= outputMin Notice
                                   ("Endpoint " ++ show ep ++ " Connected")
    handleEvent _                     = return ()

    formatMsg m LogState{..} = let fms = formatters in formatMsg' m fms

    formatMsg' _ []     = return Nothing
    formatMsg' m (f':fs) = do
      res <- liftMX $ f' m
      case res of
        ok@(Just _) -> return ok
        Nothing     -> formatMsg' m fs

    outputMin minLvl msgData LogState{..} =
      case minLvl >= level of
        True  -> liftMX (format msgData >>= output)
        False -> return ()

    defaultFormatters = [basicDataFormat]

basicDataFormat :: Message -> Process (Maybe String)
basicDataFormat = unwrapMessage
