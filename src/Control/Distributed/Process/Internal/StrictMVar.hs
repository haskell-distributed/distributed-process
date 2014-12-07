-- | Like Control.Concurrent.MVar.Strict but reduce to HNF, not NF
{-# LANGUAGE CPP, MagicHash, UnboxedTuples #-}
module Control.Distributed.Process.Internal.StrictMVar
  ( StrictMVar(StrictMVar)
  , newEmptyMVar
  , newMVar
  , takeMVar
  , putMVar
  , readMVar
  , withMVar
  , modifyMVar_
  , modifyMVar
  , modifyMVarMasked
  , mkWeakMVar
  ) where

import Control.Applicative ((<$>))
import Control.Monad ((>=>))
#if MIN_VERSION_base(4,6,0)
import Control.Exception (evaluate)
#else
import Control.Exception (evaluate, mask_, onException)
#endif
import qualified Control.Concurrent.MVar as MVar
  ( MVar
  , newEmptyMVar
  , newMVar
  , takeMVar
  , putMVar
  , readMVar
  , withMVar
  , modifyMVar_
  , modifyMVar
#if MIN_VERSION_base(4,6,0)
  , modifyMVarMasked
#endif
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

readMVar :: StrictMVar a -> IO a
readMVar (StrictMVar v) = MVar.readMVar v

withMVar :: StrictMVar a -> (a -> IO b) -> IO b
withMVar (StrictMVar v) = MVar.withMVar v

modifyMVar_ :: StrictMVar a -> (a -> IO a) -> IO ()
modifyMVar_ (StrictMVar v) f = MVar.modifyMVar_ v (f >=> evaluate)

modifyMVar :: StrictMVar a -> (a -> IO (a, b)) -> IO b
modifyMVar (StrictMVar v) f = MVar.modifyMVar v (f >=> evaluateFst)
  where
    evaluateFst :: (a, b) -> IO (a, b)
    evaluateFst (x, y) = evaluate x >> return (x, y)

modifyMVarMasked :: StrictMVar a -> (a -> IO (a, b)) -> IO b
modifyMVarMasked (StrictMVar v) f =
#if MIN_VERSION_base(4,6,0)
    MVar.modifyMVarMasked v (f >=> evaluateFst)
#else
  mask_ $ do
    a      <- MVar.takeMVar v
    (a',b) <- (f a >>= evaluate) `onException` MVar.putMVar v a
    MVar.putMVar v a'
    return b
#endif
  where
    evaluateFst :: (a, b) -> IO (a, b)
    evaluateFst (x, y) = evaluate x >> return (x, y)

mkWeakMVar :: StrictMVar a -> IO () -> IO (Weak (StrictMVar a))
mkWeakMVar m@(StrictMVar (MVar m#)) f = IO $ \s ->
  case mkWeak# m# m f s of (# s1, w #) -> (# s1, Weak w #)
