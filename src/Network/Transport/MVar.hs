{-# LANGUAGE BangPatterns #-}

module Network.Transport.MVar
  ( mkTransport
  ) where

import Control.Concurrent.MVar
import Data.IntMap (IntMap)
import Data.ByteString (ByteString)
import Data.Serialize

import qualified Data.IntMap as IntMap
import qualified Data.ByteString as BS

import Network.Transport

type Chans = MVar (Int, IntMap (MVar [ByteString]))

mkTransport :: IO Transport
mkTransport = do
  channels <- newMVar (0, IntMap.empty)
  return Transport
    { newConnectionWith = \_ -> do
        (i, m) <- takeMVar channels
        receiveChan <- newEmptyMVar
        let sourceAddr = i
            !i'      = i+1
            !m'      = IntMap.insert i receiveChan m
        putMVar channels (i', m')
        return (mkSourceAddr channels sourceAddr, mkTargetEnd receiveChan)
    , newMulticastWith = undefined
    , deserialize = \bs ->
        either (error "dummyBackend.deserializeSourceEnd: cannot parse")
               (Just . mkSourceAddr channels)
               (decode bs)
    }
  where
    mkSourceAddr :: Chans -> Int -> SourceAddr
    mkSourceAddr channels addr = SourceAddr
      { connectWith = \_ -> mkSourceEnd channels addr
      , serialize   = encode addr
      }

    mkSourceEnd :: Chans -> Int -> IO SourceEnd
    mkSourceEnd channels addr = do
      (_, m) <- readMVar channels
      case IntMap.lookup addr m of
        Nothing   -> fail "dummyBackend.send: bad send address"
        Just chan -> return SourceEnd
          { send = realSend chan
          }

    mkTargetEnd :: MVar [ByteString] -> TargetEnd
    mkTargetEnd chan = TargetEnd
      { receive = takeMVar chan
      }

    realSend :: MVar [ByteString] -> [ByteString] -> IO ()
    realSend = putMVar
