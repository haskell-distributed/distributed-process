{- ProcessRing benchmarks.

To run the benchmarks, select a value for the ring size (sz) and
the number of times to send a message around the ring

-}

{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE ScopedTypeVariables #-}

import Control.Monad
import Control.Distributed.Process hiding (catch)
import Control.Distributed.Process.Node
import Control.Exception (catch, SomeException)
import Network.Transport.TCP (createTransport, defaultTCPParameters)
import System.Environment
import System.Console.GetOpt

data Options = Options
  { optRingSize   :: Int
  , optIterations :: Int
  , optForward    :: Bool
  , optParallel   :: Bool
  , optUnsafe     :: Bool
  } deriving Show

initialProcess :: Options -> Process ()
initialProcess op =
  let ringSz = optRingSize op
      msgCnt = optIterations op
      fwd    = optForward op
      unsafe = optUnsafe op
      msg    = ("foobar", "baz")
  in do
    self <- getSelfPid
    ring <- makeRing fwd unsafe ringSz self
    forM_ [1..msgCnt] (\_ -> send ring msg)
    collect msgCnt
  where relay fsend pid = do
          msg <- expect :: Process (String, String)
          fsend pid msg
          relay fsend pid

        forward' pid =
          receiveWait [ matchAny (\m -> forward m pid) ] >> forward' pid

        makeRing :: Bool -> Bool -> Int -> ProcessId -> Process ProcessId
        makeRing !f !u !n !pid
          | n == 0    = go f u pid
          | otherwise = go f u pid >>= makeRing f u (n - 1)

        go :: Bool -> Bool -> ProcessId -> Process ProcessId
        go False False next = spawnLocal $ relay send next
        go False True  next = spawnLocal $ relay unsafeSend next
        go True  _     next = spawnLocal $ forward' next

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
  , optUnsafe     = False
  }

options :: [OptDescr (Options -> Options)]
options =
    [ Option ['s'] ["ring-size"] (OptArg optSz "SIZE") "# of processes in ring"
    , Option ['i'] ["iterations"] (OptArg optMsgCnt "ITER") "# of times to send"
    , Option ['f'] ["forward"]
        (NoArg (\opts -> opts { optForward = True }))
        "use `forward' instead of send - default = False"
    , Option ['u'] ["unsafe-send"]
        (NoArg (\opts -> opts { optUnsafe = True }))
        "use 'unsafeSend' (ignored with -f) - default = False"
    , Option ['p'] ["parallel"]
        (NoArg (\opts -> opts { optParallel = True }))
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
  catch (void $ runProcess node $ initialProcess opt)
        (\(e :: SomeException) -> putStrLn $ "ERROR: " ++ (show e))
