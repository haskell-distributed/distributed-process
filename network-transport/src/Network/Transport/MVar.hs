{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE CPP #-}

module Network.Transport.MVar
  ( mkTransport
  ) where

import Control.Concurrent.MVar
import Data.IntMap (IntMap)
import qualified Data.Serialize as Ser

import qualified Data.IntMap as IntMap

import Network.Transport

#ifndef LAZY
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as BS
encode = Ser.encode
decode = Ser.decode
#else
import Data.ByteString.Lazy.Char8 (ByteString)
import qualified Data.ByteString.Lazy.Char8 as BS
encode = Ser.encodeLazy
decode = Ser.decodeLazy
#endif
{-# INLINE encode #-}
{-# INLINE decode #-}
encode :: Ser.Serialize a => a -> ByteString
decode :: Ser.Serialize a => ByteString -> Either String a

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
