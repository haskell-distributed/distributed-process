module Data.NotByteString.Lazy.Binary
  ( encode
  , decode
  ) where

import Data.NotByteString.Lazy (ByteString, fromByteString, toByteString)
import Data.Binary (Binary)
import qualified Data.Binary as Binary (encode, decode)

encode :: Binary a => a -> ByteString 
encode = fromByteString . Binary.encode 

decode :: Binary a => ByteString -> a
decode = Binary.decode . toByteString 
