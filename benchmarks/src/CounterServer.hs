{-# OPTIONS_GHC -fno-warn-orphans #-}

import Blaze.ByteString.Builder (toLazyByteString)
import Blaze.ByteString.Builder.Char.Utf8 (fromString)
import Control.DeepSeq (NFData(rnf))
import Criterion.Main
import qualified Data.ByteString.Lazy as BL
import qualified Data.ByteString.Lazy.Internal as BL

main :: IO ()
main = do
  defaultMain [
      --bgroup "call" [
      --  bench "incrementCount" $ nf undefined
      --  bench "resetCount"  $ nf undefined
      --]
    ]
