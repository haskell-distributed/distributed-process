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
-- > 0  Left 2
-- > 1  Left 1
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
-- > 0  Left 1
module Traced ( MonadS(..)
              , return
              , (>>=)
              , (>>)
              , fail
              , ifThenElse
              , Showable(..)
              , Traceable(..)
              , traceShow
              ) where

import Prelude hiding 
  ( (>>=)
  , return
  , fail
  , (>>)
#if ! MIN_VERSION_base(4,6,0)
  , catch
#endif
  )
import qualified Prelude
import Control.Exception (catches, Handler(..), SomeException, throwIO, Exception(..), IOException)
import Control.Applicative ((<$>))
import Data.Typeable (Typeable)
import Data.Maybe (catMaybes)
import Data.ByteString (ByteString)
import Data.Int (Int32)
import Control.Concurrent.MVar (MVar)

--------------------------------------------------------------------------------
-- MonadS class                                                               --
--------------------------------------------------------------------------------

-- | Like 'Monad' but bind is only defined for 'Trace'able instances
class MonadS m where
  returnS :: a -> m a 
  bindS   :: Traceable a => m a -> (a -> m b) -> m b
  failS   :: String -> m a
  seqS    :: m a -> m b -> m b

-- | Redefinition of 'Prelude.>>=' 
(>>=) :: (MonadS m, Traceable a) => m a -> (a -> m b) -> m b
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

data Showable = forall a. Show a => Showable a

instance Show Showable where
  show (Showable x) = show x

mapShowable :: (forall a. Show a => a -> Showable) -> Showable -> Showable 
mapShowable f (Showable x) = f x 

traceShow :: Show a => a -> Maybe Showable
traceShow = Just . Showable 

class Traceable a where
  trace :: a -> Maybe Showable 

instance (Traceable a, Traceable b) => Traceable (Either a b) where
  trace (Left x)  = (mapShowable $ Showable . (Left  :: forall c. c -> Either c ())) <$> trace x 
  trace (Right y) = (mapShowable $ Showable . (Right :: forall c. c -> Either () c)) <$> trace y

instance (Traceable a, Traceable b) => Traceable (a, b) where
  trace (x, y) = case (trace x, trace y) of
    (Nothing, Nothing) -> Nothing
    (Just t1, Nothing) -> traceShow t1
    (Nothing, Just t2) -> traceShow t2
    (Just t1, Just t2) -> traceShow (t1, t2)

instance (Traceable a, Traceable b, Traceable c) => Traceable (a, b, c) where
  trace (x, y, z) = case (trace x, trace y, trace z) of
    (Nothing, Nothing, Nothing) -> Nothing 
    (Just t1, Nothing, Nothing) -> traceShow t1
    (Nothing, Just t2, Nothing) -> traceShow t2
    (Just t1, Just t2, Nothing) -> traceShow (t1, t2)
    (Nothing, Nothing, Just t3) -> traceShow t3
    (Just t1, Nothing, Just t3) -> traceShow (t1, t3)
    (Nothing, Just t2, Just t3) -> traceShow (t2, t3)
    (Just t1, Just t2, Just t3) -> traceShow (t1, t2, t3)

instance Traceable a => Traceable (Maybe a) where
  trace Nothing  = traceShow (Nothing :: Maybe ())
  trace (Just x) = mapShowable (Showable . Just) <$> trace x  

instance Traceable a => Traceable [a] where
  trace = traceShow . catMaybes . map trace 

instance Traceable () where
  trace = const Nothing 

instance Traceable Int where
  trace = traceShow 

instance Traceable Int32 where
  trace = traceShow 

instance Traceable Bool where
  trace = const Nothing 

instance Traceable ByteString where
  trace = traceShow 

instance Traceable (MVar a) where
  trace = const Nothing 

instance Traceable [Char] where
  trace = traceShow 

instance Traceable IOException where
  trace = traceShow

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
    show ex ++ "\nTrace:\n" ++ unlines (map (\(i, t) -> show i ++ "\t" ++ t) (zip ([0..] :: [Int]) (take 10 . reverse $ ts)))

traceHandlers :: Traceable a => a -> [Handler b]
traceHandlers a =  case trace a of
  Nothing -> [ Handler $ \ex -> throwIO (ex :: SomeException) ]
  Just t  -> [ Handler $ \(TracedException ts ex) -> throwIO $ TracedException (show t : ts) ex
             , Handler $ \ex -> throwIO $ TracedException [show t] (ex :: SomeException)
             ]

-- | Definition of 'ifThenElse' for use with RebindableSyntax 
ifThenElse :: Bool -> a -> a -> a
ifThenElse True  x _ = x
ifThenElse False _ y = y
