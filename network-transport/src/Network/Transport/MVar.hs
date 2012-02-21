{-# LANGUAGE BangPatterns #-}

module Network.Transport.MVar
  ( mkTransport
  ) where

import Control.Concurrent.MVar
import Data.IntMap (IntMap)
import Data.ByteString.Lazy.Char8 (ByteString)

import qualified Data.IntMap as IntMap
import qualified Data.ByteString.Lazy.Char8 as BS

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
        case BS.readInt bs of
          Nothing    -> error "dummyBackend.deserializeSourceEnd: cannot parse"
          Just (n,_) -> Just . mkSourceAddr channels $ n
    , closeTransport = return ()
    }
  where
    mkSourceAddr :: Chans -> Int -> SourceAddr
    mkSourceAddr channels addr = SourceAddr
      { connectWith = \_ -> mkSourceEnd channels addr
      , serialize   = BS.pack (show addr)
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
