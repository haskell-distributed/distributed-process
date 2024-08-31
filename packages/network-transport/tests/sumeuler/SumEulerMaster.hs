import System.Environment (getArgs)
import Network.Transport
import Network.Transport.TCP (createTransport)
import Control.Concurrent (forkIO)
import Control.Concurrent.MVar (MVar, newEmptyMVar, putMVar, takeMVar)
import Control.Monad (forM, forM_, replicateM_)
import qualified Data.ByteString as BS (concat)
import qualified Data.ByteString.Char8 as BSC (pack, unpack)
import Control.Monad.Trans.Writer (execWriterT, tell)
import Control.Monad.IO.Class (liftIO)

master :: MVar () -> EndPoint -> [String] -> IO ()
master done endpoint workers = do
  conns <- forM workers $ \worker -> do
    Right conn <- connect endpoint (EndPointAddress $ BSC.pack worker) ReliableOrdered
    return conn
  -- Send out requests
  forM_ conns $ \conn -> do
    send conn [BSC.pack $ show 5300]
    close conn
  -- Print all replies
  replies <- execWriterT $ replicateM_ (length workers * 3) $ do
    event <- liftIO $ receive endpoint
    case event of
      Received _ msg ->
        tell [read . BSC.unpack . BS.concat $ msg]
      _ ->
        return ()
  putStrLn $ "Replies: " ++ show (replies :: [Int])
  putMVar done ()

main :: IO ()
main = do
  host:port:workers <- getArgs
  Right transport   <- createTransport host port
  Right endpoint    <- newEndPoint transport
  masterDone        <- newEmptyMVar

  putStrLn $ "Master using workers " ++ show workers

  forkIO $ master masterDone endpoint workers

  takeMVar masterDone

