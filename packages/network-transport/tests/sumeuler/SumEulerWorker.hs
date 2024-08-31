import System.Environment (getArgs)
import Network.Transport
import Network.Transport.TCP (createTransport)
import qualified Data.ByteString.Char8 as BSC (putStrLn, pack, unpack)
import qualified Data.ByteString as BS (concat)
import Control.Concurrent (forkIO)
import Control.Concurrent.MVar (MVar, newEmptyMVar, putMVar, takeMVar)
import System.IO (hFlush, stdout, stderr, hPutStrLn)

mkList :: Int -> [Int]
mkList n = [1 .. n - 1]

relPrime :: Int -> Int -> Bool
relPrime x y = gcd x y == 1

euler :: Int -> Int
euler n = length (filter (relPrime n) (mkList n))

sumEuler :: Int -> Int
sumEuler = sum . (map euler) . mkList

worker :: String -> MVar () -> EndPoint -> IO ()
worker id done endpoint = do
    ConnectionOpened _ _ theirAddr <- receive endpoint
    Right replyChan <- connect endpoint theirAddr ReliableOrdered
    go replyChan
  where
    go replyChan = do
      event <- receive endpoint
      case event of
        ConnectionClosed _ -> do
          close replyChan
          putMVar done ()
        Received _ msg -> do
          let i :: Int
              i = read . BSC.unpack . BS.concat $ msg
          send replyChan [BSC.pack . show $ sumEuler i]
          go replyChan

main :: IO ()
main = do
  (id:host:port:_) <- getArgs
  Right transport  <- createTransport host port
  Right endpoint   <- newEndPoint transport
  workerDone       <- newEmptyMVar

  BSC.putStrLn (endPointAddressToByteString (address endpoint))
  hFlush stdout

  forkIO $ worker id workerDone endpoint

  takeMVar workerDone
