{-# LANGUAGE RebindableSyntax #-}
-- | Monad to trace all terms that get bound
-- 
-- Examples:
--
-- > test1 :: IO Int
-- > test1 = runTraced $ do
-- >   Left x  <- return (Left 1 :: Either Int Int)
-- >   Left y  <- return (Left 2 :: Either Int Int)
-- >   return (x + y)
--
-- outputs
--
-- > 3
--
-- as expected. Things get more interesting when we have a pattern match failure:
--
-- > test2 :: IO Int
-- > test2 = runTraced $ do
-- >   Left x  <- return (Left 1 :: Either Int Int)
-- >   Right y <- return (Left 2 :: Either Int Int)
-- >   return (x + y)
--
-- outputs
--
-- > *** Exception: user error (Pattern match failure in do expression at Traced.hs:96:3-9
-- > Trace:
-- >   Left 1
-- >   Left 2
-- > )
--
-- The module also exports a 'guard' function which is used in similar fashion
-- to the 'guard' from "Control.Monad":
--
-- > test3 :: IO Int
-- > test3 = runTraced $ do
-- >   Left x  <- return (Left 1 :: Either Int Int)
-- >   Left y  <- return (Left 2 :: Either Int Int)
-- >   guard (x == 3)
-- >   return (x + y)
--
-- outputs
--
-- > *** Exception: user error (Guard failed
-- > Trace:
-- >   Left 1
-- >   Left 2
-- > )
--  
-- Note that we get no line-number info this way; we can fix this by saying
--
-- > test4 :: IO Int
-- > test4 = runTraced $ do
-- >   Left x  <- return (Left 1 :: Either Int Int)
-- >   Left y  <- return (Left 2 :: Either Int Int)
-- >   True <- return (x == 3)
-- >   return (x + y)
--
-- which outputs
--
-- > *** Exception: user error (Pattern match failure in do expression at Traced.hs:110:3-6
-- > Trace:
-- >   Left 1
-- >   Left 2
-- >   False
-- > )
--
-- The module also exports a 'liftIO', and does not trace ignored unit values (from '>>'): 
--
-- > test5 :: IO Int
-- > test5 = runTraced $ do
-- >   Left x <- return (Left 1 :: Either Int Int)
-- >   liftIO $ putStrLn "hi"  
-- >   Left y <- return (Left 2 :: Either Int Int)
-- >   True   <- return (y == 1)
-- >   return (x + y)
-- 
-- outputs
--
-- > hi
-- > *** Exception: user error (Pattern match failure in do expression at Traced.hs:137:3-6
-- > Trace:
-- >   Left 1
-- >   Left 2
-- >   False
-- > )
--
-- Every Monad is also a MonadS, but not vice versa.

module Traced ( -- Subclass of monads where bind is defined only for showable arguments 
              MonadS(..)
            , return
            , (>>=)
            , (>>)
            , fail
            , guard
              -- MonadS instance that shows a trace of all bound terms when an error occurs
            , Traced
            , runTraced
            , liftIO
            ) where

import Prelude hiding ((>>=), return, fail, catch, (>>))
import qualified Prelude
import Data.String (fromString)

class MonadS m where
  returnS :: a -> m a 
  bindS   :: Show a => m a -> (a -> m b) -> m b
  failS   :: String -> m a
  seqS    :: Show a => m a -> m b -> m b

instance MonadS IO where
  returnS = Prelude.return
  bindS   = (Prelude.>>=)
  failS   = Prelude.fail
  seqS    = (Prelude.>>)

newtype Traced a = Traced { unTraced :: IO ([String], Either String a) }

instance MonadS Traced where
  returnS x = Traced $ Prelude.return ([], Right x) 
  x `bindS` f = Traced $ unTraced x Prelude.>>= \(trace, result) ->
    case result of
      Left err -> Prelude.return (trace, Left err)
      Right a  -> unTraced (f a) Prelude.>>= \(trace', result') ->
        Prelude.return (trace ++ show a : trace', result')
  x `seqS` y = Traced $ unTraced x Prelude.>>= \(trace, result) ->
    case result of
      Left err -> Prelude.return (trace, Left err)
      Right a  -> unTraced y Prelude.>>= \(trace', result') ->
        Prelude.return (trace ++ trace', result')
  failS err = Traced $ Prelude.return ([], Left err)

runTraced :: Traced a -> IO a
runTraced (Traced x) = x Prelude.>>= \(trace, ma) ->
  case ma of
    Left err -> Prelude.fail $ err ++ "\nTrace:\n" ++ showTrace trace
    Right a  -> Prelude.return a 

showTrace :: [String] -> String
showTrace = unlines . map (\xs -> ' ' : ' ' : xs) 

guard :: MonadS m => Bool -> m ()
guard True  = returnS ()
guard False = failS "Guard failed" 

(>>=) :: (MonadS m, Show a) => m a -> (a -> m b) -> m b
(>>=) = bindS

(>>) :: (MonadS m, Show a) => m a -> m b -> m b
(>>) = seqS

return :: MonadS m => a -> m a
return = returnS

fail :: MonadS m => String -> m a
fail = failS 

liftIO :: IO a -> Traced a
liftIO x = Traced $ x Prelude.>>= \a -> Prelude.return ([], Right a) 
