module Data.NotByteString.Internal
  ( unsafeCreate
  , toForeignPtr
  , inlinePerformIO
  ) where

import Data.NotByteString (ByteString, fromByteString, toByteString)
import Foreign.Ptr (Ptr)
import Foreign.ForeignPtr (ForeignPtr)
import Data.Word (Word8)
import qualified Data.ByteString.Internal as BSI 
  ( unsafeCreate
  , toForeignPtr
  , inlinePerformIO
  )

unsafeCreate :: Int -> (Ptr Word8 -> IO ()) -> ByteString
unsafeCreate i f = fromByteString $ BSI.unsafeCreate i f

toForeignPtr :: ByteString -> (ForeignPtr Word8, Int, Int)
toForeignPtr = BSI.toForeignPtr . toByteString 

inlinePerformIO :: IO a -> a
inlinePerformIO = BSI.inlinePerformIO
