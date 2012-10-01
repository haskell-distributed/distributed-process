-- | Like Control.Concurrent.MVar.Strict but reduce to HNF, not NF
{-# LANGUAGE MagicHash, UnboxedTuples #-}
module Control.Distributed.Process.Internal.StrictMVar 
  ( StrictMVar(StrictMVar)
  , newEmptyMVar
  , newMVar
  , takeMVar
  , putMVar
  , withMVar
  , modifyMVar_
  , modifyMVar
  , mkWeakMVar
  ) where

import Control.Applicative ((<$>))
import Control.Monad ((>=>))
import Control.Exception (evaluate)
import qualified Control.Concurrent.MVar as MVar 
  ( MVar
  , newEmptyMVar
  , newMVar
  , takeMVar
  , putMVar
  , withMVar
  , modifyMVar_
  , modifyMVar
  )
import GHC.MVar (MVar(MVar))
import GHC.IO (IO(IO)) 
import GHC.Prim (mkWeak#)
import GHC.Weak (Weak(Weak))

newtype StrictMVar a = StrictMVar (MVar.MVar a)

newEmptyMVar :: IO (StrictMVar a)
newEmptyMVar = StrictMVar <$> MVar.newEmptyMVar

newMVar :: a -> IO (StrictMVar a)
newMVar x = evaluate x >> StrictMVar <$> MVar.newMVar x

takeMVar :: StrictMVar a -> IO a
takeMVar (StrictMVar v) = MVar.takeMVar v

putMVar :: StrictMVar a -> a -> IO ()
putMVar (StrictMVar v) x = evaluate x >> MVar.putMVar v x

withMVar :: StrictMVar a -> (a -> IO b) -> IO b
withMVar (StrictMVar v) = MVar.withMVar v

modifyMVar_ :: StrictMVar a -> (a -> IO a) -> IO ()
modifyMVar_ (StrictMVar v) f = MVar.modifyMVar_ v (f >=> evaluate) 

modifyMVar :: StrictMVar a -> (a -> IO (a, b)) -> IO b
modifyMVar (StrictMVar v) f = MVar.modifyMVar v (f >=> evaluateFst)
  where
    evaluateFst :: (a, b) -> IO (a, b)
    evaluateFst (x, y) = evaluate x >> return (x, y)

mkWeakMVar :: StrictMVar a -> IO () -> IO (Weak (StrictMVar a))
mkWeakMVar m@(StrictMVar (MVar m#)) f = IO $ \s ->
  case mkWeak# m# m f s of (# s1, w #) -> (# s1, Weak w #)
