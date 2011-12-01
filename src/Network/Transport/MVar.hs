{-# LANGUAGE BangPatterns #-}

module Network.Transport.MVar
  ( mkTransport
  ) where

import Control.Concurrent.MVar
import Data.IntMap (IntMap)
import Data.ByteString.Char8 (ByteString)

import qualified Data.IntMap as IntMap
import qualified Data.ByteString.Char8 as BS

import Network.Transport

type Chans = MVar (Int, IntMap (MVar [ByteString]))

mkTransport :: IO Transport
mkTransport = do
  channels <- newMVar (0, IntMap.empty)
  return Transport
    { newConnectionWith = \_ -> do
        (i, m) <- takeMVar channels
        receiveChan <- newEmptyMVar
        let sendAddr = i
            !i'      = i+1
            !m'      = IntMap.insert i receiveChan m
        putMVar channels (i', m')
        return (mkSendAddr channels sendAddr, mkReceiveEnd receiveChan)
    , newMulticastWith = undefined
    , deserialize = \bs ->
        case BS.readInt bs of
          Nothing    -> error "dummyBackend.deserializeSendEnd: cannot parse"
          Just (n,_) -> Just . mkSendAddr channels $ n
    }
  where
    mkSendAddr :: Chans -> Int -> SendAddr
    mkSendAddr channels addr = SendAddr
      { connectWith = \_ -> mkSendEnd channels $ addr
      , serialize   = BS.pack (show addr)
      }
    -- mkSendEnd channels sendAddr

    mkSendEnd :: Chans -> Int -> IO SendEnd
    mkSendEnd channels addr = do
      (_, m) <- readMVar channels
      case IntMap.lookup addr m of
        Nothing   -> fail "dummyBackend.send: bad send address"
        Just chan -> return SendEnd
          { send = realSend chan
          }

    mkReceiveEnd :: MVar [ByteString] -> ReceiveEnd
    mkReceiveEnd chan = ReceiveEnd
      { receive = takeMVar chan
      }

    realSend :: MVar [ByteString] -> [ByteString] -> IO ()
    realSend = putMVar
