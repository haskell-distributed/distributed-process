module Network.Transport.TCP.Mock.Socket.ByteString
  ( sendMany
  , recv
  ) where

import Data.ByteString (ByteString)
import qualified Data.ByteString as BSS (pack, foldl)
import Data.Word (Word8)
import Control.Applicative ((<$>))
import Network.Transport.TCP.Mock.Socket

sendMany :: Socket -> [ByteString] -> IO ()
sendMany sock = mapM_ (bsMapM_ (writeSocket sock . Payload))
  where
    bsMapM_ :: (Word8 -> IO ()) -> ByteString -> IO ()
    bsMapM_ p = BSS.foldl (\io w -> io >> p w) (return ())

recv :: Socket -> Int -> IO ByteString
recv sock = \n -> BSS.pack <$> go [] n
  where
    go :: [Word8] -> Int -> IO [Word8]
    go acc 0 = return (reverse acc)
    go acc n = do
      mw <- readSocket sock
      case mw of
        Just w  -> go (w : acc) (n - 1)
        Nothing -> return (reverse acc)
