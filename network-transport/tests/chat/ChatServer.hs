import System.Environment (getArgs)
import Network.Transport
import Network.Transport.TCP (createTransport)
import Control.Monad.State (evalStateT, modify, get)
import Control.Monad (forever)
import Control.Monad.IO.Class (liftIO)
import qualified Data.IntMap as IntMap (empty, insert, delete, elems)
import qualified Data.ByteString.Char8 as BSC (pack)

main :: IO ()
main = do
  host:port:_     <- getArgs
  Right transport <- createTransport host port
  Right endpoint  <- newEndPoint transport

  putStrLn $ "Chat server ready at " ++ (show . endPointAddressToByteString . address $ endpoint)

  flip evalStateT IntMap.empty . forever $ do
    event <- liftIO $ receive endpoint
    case event of
      ConnectionOpened cid _ addr -> do
        get >>= \clients -> liftIO $ do
          Right conn <- connect endpoint addr ReliableOrdered
          send conn [BSC.pack . show . IntMap.elems $ clients]
          close conn
        modify $ IntMap.insert cid (endPointAddressToByteString addr) 
      ConnectionClosed cid ->
        modify $ IntMap.delete cid
