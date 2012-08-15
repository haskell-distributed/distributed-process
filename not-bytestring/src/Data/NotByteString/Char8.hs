module Data.NotByteString.Char8
  ( pack
  , unpack
  , split
  ) where

import Data.NotByteString 
  ( ByteString
  , fromString
  , toString
  , fromByteString
  , toByteString
  )
import qualified Data.ByteString.Char8 as BSC (split)

pack :: String -> ByteString
pack = fromString 

unpack :: ByteString -> String
unpack = toString 

-- TODO: Avoid roundtrip
split :: Char -> ByteString -> [ByteString]
split c = map fromByteString . BSC.split c . toByteString 
