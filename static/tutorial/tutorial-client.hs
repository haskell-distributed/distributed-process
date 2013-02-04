import Network.Transport
import Network.Transport.TCP (createTransport, defaultTCPParameters)
import System.Environment
import Control.Monad
import Data.ByteString.Char8

main :: IO ()
main = do
  [host, port, serverAddr] <- getArgs
  Right transport <- createTransport host port defaultTCPParameters
  Right endpoint  <- newEndPoint transport

  let addr = EndPointAddress (pack serverAddr)
--  Right conn <- connect endpoint addr ReliableOrdered defaultConnectHints
  x <- connect endpoint addr ReliableOrdered defaultConnectHints
  let conn = case x of
              Right conn -> conn
              Left err -> error$ "Error connecting: "++show err
  send conn [pack "Hello world"]
  close conn

  replicateM_ 3 $ receive endpoint >>= print

  closeTransport transport
