{-# LANGUAGE StaticPointers #-}
{-# LANGUAGE CPP                 #-}
{-# LANGUAGE ScopedTypeVariables #-}

module MailboxTestFilters where

import Control.Distributed.Process
import Control.Distributed.Process.Execution.Mailbox (FilterResult(..))
import Control.Monad (forM)

import Prelude hiding (drop)
import Data.Maybe (catMaybes)
import Data.Binary (decode, encode)

filterInputs :: (String, Int, Bool) -> Message -> Process FilterResult
filterInputs (s, i, b) msg = do
  rs <- forM [ \m -> handleMessageIf m (\s' -> s' == s) (\_ -> return Keep)
             , \m -> handleMessageIf m (\i' -> i' == i) (\_ -> return Keep)
             , \m -> handleMessageIf m (\b' -> b' == b) (\_ -> return Keep)
             ] $ \h -> h msg
  if (length (catMaybes rs) > 0)
    then return Keep
    else return Skip

filterEvens :: Message -> Process FilterResult
filterEvens m = do
  matched <- handleMessage m (\(i :: Int) -> do
                               if even i then return Keep else return Skip)
  case matched of
    Just fr -> return fr
    _       -> return Skip

intFilter :: Closure (Message -> Process FilterResult)
intFilter = (static filterEvens)

myFilter :: (String, Int, Bool) -> Closure (Message -> Process FilterResult)
myFilter x = closure (static (filterInputs . decode)) (encode x)

