import Network.Transport
import Network.Transport.TCP (createTransport)
import System.Environment
import Control.Monad
import Data.ByteString.Char8

main :: IO ()
main = do
  [host, port, serverAddr] <- getArgs
  Right transport <- createTransport host port 
  Right endpoint  <- newEndPoint transport

  let addr = EndPointAddress (pack serverAddr)
  Right conn <- connect endpoint addr ReliableOrdered
  send conn [pack "Hello world"]
  close conn

  replicateM_ 3 $ receive endpoint >>= print 

  closeTransport transport
