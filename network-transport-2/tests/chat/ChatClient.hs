import System.Environment (getArgs)
import Network.Transport
import Network.Transport.TCP (createTransport)
import Control.Concurrent.MVar (MVar, newEmptyMVar, takeMVar, putMVar, newMVar, readMVar, modifyMVar_, modifyMVar)
import Control.Concurrent (forkIO)
import Control.Monad (forever, forM, unless, when)
import qualified Data.ByteString as BS (concat, null)
import qualified Data.ByteString.Char8 as BSC (pack, unpack, getLine)
import Data.Map (Map)
import qualified Data.Map as Map (fromList, elems, insert, member, empty, size, delete, (!))

chatClient :: MVar () -> EndPoint -> EndPointAddress -> IO ()
chatClient done endpoint serverAddr = do
    connect endpoint serverAddr ReliableOrdered
    cOut <- getPeers >>= connectToPeers 
    cIn  <- newMVar Map.empty

    -- Listen for incoming messages
    forkIO . forever $ do
      event <- receive endpoint
      case event of
        Received _ msg ->
          putStrLn . BSC.unpack . BS.concat $ msg 
        ConnectionOpened cid _ addr -> do
          modifyMVar_ cIn $ return . Map.insert cid addr
          didAdd <- modifyMVar cOut $ \conns ->
            if not (Map.member addr conns) 
              then do
                Right conn <- connect endpoint addr ReliableOrdered
                return (Map.insert addr conn conns, True)
              else
                return (conns, False)
          when didAdd $ showNumPeers cOut
        ConnectionClosed cid -> do
          addr <- modifyMVar cIn $ \conns ->
            return (Map.delete cid conns, conns Map.! cid)
          modifyMVar_ cOut $ \conns -> do
            close (conns Map.! addr)
            return (Map.delete addr conns)
          showNumPeers cOut



{-
    chatState <- newMVar (Map.fromList peerConns)
  
    -- Thread to listen to incoming messages
    forkIO . forever $ do
      event <- receive endpoint 
      case event of
        ConnectionOpened _ _ (EndPointAddress addr) -> do
          modifyMVar_ chatState $ \peers -> 
            if not (Map.member addr peers)
              then do
                Right conn <- connect endpoint (EndPointAddress addr) ReliableOrdered 
                return (Map.insert addr conn peers)
              else
                return peers
        Received _ msg ->
          putStrLn . BSC.unpack . BS.concat $ msg 
        ConnectionClosed _ ->
          return ()
  
-}
    -- Thread to interact with the user
    showNumPeers cOut
    let go = do
          msg <- BSC.getLine
          unless (BS.null msg) $ do
            readMVar cOut >>= \conns -> forM (Map.elems conns) $ \conn -> send conn [msg]
            go
    go
    putMVar done ()

  where
    getPeers :: IO [EndPointAddress]
    getPeers = do 
      ConnectionOpened _ _ _ <- receive endpoint
      Received _ msg <- receive endpoint
      ConnectionClosed _ <- receive endpoint
      return . map EndPointAddress . read . BSC.unpack . BS.concat $ msg

    connectToPeers :: [EndPointAddress] -> IO (MVar (Map EndPointAddress Connection))
    connectToPeers addrs = do
      conns <- forM addrs $ \addr -> do
        Right conn <- connect endpoint addr ReliableOrdered
        return (addr, conn)
      newMVar (Map.fromList conns)
      
    showNumPeers :: MVar (Map EndPointAddress Connection) -> IO ()
    showNumPeers cOut = 
      readMVar cOut >>= \conns -> putStrLn $ "# " ++ show (Map.size conns) ++ " peers"
      



main :: IO ()
main = do
  host:port:server:_ <- getArgs
  Right transport <- createTransport host port
  Right endpoint <- newEndPoint transport
  clientDone <- newEmptyMVar

  forkIO $ chatClient clientDone endpoint (EndPointAddress . BSC.pack $ server)

  takeMVar clientDone

