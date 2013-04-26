{- ProcessRing benchmarks.

To run the benchmarks, select a value for the ring size (sz) and
the number of times to send a message around the ring
-}
import Control.Monad
import Control.Distributed.Process hiding (catch)
import Control.Distributed.Process.Node
import Control.Exception (SomeException, catch)
import Network.Transport.TCP (createTransport, defaultTCPParameters)
import System.Environment
import System.Console.GetOpt

data Options = Options
  { optRingSize   :: Int
  , optIterations :: Int
  , optForward    :: Bool
  , optParallel   :: Bool
  } deriving Show

initialProcess :: Options -> Process ()
initialProcess op =
  let ringSz = optRingSize op
      msgCnt = optIterations op
      fwd    = optForward op
      msg    = ("foobar", "baz")
  in do
    self <- getSelfPid
    ring <- makeRing fwd ringSz self
    forM_ [1..msgCnt] (\_ -> send ring msg)
    collect msgCnt
  where relay' pid = do
          msg <- expect :: Process (String, String)
          send pid msg
          relay' pid

        forward' pid =
          receiveWait [ matchAny (\m -> forward m pid) ] >> forward' pid

        makeRing :: Bool -> Int -> ProcessId -> Process ProcessId
        makeRing !f !n !pid
          | n == 0    = go f pid
          | otherwise = go f pid >>= makeRing f (n - 1)

        go :: Bool -> ProcessId -> Process ProcessId
        go False next = spawnLocal $ relay' next
        go True  next = spawnLocal $ forward' next

        collect :: Int -> Process ()
        collect !n
          | n == 0    = return ()
          | otherwise = do
                receiveWait [
                    matchIf    (\(a, b) -> a == "foobar" && b == "baz")
                               (\_ -> return ())
                  , matchAny   (\_ -> error "unexpected input!")
                  ]
                collect (n - 1)

defaultOptions :: Options
defaultOptions = Options
  { optRingSize   = 10
  , optIterations = 100
  , optForward    = False
  , optParallel   = False
  }

options :: [OptDescr (Options -> Options)]
options =
    [ Option ['s'] ["ring-size"] (OptArg optSz "SIZE") "# of processes in ring"
    , Option ['i'] ["iterations"] (OptArg optMsgCnt "ITER") "# of times to send"
    , Option ['f'] ["forward"]
        (NoArg (\opts -> opts { optForward = True }))
        "use `forward' instead of send - default = False"
    , Option ['p'] ["parallel"]
        (NoArg (\opts -> opts { optForward = True }))
        "send in parallel and consume sequentially - default = False"
    ]

optMsgCnt :: Maybe String -> Options -> Options
optMsgCnt Nothing  opts = opts
optMsgCnt (Just c) opts = opts { optIterations = ((read c) :: Int) }

optSz :: Maybe String -> Options -> Options
optSz Nothing  opts = opts
optSz (Just s) opts = opts { optRingSize = ((read s) :: Int) }

parseArgv :: [String] -> IO (Options, [String])
parseArgv argv = do
  pn <- getProgName
  case getOpt Permute options argv of
    (o,n,[]  ) -> return (foldl (flip id) defaultOptions o, n)
    (_,_,errs) -> ioError (userError (concat errs ++ usageInfo (header pn) options))
  where header pn' = "Usage: " ++ pn' ++ " [OPTION...]"

main :: IO ()
main = do
  argv <- getArgs
  (opt, _) <- parseArgv argv
  putStrLn $ "options: " ++ (show opt)
  Right transport <- createTransport "127.0.0.1" "8090" defaultTCPParameters
  node <- newLocalNode transport initRemoteTable
  catch (runProcess node $ initialProcess opt)
        (\(e :: SomeException) -> putStrLn $ "ERROR: " ++ (show e))

