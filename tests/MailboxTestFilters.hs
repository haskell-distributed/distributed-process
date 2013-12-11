{-# LANGUAGE TemplateHaskell     #-}
{-# LANGUAGE ScopedTypeVariables #-}

module MailboxTestFilters where

import Control.Distributed.Process
import Control.Distributed.Process.Platform.Execution.Mailbox (FilterResult(..))
import Control.Monad (forM)

#if ! MIN_VERSION_base(4,6,0)
import Prelude hiding (catch, drop)
#else
import Prelude hiding (drop)
#endif
import Data.Maybe (catMaybes)
import Control.Distributed.Process.Closure (remotable, mkClosure, mkStaticClosure)

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

$(remotable ['filterInputs, 'filterEvens])

intFilter :: Closure (Message -> Process FilterResult)
intFilter = $(mkStaticClosure 'filterEvens)

myFilter :: (String, Int, Bool) -> Closure (Message -> Process FilterResult)
myFilter = $(mkClosure 'filterInputs)

