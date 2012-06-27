-- | Implementation of 'Closure' that works around the absence of 'static'.
--
-- [Example usage]
--
-- Suppose we have a monomorphic function
--
-- > addInt :: Int -> Int -> Int
-- > addInt x y = x + y
--
-- Then
--
-- > remotable ['addInt]
-- 
-- creates a function 
--
-- > $(mkClosure 'addInt) :: Int -> Closure (Int -> Int)
-- 
-- which can be used to partially apply 'addInt' and turn it into a 'Closure',
-- which can be sent across the network. Closures can be deserialized with 
--
-- > unClosure :: Typeable a => Closure a -> Process a
--
-- In general, given a monomorphic function @f : a -> b@ the corresponding 
-- function @$(mkClosure 'f)@ will have type @a -> Closure b@.
--
-- The call to 'remotable' will also generate a function
--
-- > __remoteTable :: RemoteTable -> RemoteTable
--
-- which can be used to construct the 'RemoteTable' used to initialize
-- Cloud Haskell. You should have (at most) one call to 'remotable' per module,
-- and compose all created functions when initializing Cloud Haskell:
--
-- > let rtable = M1.__remoteTable
-- >            . M2.__remoteTable
-- >            . ...
-- >            . Mn.__remoteTable
-- >            $ initRemoteTable 
--
-- See Section 6, /Faking It/, of /Towards Haskell in the Cloud/ for more info. 
{-# LANGUAGE TemplateHaskell #-}
module Control.Distributed.Process.Closure 
  ( -- * Primitive closures
    remotable
  , mkClosure
    -- * Generic closure combinators
  , closureApply
  , closureConst
  , closureUnit
    -- * Arrow combinators for processes
  , CP
  , cpIntro
  , cpElim
  , cpId
  , cpComp
  , cpFirst
  , cpSwap
  , cpSecond
  , cpPair
  , cpCopy
  , cpFanOut
  , cpLeft
  , cpMirror
  , cpRight
  , cpEither
  , cpUntag
  , cpFanIn
  , cpApply
    -- * Derived combinators for processes
  , cpBind
  , cpSeq
  ) where 

import Prelude hiding (lookup)
import Data.ByteString.Lazy (ByteString, empty)
import Data.Binary (encode, decode)
import Data.Typeable (typeOf, Typeable)
import Control.Applicative ((<$>))
import Language.Haskell.TH 
  ( -- Q monad and operations
    Q
  , reify
    -- Names
  , Name
  , mkName
  , nameBase
    -- Algebraic data types
  , Dec
  , Exp
  , Type(AppT, ArrowT)
  , Info(VarI)
    -- Lifted constructors
    -- .. Literals
  , stringL
    -- .. Patterns
  , normalB
  , clause
    -- .. Expressions
  , varE
  , litE
   -- .. Top-level declarations
  , funD
  , sigD
  )
import Control.Distributed.Process.Internal.Types
  ( RemoteTable
  , Closure(..)
  , Static(..)
  , StaticLabel(..)
  , Process
  , ProcessId
  , CallReply(..)
  , registerLabel
  , registerSender
  )
import Control.Distributed.Process (send)
import Control.Distributed.Process.Internal.Dynamic (toDyn)

--------------------------------------------------------------------------------
-- Top-level API                                                              --
--------------------------------------------------------------------------------

-- | Create the closure, decoder, and metadata definitions for the given list
-- of functions
remotable :: [Name] -> Q [Dec] 
remotable ns = do
  (closures, inserts) <- unzip <$> mapM generateDefs ns
  rtable <- createMetaData (concat inserts)
  return $ concat closures ++ rtable 

-- | Create a closure
mkClosure :: Name -> Q Exp
mkClosure = varE . closureName 

--------------------------------------------------------------------------------
-- Generic closure combinators                                                -- 
--------------------------------------------------------------------------------

closureApply :: Closure (a -> b) -> Closure a -> Closure b
closureApply (Closure (Static labelf) envf) (Closure (Static labelx) envx) = 
  Closure (Static ClosureApply) $ encode (labelf, envf, labelx, envx)

closureConst :: forall a b. (Typeable a, Typeable b) 
          => Closure (a -> b -> a)
closureConst = Closure (Static ClosureConst) (encode $ typeOf aux)
  where
    aux :: a -> b -> a
    aux = undefined

closureUnit :: Closure ()
closureUnit = Closure (Static ClosureUnit) empty

--------------------------------------------------------------------------------
-- Arrow combinators for processes                                            -- 
--------------------------------------------------------------------------------

type CP a b = Closure (a -> Process b)

cpIntro :: (Typeable a, Typeable b)
        => Closure (Process b) -> CP a b 
cpIntro = closureApply closureConst 

cpElim :: Typeable a 
       => CP () a -> Closure (Process a)
cpElim = flip closureApply closureUnit 

cpId :: forall a. Typeable a 
     => CP a a 
cpId = Closure (Static CpId) (encode $ typeOf aux)
  where
    aux :: a -> Process a
    aux = undefined

cpComp :: forall a b c. (Typeable a, Typeable b, Typeable c) 
       => CP a b -> CP b c -> CP a c
cpComp f g = comp `closureApply` f `closureApply` g 
  where
    comp :: Closure ((a -> Process b) -> (b -> Process c) -> (a -> Process c))
    comp = Closure (Static CpComp) (encode $ typeOf aux)
    
    aux :: (a -> Process b) -> (b -> Process c) -> (a -> Process c)
    aux = undefined

cpFirst :: forall a b c. (Typeable a, Typeable b, Typeable c)
        => CP a b -> CP (a, c) (b, c)
cpFirst = closureApply first
  where
    first :: Closure ((a -> Process b) -> (a, c) -> Process (b, c))
    first = Closure (Static CpFirst) (encode $ typeOf aux)

    aux :: (a -> Process b) -> (a, c) -> Process (b, c)
    aux = undefined

cpSwap :: forall a b. (Typeable a, Typeable b)
       => CP (a, b) (b, a)
cpSwap = Closure (Static CpSwap) (encode $ typeOf aux)
  where
    aux :: (a, b) -> Process (b, a)
    aux = undefined

cpSecond :: (Typeable a, Typeable b, Typeable c)
         => CP a b -> CP (c, a) (c, b)
cpSecond f = cpSwap `cpComp` cpFirst f `cpComp` cpSwap

cpPair :: (Typeable a, Typeable a', Typeable b, Typeable b')
        => CP a b -> CP a' b' -> CP (a, a') (b, b')
cpPair f g = cpFirst f `cpComp` cpSecond g

cpCopy :: forall a. Typeable a 
       => CP a (a, a)
cpCopy = Closure (Static CpCopy) (encode $ typeOf aux)
  where
    aux :: a -> Process (a, a)
    aux = undefined

cpFanOut :: (Typeable a, Typeable b, Typeable c)
         => CP a b -> CP a c -> CP a (b, c)
cpFanOut f g = cpCopy `cpComp` (f `cpPair` g)         

cpLeft :: forall a b c. (Typeable a, Typeable b, Typeable c)
       => CP a b -> CP (Either a c) (Either b c)
cpLeft = closureApply left
  where
    left :: Closure ((a -> Process b) -> Either a c -> Process (Either b c)) 
    left = Closure (Static CpLeft) (encode $ typeOf aux)

    aux :: (a -> Process b) -> Either a c -> Process (Either b c)
    aux = undefined

cpMirror :: forall a b. (Typeable a, Typeable b)
         => CP (Either a b) (Either b a)
cpMirror = Closure (Static CpMirror) (encode $ typeOf aux)
  where
    aux :: Either a b -> Process (Either b a)
    aux = undefined

cpRight :: forall a b c. (Typeable a, Typeable b, Typeable c)
        => CP a b -> CP (Either c a) (Either c b)
cpRight f = cpMirror `cpComp` cpLeft f `cpComp` cpMirror 

cpEither :: (Typeable a, Typeable a', Typeable b, Typeable b')
         => CP a b -> CP a' b' -> CP (Either a a') (Either b b')
cpEither f g = cpLeft f `cpComp` cpRight g

cpUntag :: forall a. Typeable a
        => CP (Either a a) a
cpUntag = Closure (Static CpUntag) (encode $ typeOf aux)
  where
    aux :: Either a a -> Process a
    aux = undefined

cpFanIn :: (Typeable a, Typeable b, Typeable c) 
        => CP a c -> CP b c -> CP (Either a b) c
cpFanIn f g = (f `cpEither` g) `cpComp` cpUntag 

cpApply :: forall a b. (Typeable a, Typeable b)
        => CP (CP a b, a) b
cpApply = Closure (Static CpApply) $ encode ( typeOf aux
                                            , typeOf (undefined :: a) 
                                            , typeOf (undefined :: Process b)
                                            )
  where
    aux :: (Closure (a -> Process b), a) -> Process b
    aux = undefined

--------------------------------------------------------------------------------
-- Some derived operators for processes                                       -- 
--------------------------------------------------------------------------------

cpBind :: (Typeable a, Typeable b) 
       => Closure (Process a) -> Closure (a -> Process b) -> Closure (Process b)
cpBind x f = cpElim $ cpIntro x `cpComp` f

cpSeq :: Closure (Process ()) -> Closure (Process ()) -> Closure (Process ())
cpSeq p q = p `cpBind` cpIntro q

--------------------------------------------------------------------------------
-- Internal (Template Haskell)                                                --
--------------------------------------------------------------------------------

-- | Generate the code to add the metadata to the CH runtime
createMetaData :: [Q Exp] -> Q [Dec]
createMetaData is = 
  [d| __remoteTable :: RemoteTable -> RemoteTable ;
      __remoteTable = $(compose is)
    |]

-- | Generate the necessary definitions for one function 
--
-- Given an (f :: a -> b) in module M, create: 
--  1. f__closure :: a -> Closure b,
--  2. registerLabel "M.f" (toDyn ((f . enc) :: ByteString -> b))
-- 
-- Moreover, if b is of the form Process c, then additionally create
--  3. registerSender (Process c) (send :: ProcessId -> c -> Process ())
generateDefs :: Name -> Q ([Dec], [Q Exp])
generateDefs n = do
  mType <- getType n
  case mType of
    Just (origName, ArrowT `AppT` arg `AppT` res) -> do
      (closure, label) <- generateClosure origName (return arg) (return res)
      let decoder = generateDecoder origName (return res)
          insert  = [| registerLabel $(stringE label) (toDyn $decoder) |]

      -- Generate special closure to support 'call'
      mResult <- processResult res
      insert' <- case mResult of
        Nothing -> 
          return [] 
        Just result -> do 
          let sender = generateSender result 
          return . return $ 
            [| registerSender $(typeToTypeRep res) (toDyn $sender) |]

      return (closure, insert : insert')
    _ -> 
      fail $ "remotable: " ++ show n ++ " is not a function"
   
-- | Generate the closure creator (see 'generateDefs')
generateClosure :: Name -> Q Type -> Q Type -> Q ([Dec], String)
generateClosure n arg res = do
    closure <- sequence 
      [ sigD (closureName n) [t| $arg -> Closure $res |]
      , sfnD (closureName n) [| Closure (Static (UserStatic ($(stringE label)))) . encode |]  
      ]
    return (closure, label)
  where
    label :: String 
    label = show $ n

-- | If 't' is of the form 'Process b', return 'Just b'
processResult :: Type -> Q (Maybe (Q Type))
processResult t = do
  process <- [t| Process |]
  case t of
    p `AppT` a | p == process -> return . Just . return $ a
    _                         -> return Nothing

-- | Generate the decoder (see 'generateDefs')
generateDecoder :: Name -> Q Type -> Q Exp 
generateDecoder n res = [| $(varE n) . decode :: ByteString -> $res |]

-- | Generate the sender. This is necessary to support 'call'
generateSender :: Q Type -> Q Exp
generateSender tp = 
  [| (\pid -> send pid . CallReply) :: ProcessId -> $tp -> Process () |]

-- | The name for the function that generates the closure
closureName :: Name -> Name
closureName n = mkName $ nameBase n ++ "__closure"

--------------------------------------------------------------------------------
-- Generic Template Haskell auxiliary functions                               --
--------------------------------------------------------------------------------

typeToTypeRep :: Type -> Q Exp
typeToTypeRep tp = [| typeOf (undefined :: $(return tp)) |]

-- | Compose a set of expressions
compose :: [Q Exp] -> Q Exp
compose []     = [| id |]
compose [e]    = e 
compose (e:es) = [| $e . $(compose es) |]

-- | Literal string as an expression
stringE :: String -> Q Exp
stringE = litE . stringL

-- | Look up the "original name" (module:name) and type of a top-level function
getType :: Name -> Q (Maybe (Name, Type))
getType name = do 
  info <- reify name
  case info of 
    VarI origName typ _ _ -> return $ Just (origName, typ)
    _                     -> return Nothing

-- | Variation on 'funD' which takes a single expression to define the function
sfnD :: Name -> Q Exp -> Q Dec
sfnD n e = funD n [clause [] (normalB e) []] 
