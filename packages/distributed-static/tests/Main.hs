{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StaticPointers #-}
module Main (main) where

import Control.DeepSeq (force)
import Control.Distributed.Static
    ( Closure,
      closure,
      unclosure,
      closureApplyStatic,
      closureApply,
      closureCompose,
      closureSplit )
import Control.Exception (IOException, evaluate, try)
import Data.Binary (decode, encode)
import Data.ByteString.Lazy (ByteString)
import qualified Data.ByteString.Lazy as BL
import Data.List (isInfixOf)
import Data.Typeable (Typeable)
import Data.Word (Word64)
import GHC.StaticPtr (IsStatic (fromStaticPtr), StaticPtr)
import Test.Tasty (TestTree, defaultMain, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

-- The closures below are deliberately not point-free: until GHC 10, there were
-- syntactically-valid uses of `static` that were meaningless. See GHC proposal 732

-- The example from /Towards Haskell in the Cloud/
addEnv :: ByteString -> Int -> Int
addEnv bs y = decode bs + y

addClosure :: Int -> Closure (Int -> Int)
addClosure x = closure (static addEnv) (encode x)

intClosure :: Int -> Closure Int
intClosure x = closure (static decode) (encode x)

-- Same type as 'addEnv', but a different pointer
subEnv :: ByteString -> Int -> Int
subEnv bs y = y - decode bs

subClosure :: Int -> Closure (Int -> Int)
subClosure x = closure (static subEnv) (encode x)

succInt :: Int -> Int
succInt = (+ 1)

plus :: Int -> Int -> Int
plus = (+)

addIO :: Int -> Int -> IO Int
addIO a b = return (a + b)

-- A polymorphic static pointer
idPtr :: Typeable a => StaticPtr (a -> a)
idPtr = static id

roundTrip :: Closure a -> Closure a
roundTrip = decode . encode

main :: IO ()
main = defaultMain tests

tests :: TestTree
tests = testGroup "distributed-static"
  [ testGroup "closure"
      [ testCase "unclosure" $ do
          f <- unclosure (addClosure 3)
          f 4 @?= 7
      , testCase "binary round trip" $ do
          f <- unclosure (roundTrip (addClosure 3))
          f 4 @?= 7
      ]
  , testGroup "combinators"
      [ testCase "closureApplyStatic" $ do
          x <- unclosure (roundTrip (closureApplyStatic (static succInt) (intClosure 1)))
          x @?= 2
      , testCase "closureApply" $ do
          x <- unclosure (roundTrip (closureApply (addClosure 3) (intClosure 4)))
          x @?= 7
      , testCase "closureCompose" $ do
          f <- unclosure (roundTrip (closureCompose (addClosure 1) (addClosure 10)))
          f 100 @?= 111
      , testCase "closureSplit" $ do
          f <- unclosure (roundTrip (closureSplit (addClosure 1) (addClosure 2)))
          f (10, 20) @?= (11, 22)
      , testCase "nested combinators" $ do
          let plusOne   = closureApplyStatic (static plus) (intClosure 1)
              two       = closureApplyStatic (static succInt) (intClosure 1)
              composed  = closureCompose plusOne (addClosure 10)
          x <- unclosure (roundTrip (closureApply composed two))
          x @?= 13
      , testCase "closures returning IO actions" $ do
          -- Regression test: the combinators erase types internally, and GHC
          -- miscompiled this with -O if the erased type was an empty data type.
          let c = closureApplyStatic (static addIO) (intClosure 1) `closureApply` intClosure 2
          action <- unclosure (roundTrip c)
          r <- action
          r @?= 3
      ]
  , testGroup "IsStatic"
      [ testCase "a static form is a closure" $ do
          let c = static (42 :: Int) :: Closure Int
          x <- unclosure (roundTrip c)
          x @?= 42
      , testCase "a static form as an argument to a combinator" $ do
          let c = closureApply (static succInt) (intClosure 1)
          x <- unclosure (roundTrip c)
          x @?= 2
      , testCase "polymorphic pointer at several types" $ do
          f <- unclosure (roundTrip (fromStaticPtr (idPtr :: StaticPtr (Int -> Int))))
          f 1 @?= 1
          g <- unclosure (roundTrip (fromStaticPtr (idPtr :: StaticPtr (String -> String))))
          g "a" @?= "a"
      ]
  , testGroup "wire format"
      [ testCase "a pointer is a tag and a key" $
          BL.length (encode (static (42 :: Int) :: Closure Int)) @?= 1 + 16
      , testCase "an application is serialized in place" $ do
          -- Not as an encoded environment, which would add a length prefix
          let f = addClosure 1
              x = intClosure 2
          BL.length (encode (closureApply f x)) @?= 1 + BL.length (encode f) + BL.length (encode x)
      ]
  , testGroup "instances"
      [ testCase "Eq and Ord" $ do
          addClosure 1 @?= addClosure 1
          assertBool "different environments" (addClosure 1 /= addClosure 2)
          assertBool "different pointers" (addClosure 1 /= subClosure 1)
          assertBool "ordering" (compare (addClosure 1) (addClosure 2) /= EQ)
          roundTrip (addClosure 1) @?= addClosure 1
      , testCase "Show" $
          assertBool "constructor" ("closure" `isInfixOf` show (addClosure 1))
      , testCase "NFData" $ do
          _ <- evaluate (force (addClosure 1))
          return ()
      ]
  , testGroup "invalid pointers"
      [ testCase "decoding succeeds but resolving fails" $ do
          let bad = decode (encode (0 :: Word64, 0 :: Word64, 0 :: Word64)) :: Closure Int
          _ <- evaluate bad
          r <- try (unclosure bad)
          case r of
            Left (_ :: IOException) -> return ()
            Right (_ :: Int)        -> assertFailure "resolved an invalid pointer"
      , testCase "an invalid pointer inside an application" $ do
          let bad = decode (encode (0 :: Word64, 0 :: Word64, 0 :: Word64)) :: Closure Int
          r <- try (unclosure (closureApply (addClosure 1) bad))
          case r of
            Left (_ :: IOException) -> return ()
            Right (_ :: Int)        -> assertFailure "resolved an invalid pointer"
      ]
  ]
