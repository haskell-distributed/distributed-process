module Data.NotByteString.NBS 
  ( recv
  , sendMany
  ) where

import Control.Applicative ((<$>))
import Data.NotByteString (ByteString, fromByteString, toByteString)
import Network.Socket (Socket)
import qualified Network.Socket.ByteString as NSB (recv, sendMany)

recv :: Socket -> Int -> IO ByteString
recv sock n = fromByteString <$> NSB.recv sock n

sendMany :: Socket -> [ByteString] -> IO ()
sendMany sock = NSB.sendMany sock . map toByteString 
