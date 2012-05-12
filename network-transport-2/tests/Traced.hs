{-# LANGUAGE RebindableSyntax, ScopedTypeVariables, DeriveDataTypeable, FlexibleInstances, OverlappingInstances #-}
-- | Add tracing to the IO monad (see examples). 
-- 
-- [Usage]
-- 
-- > {-# LANGUAGE RebindableSyntax #-}
-- > import Prelude hiding (catch, (>>=), (>>), return, fail)
-- > import Traced
--
-- [Example]
--
-- > test1 :: IO Int
-- > test1 = do
-- >   Left x  <- return (Left 1 :: Either Int Int)
-- >   putStrLn "Hello world"
-- >   Right y <- return (Left 2 :: Either Int Int)
-- >   return (x + y)
--
-- outputs 
--
-- > Hello world
-- > *** Exception: user error (Pattern match failure in do expression at Traced.hs:187:3-9)
-- > Trace:
-- > 0	Left 2
-- > 1	Left 1
--
-- [Guards]
--
-- Use the following idiom instead of using 'Control.Monad.guard':
--
-- > test2 :: IO Int
-- > test2 = do
-- >   Left x <- return (Left 1 :: Either Int Int)
-- >   True   <- return (x == 3)
-- >   return x 
--
-- The advantage of this idiom is that it gives you line number information when the guard fails:
--
-- > *Traced> test2
-- > *** Exception: user error (Pattern match failure in do expression at Traced.hs:193:3-6)
-- > Trace:
-- > 0	Left 1
module Traced ( MonadS(..)
              , return
              , (>>=)
              , (>>)
              , fail
              , ifThenElse
              , Trace(..)
              ) where

import Prelude hiding ((>>=), return, fail, catch, (>>))
import qualified Prelude
import Data.String (fromString)
import Control.Exception (catches, Handler(..), SomeException, throw, Exception(..), IOException)
import Control.Applicative ((<$>))
import Data.Typeable (Typeable)
import Data.Maybe (catMaybes)
import Data.List (intersperse)
import Data.ByteString (ByteString)
import Data.Int (Int32)
import Control.Concurrent.MVar (MVar)

--------------------------------------------------------------------------------
-- MonadS class                                                               --
--------------------------------------------------------------------------------

-- | Like 'Monad' but bind is only defined for 'Trace'able instances
class MonadS m where
  returnS :: a -> m a 
  bindS   :: Trace a => m a -> (a -> m b) -> m b
  failS   :: String -> m a
  seqS    :: m a -> m b -> m b

-- | Redefinition of 'Prelude.>>=' 
(>>=) :: (MonadS m, Trace a) => m a -> (a -> m b) -> m b
(>>=) = bindS

-- | Redefinition of 'Prelude.>>'
(>>) :: MonadS m => m a -> m b -> m b
(>>) = seqS

-- | Redefinition of 'Prelude.return'
return :: MonadS m => a -> m a
return = returnS

-- | Redefinition of 'Prelude.fail'
fail :: MonadS m => String -> m a
fail = failS 

--------------------------------------------------------------------------------
-- Trace typeclass (for adding elements to a trace                            --
--------------------------------------------------------------------------------

-- | Used to add a term to the trace
class Trace a where
  -- | Return 'Nothing' not to add the term to the trace
  trace :: a -> Maybe String

instance (Trace a, Trace b) => Trace (Either a b) where
  trace (Left x)  = ("Left " ++) <$> trace x 
  trace (Right y) = ("Right " ++) <$> trace y 

instance Trace a => Trace [a] where
  trace as = Just $ "[" ++ (concat . intersperse "," . catMaybes . map trace $ as) ++ "]"

instance (Trace a, Trace b) => Trace (a, b) where
  trace (x, y) = case (trace x, trace y) of
    (Nothing, Nothing) -> Nothing
    (Just t1, Nothing) -> Just t1
    (Nothing, Just t2) -> Just t2
    (Just t1, Just t2) -> Just $ "(" ++ t1 ++ ", " ++ t2 ++ ")"

instance (Trace a, Trace b, Trace c) => Trace (a, b, c) where
  trace (x, y, z) = case (trace x, trace y, trace z) of
    (Nothing, Nothing, Nothing) -> Nothing
    (Just t1, Nothing, Nothing) -> Just t1
    (Nothing, Just t2, Nothing) -> Just t2
    (Nothing, Nothing, Just t3) -> Just t3
    (Just t1, Just t2, Nothing) -> Just $ "(" ++ t1 ++ "," ++ t2 ++ ")"
    (Just t1, Nothing, Just t3) -> Just $ "(" ++ t1 ++ "," ++ t3 ++ ")"
    (Nothing, Just t2, Just t3) -> Just $ "(" ++ t2 ++ "," ++ t3 ++ ")"
    (Just t1, Just t2, Just t3) -> Just $ "(" ++ t1 ++ "," ++ t2 ++ "," ++ t2 ++ "," ++ t3 ++ ")"

instance Trace () where
  trace = const Nothing

instance Trace Int where
  trace = Just . show

instance Trace Int32 where
  trace = Just . show

instance Trace Bool where
  trace = const Nothing

instance Trace ByteString where
  trace = Just . show

instance Trace (MVar a) where
  trace = const Nothing 

instance Trace [Char] where
  trace = Just . show 

instance Trace IOException where
  trace = Just . show

--------------------------------------------------------------------------------
-- IO instance for MonadS                                                     --
--------------------------------------------------------------------------------

data TracedException = TracedException [String] SomeException
  deriving Typeable

instance Exception TracedException

-- | Add tracing to 'IO' (see examples) 
instance MonadS IO where
  returnS = Prelude.return
  bindS   = \x f -> x Prelude.>>= \a -> catches (f a) (traceHandlers a)
  failS   = Prelude.fail
  seqS    = (Prelude.>>)

instance Show TracedException where
  show (TracedException ts ex) = 
    show ex ++ "\nTrace:\n" ++ unlines (map (\(i, t) -> show i ++ "\t" ++ t) (zip ([0..] :: [Int]) (reverse ts)))

traceHandlers :: Trace a => a -> [Handler b]
traceHandlers a =  case trace a of
  Nothing -> [ Handler $ \(ex :: SomeException)   -> throw ex ]
  Just t  -> [ Handler $ \(TracedException ts ex) -> throw $ TracedException (t : ts) ex
             , Handler $ \(ex :: SomeException)   -> throw $ TracedException [t] ex
             ]
  
-- | Definition of 'ifThenElse' for use with RebindableSyntax 
ifThenElse :: Bool -> a -> a -> a
ifThenElse True  x _ = x
ifThenElse False _ y = y
