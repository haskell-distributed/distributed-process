{-# LANGUAGE DeriveDataTypeable #-}

module MathsDemo
  ( add
  , divide
  , launchMathServer
  , DivByZero(..)
  , Add(..)
  ) where

import Control.Applicative
import Control.Distributed.Process hiding (call)
import Control.Distributed.Process.Platform
import Control.Distributed.Process.Platform.ManagedProcess
import Control.Distributed.Process.Platform.Time

import Data.Binary (Binary(..))
import Data.Typeable (Typeable)

data Add       = Add    Double Double deriving (Typeable)
data Divide    = Divide Double Double deriving (Typeable)
data DivByZero = DivByZero deriving (Typeable, Eq)

instance Binary Add where
  put (Add x y) = put x >> put y
  get = Add <$> get <*> get

instance Binary Divide where
  put (Divide x y) = put x >> put y
  get = Divide <$> get <*> get

instance Binary DivByZero where
  put DivByZero = return ()
  get = return DivByZero

-- public API

add :: ProcessId -> Double -> Double -> Process Double
add sid x y = call sid (Add x y)

divide :: ProcessId -> Double -> Double
          -> Process (Either DivByZero Double)
divide sid x y = call sid (Divide x y )

launchMathServer :: Process ProcessId
launchMathServer =
  let server = statelessProcess {
      apiHandlers = [
          handleCall_   (\(Add    x y) -> return (x + y))
        , handleCallIf_ (input (\(Divide _ y) -> y /= 0)) handleDivide
        , handleCall_   (\(Divide _ _) -> divByZero)
        , action        (\("stop") -> stop_ ExitNormal)
        ]
    }
  in spawnLocal $ serve () (statelessInit Infinity) server
  where handleDivide :: Divide -> Process (Either DivByZero Double)
        handleDivide (Divide x y) = return $ Right $ x / y

        divByZero :: Process (Either DivByZero Double)
        divByZero = return $ Left DivByZero
