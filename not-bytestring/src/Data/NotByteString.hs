module Data.NotByteString 
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
  ) where

import Prelude hiding (length, null, concat, splitAt)
import qualified Prelude (length, null, splitAt)
import Data.Binary (Binary)
import Data.Typeable (Typeable)
import qualified Data.ByteString as BS (ByteString)
import qualified Data.ByteString.Char8 as BSC (pack, unpack)
import Control.Arrow ((***))

newtype ByteString = NotByteString { toString :: String }
  deriving (Eq, Ord, Binary, Typeable)

instance Show ByteString where
  show = toString 

fromString :: String -> ByteString
fromString = NotByteString

fromByteString :: BS.ByteString -> ByteString
fromByteString = fromString . BSC.unpack

toByteString :: ByteString -> BS.ByteString
toByteString = BSC.pack . toString

length :: ByteString -> Int
length = Prelude.length . toString 

concat :: [ByteString] -> ByteString
concat = fromString . concatMap toString 

null :: ByteString -> Bool
null = Prelude.null . toString 

empty :: ByteString
empty = fromString ""

splitAt :: Int -> ByteString -> (ByteString, ByteString)
splitAt i = (fromString *** fromString) . Prelude.splitAt i . toString
