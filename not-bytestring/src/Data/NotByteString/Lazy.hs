module Data.NotByteString.Lazy
  ( ByteString(Nil, Cons)
  , fromString 
  , toString 
  , fromByteString
  , toByteString
  , length
  , concat
  , null
  , empty
  , splitAt
  , foldr
  , foldl'
  , (++)
  , toChunks
  , fromChunks
  ) where

import Prelude hiding (length, null, concat, splitAt, foldr, (++), reverse)
import qualified Prelude (length, null, splitAt, foldr)
import Data.Binary (Binary(get, put))
import Data.Typeable (Typeable)
import qualified Data.ByteString.Lazy as BSL (ByteString)
import qualified Data.ByteString.Lazy.Char8 as BSLC (pack, foldr)
import qualified Data.NotByteString as Strict (ByteString(Nil, Cons), foldr)
import Control.Applicative ((<$>))

data ByteString = Nil | Cons {-# UNPACK #-} !Char ByteString 
  deriving (Typeable, Eq, Ord)

instance Show ByteString where
  show = toString 

instance Binary ByteString where
  get = fromByteString <$> get 
  put = put . toByteString 

foldl' :: (a -> Char -> a) -> a -> ByteString -> a
foldl' f = go
  where
    go !acc Nil         = acc
    go !acc (Cons c cs) = go (acc `f` c) cs

foldr :: (Char -> a -> a) -> a -> ByteString -> a
foldr f e = go
  where
    go Nil         = e
    go (Cons c cs) = c `f` go cs

toString :: ByteString -> String
toString = foldr (:) []

fromString :: String -> ByteString
fromString = Prelude.foldr Cons Nil

fromByteString :: BSL.ByteString -> ByteString
fromByteString = BSLC.foldr Cons Nil

toByteString :: ByteString -> BSL.ByteString
toByteString = BSLC.pack . toString

length :: ByteString -> Int
length = foldl' (\l _ -> l + 1) 0 

(++) :: ByteString -> ByteString -> ByteString
xs ++ ys = foldr Cons ys xs

concat :: [ByteString] -> ByteString
concat = Prelude.foldr (++) empty 

null :: ByteString -> Bool
null = foldr (\_ _ -> False) True 

empty :: ByteString
empty = Nil 

reverse :: ByteString -> ByteString
reverse = go Nil
  where
    go acc Nil         = acc
    go acc (Cons c cs) = go (Cons c acc) cs

splitAt :: Int -> ByteString -> (ByteString, ByteString)
splitAt = go Nil
  where
    go acc 0 cs          = (reverse acc, cs)
    go acc _ Nil         = (reverse acc, Nil)
    go acc n (Cons c cs) = go (Cons c acc) (n - 1) cs

toStrict :: ByteString -> Strict.ByteString
toStrict = foldr Strict.Cons Strict.Nil

fromStrict :: Strict.ByteString -> ByteString
fromStrict = Strict.foldr Cons Nil

-- | This does not preserve laziness 
toChunks :: ByteString -> [Strict.ByteString]
toChunks = return . toStrict

fromChunks :: [Strict.ByteString] -> ByteString
fromChunks = concat . map fromStrict
