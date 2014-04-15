
import Data.Rank1Typeable
import Data.Rank1Dynamic

import Test.HUnit hiding (Test)
import Test.Framework
import Test.Framework.Providers.HUnit
import Unsafe.Coerce


main :: IO ()
main = defaultMain tests

tests :: [Test]
tests =
  [ testGroup "Examples of isInstanceOf"
      [ testCase "CANNOT use a term of type 'Int -> Bool' as 'Int -> Int'" $
          typeOf (undefined :: Int -> Int) `isInstanceOf` typeOf (undefined :: Int -> Bool)
          @?= Left "Cannot unify Int and Bool"

      , testCase "CAN use a term of type 'forall a. a -> Int' as 'Int -> Int'" $
          typeOf (undefined :: Int -> Int) `isInstanceOf` typeOf (undefined :: ANY -> Int)
          @?= Right ()

      , testCase "CAN use a term of type 'forall a b. a -> b' as 'forall a. a -> a'" $
          typeOf (undefined :: ANY -> ANY) `isInstanceOf` typeOf (undefined :: ANY -> ANY1)
          @?= Right ()

      , testCase "CANNOT use a term of type 'forall a. a -> a' as 'forall a b. a -> b'" $
          typeOf (undefined :: ANY -> ANY1) `isInstanceOf` typeOf (undefined :: ANY -> ANY)
          @?= Left "Cannot unify Succ and Zero"

      , testCase "CAN use a term of type 'forall a. a' as 'forall a. a -> a'" $
          typeOf (undefined :: ANY -> ANY) `isInstanceOf` typeOf (undefined :: ANY)
          @?= Right ()

      , testCase "CANNOT use a term of type 'forall a. a -> a' as 'forall a. a'" $
          typeOf (undefined :: ANY) `isInstanceOf` typeOf (undefined :: ANY -> ANY)
          @?= Left "Cannot unify Skolem and (->)"
      ]

  , testGroup "Examples of funResultTy"
      [ testCase "Apply fn of type (forall a. a -> a) to arg of type Bool gives Bool" $
          show (funResultTy (typeOf (undefined :: ANY -> ANY)) (typeOf (undefined :: Bool)))
          @?= "Right Bool"

      , testCase "Apply fn of type (forall a b. a -> b -> a) to arg of type Bool gives forall a. a -> Bool" $
          show (funResultTy (typeOf (undefined :: ANY -> ANY1 -> ANY)) (typeOf (undefined :: Bool)))
          @?= "Right (ANY -> Bool)" -- forall a. a -> Bool

      , testCase "Apply fn of type (forall a. (Bool -> a) -> a) to argument of type (forall a. a -> a) gives Bool" $
          show (funResultTy (typeOf (undefined :: (Bool -> ANY) -> ANY)) (typeOf (undefined :: ANY -> ANY)))
          @?= "Right Bool"

      , testCase "Apply fn of type (forall a b. a -> b -> a) to arg of type (forall a. a -> a) gives (forall a b. a -> b -> b)" $
        show (funResultTy (typeOf (undefined :: ANY -> ANY1 -> ANY)) (typeOf (undefined :: ANY1 -> ANY1)))
        @?= "Right (ANY -> ANY1 -> ANY1)"

      , testCase "Cannot apply function of type (forall a. (a -> a) -> a -> a) to arg of type (Int -> Bool)" $
          show (funResultTy (typeOf (undefined :: (ANY -> ANY) -> (ANY -> ANY))) (typeOf (undefined :: Int -> Bool)))
          @?= "Left \"Cannot unify Int and Bool\""
      ]

  , testGroup "Examples of fromDynamic"
      [ testCase "CANNOT use a term of type 'Int -> Bool' as 'Int -> Int'" $
          do f <- fromDynamic (toDynamic (even :: Int -> Bool))
             return $ (f :: Int -> Int) 0
          @?= Left "Cannot unify Int and Bool"

      , testCase "CAN use a term of type 'forall a. a -> Int' as 'Int -> Int'" $
          do f <- fromDynamic (toDynamic (const 1 :: ANY -> Int))
             return $ (f :: Int -> Int) 0
          @?= Right 1

      , testCase "CAN use a term of type 'forall a b. a -> b' as 'forall a. a -> a'" $
          do f <- fromDynamic (toDynamic (unsafeCoerce :: ANY1 -> ANY2))
             return $ (f :: Int -> Int) 0
          @?= Right 0

      , testCase "CANNOT use a term of type 'forall a. a -> a' as 'forall a b. a -> b'" $
          do f <- fromDynamic (toDynamic (id :: ANY -> ANY))
             return $ (f :: Int -> Bool) 0
          @?= Left "Cannot unify Bool and Int"

      , testCase "CAN use a term of type 'forall a. a' as 'forall a. a -> a'" $
          case do f <- fromDynamic (toDynamic (undefined :: ANY))
                  return $ (f :: Int -> Int) 0
               of
            Right _ -> return ()
            result  -> assertFailure $ "Expected 'Right _' but got '" ++ show result ++ "'"

      , testCase "CANNOT use a term of type 'forall a. a -> a' as 'forall a. a'" $
          do f <- fromDynamic (toDynamic (id :: ANY -> ANY)) ; return $ (f :: Int)
          @?= Left "Cannot unify Int and (->)"
      ]

  , testGroup "Examples of dynApply"
      [ testCase "Apply fn of type (forall a. a -> a) to arg of type Bool gives Bool" $
          do app <- toDynamic (id :: ANY -> ANY) `dynApply` toDynamic True
             f <- fromDynamic app
             return $ (f :: Bool)
          @?= Right True

      , testCase "Apply fn of type (forall a b. a -> b -> a) to arg of type Bool gives forall a. a -> Bool" $
          do app <- toDynamic (const :: ANY -> ANY1 -> ANY) `dynApply` toDynamic True
             f <- fromDynamic app
             return $ (f :: Int -> Bool) 0
          @?= Right True

      , testCase "Apply fn of type (forall a. (Bool -> a) -> a) to argument of type (forall a. a -> a) gives Bool" $
          do app <- toDynamic (($ True) :: (Bool -> ANY) -> ANY) `dynApply` toDynamic (id :: ANY -> ANY)
             f <- fromDynamic app
             return (f :: Bool)
          @?= Right True

      , testCase "Apply fn of type (forall a b. a -> b -> a) to arg of type (forall a. a -> a) gives (forall a b. a -> b -> b)" $
          do app <- toDynamic (const :: ANY -> ANY1 -> ANY) `dynApply` toDynamic (id :: ANY -> ANY)
             f <- fromDynamic app ; return $ (f :: Int -> Bool -> Bool) 0 True
          @?= Right True

      , testCase "Cannot apply function of type (forall a. (a -> a) -> a -> a) to arg of type (Int -> Bool)" $
          do app <- toDynamic ((\f -> f . f) :: (ANY -> ANY) -> ANY -> ANY) `dynApply` toDynamic (even :: Int -> Bool) ; f <- fromDynamic app ; return (f :: ())
          @?= Left "Cannot unify Int and Bool"
      ]
  ]
