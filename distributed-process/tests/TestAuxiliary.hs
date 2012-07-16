{-# OPTIONS_GHC -fno-warn-orphans #-}
module TestAuxiliary ( -- Running tests
                       runTest
                     , runTests
                       -- Writing tests
                     , forkTry
                     , trySome
                     , randomThreadDelay
                     ) where


#if ! MIN_VERSION_base(4,6,0)
import Prelude hiding (catch)
#endif

import Control.Concurrent (myThreadId, forkIO, ThreadId, throwTo, threadDelay)
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
import System.Random (randomIO)

-- | Like fork, but throw exceptions in the child thread to the parent
forkTry :: IO () -> IO ThreadId 
forkTry p = do
  tid <- myThreadId
  forkIO $ catch p (\e -> throwTo tid (e :: SomeException))

-- | Like try, but specialized to SomeException
trySome :: IO a -> IO (Either SomeException a)
trySome = try

-- | Run the given test, catching timeouts and exceptions
runTest :: String -> IO () -> IO Bool 
runTest description test = do
  putStr $ "Running " ++ show description ++ ": "
  hFlush stdout
  done <- try . timeout 60000000 $ test -- 60 seconds
  case done of
    Left err        -> failed $ "(exception: " ++ show (err :: SomeException) ++ ")" 
    Right Nothing   -> failed "(timeout)"
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
  success <- foldr (liftM2 (&&) . uncurry runTest) (return True) tests
  unless success $ fail "Some tests failed"

-- | Random thread delay between 0 and the specified max 
randomThreadDelay :: Int -> IO ()
randomThreadDelay maxDelay = do
  delay <- randomIO :: IO Int
  threadDelay (delay `mod` maxDelay) 
