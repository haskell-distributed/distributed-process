module Data.NotByteString.Lazy 
  ( ByteString
  , fromString 
  , toString 
  , fromByteString
  , toByteString
  , length
  , concat
  , null
  , empty
  , splitAt
  , toChunks
  , fromChunks
  ) where

import Prelude hiding (length, concat, null, splitAt)
import Data.NotByteString 
  ( ByteString
  , fromString
  , toString
  , length
  , concat
  , null
  , empty
  , splitAt
  )
import qualified Data.ByteString.Lazy as BSL (ByteString)
import qualified Data.ByteString.Lazy.Char8 as BSLC (pack, unpack)

fromByteString :: BSL.ByteString -> ByteString
fromByteString = fromString . BSLC.unpack

toByteString :: ByteString -> BSL.ByteString
toByteString = BSLC.pack . toString

toChunks :: ByteString -> [ByteString]
toChunks = return

fromChunks :: [ByteString] -> ByteString
fromChunks = concat
