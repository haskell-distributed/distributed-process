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
    -- * Closure combinators
  , bindCP
  ) where 

import Prelude hiding (lookup)
import Data.ByteString.Lazy (ByteString)
import Data.Binary (encode, decode)
import Data.Typeable (typeOf)
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
-- Closure combinators                                                        --
--------------------------------------------------------------------------------

bindCP :: Closure (Process a) -> Closure (a -> Process b) -> Closure (Process b)
bindCP (Closure (Static x) envx) (Closure (Static f) (envf)) =
  Closure (Static "$bind") (encode ((x, envx), (f, envf)))

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
      , sfnD (closureName n) [| Closure (Static $(stringE label)) . encode |]  
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
