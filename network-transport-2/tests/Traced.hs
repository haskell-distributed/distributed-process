{-# LANGUAGE RebindableSyntax, FlexibleInstances, UndecidableInstances, ScopedTypeVariables, DeriveDataTypeable #-}
-- | Add "tracing" to the IO monad (see examples). 
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
-- > *** Exception: user error (Pattern match failure in do expression at tests/Traced.hs:107:3-9)
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
-- > *Traced> test3
-- > *** Exception: user error (Pattern match failure in do expression at tests/Traced.hs:103:3-6)
-- > Trace:
-- > 0	False
-- > 1	Left 1
module Traced ( MonadS(..)
              , return
              , (>>=)
              , (>>)
              , fail
              ) where

import Prelude hiding ((>>=), return, fail, catch, (>>))
import qualified Prelude
import Data.String (fromString)
import Control.Exception (catches, Handler(..), SomeException, throw, Exception(..))
import Data.Typeable (Typeable)

--------------------------------------------------------------------------------
-- MonadS class                                                               --
--------------------------------------------------------------------------------

-- | Like 'Monad' but bind is only defined for 'Showable' instances
class MonadS m where
  returnS :: a -> m a 
  bindS   :: Show a => m a -> (a -> m b) -> m b
  failS   :: String -> m a
  seqS    :: m a -> m b -> m b

-- | Redefinition of 'Prelude.>>=' 
(>>=) :: (MonadS m, Show a) => m a -> (a -> m b) -> m b
(>>=) = bindS

-- | Redefinition of 'Prelude.>>'
(>>) :: (MonadS m, Show a) => m a -> m b -> m b
(>>) = seqS

-- | Redefinition of 'Prelude.return'
return :: MonadS m => a -> m a
return = returnS

-- | Redefinition of 'Prelude.fail'
fail :: MonadS m => String -> m a
fail = failS 

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
  show (TracedException trace ex) = 
    show ex ++ "\nTrace:\n" ++ unlines (map (\(i, t) -> show i ++ "\t" ++ t) (zip ([0..] :: [Int]) (reverse trace)))

traceHandlers :: Show a => a -> [Handler b]
traceHandlers a = 
  [ Handler $ \(TracedException trace ex) -> throw $ TracedException (show a : trace) ex
  , Handler $ \(ex :: SomeException) -> throw $ TracedException [show a] ex
  ]
