module TestAuxiliary (runTest, runTests, forkTry) where

import Prelude hiding (catch)
import Control.Concurrent (myThreadId, forkIO, ThreadId, throwTo)
import Control.Monad (liftM2, unless)
import Control.Exception (SomeException, try, catch)
import System.Timeout (timeout)
import System.IO (stdout, hFlush)
import System.Console.ANSI ( SGR(SetColor, Reset)
                           , Color(Red, Green)
                           , ConsoleLayer(Foreground)
                           , ColorIntensity(Vivid)
                           , setSGR
                           )

-- | Like fork, but throw exceptions in the child thread to the parent
forkTry :: IO () -> IO ThreadId 
forkTry p = do
  tid <- myThreadId
  forkIO $ catch p (\e -> throwTo tid (e :: SomeException))

-- | Run the given test, catching timeouts and exceptions
runTest :: String -> IO () -> IO Bool 
runTest description test = do
  putStr $ "Running " ++ show description ++ ": "
  hFlush stdout
  done <- try . timeout 10000000 $ test
  case done of
    Left err        -> failed $ "(exception: " ++ show (err :: SomeException) ++ ")" 
    Right Nothing   -> failed $ "(timeout)"
    Right (Just ()) -> ok 
  where
    failed :: String -> IO Bool 
    failed err = do
      setSGR [SetColor Foreground Vivid Red]
      putStr "failed "
      setSGR [Reset]
      putStrLn err
      return False

    ok :: IO Bool 
    ok = do
      setSGR [SetColor Foreground Vivid Green]
      putStrLn "ok"
      setSGR [Reset]
      return True

-- | Run a bunch of tests and throw an exception if any fails 
runTests :: [(String, IO ())] -> IO ()
runTests tests = do
  success <- foldr (liftM2 (&&) . uncurry runTest) (return True) $ tests
  unless success $ fail "Some tests failed"
