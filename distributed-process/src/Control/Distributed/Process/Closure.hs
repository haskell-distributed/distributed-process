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
  ( unClosure
  , remotable 
  , mkClosure
  ) where

import Prelude hiding (lookup)
import Data.ByteString.Lazy (ByteString)
import Data.Binary (Binary(..), encode, decode)
import qualified Data.Map as Map (insert, (!))
import Data.Dynamic (toDyn, fromDyn)
import Data.Typeable (Typeable)
import Control.Applicative ((<$>), (<*>))
import Control.Monad.Reader (ask)
import Control.Exception (throw)
import Language.Haskell.TH ( -- Q monad and operations
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
import Control.Distributed.Process (Process)                           
import Control.Distributed.Process.Internal ( RemoteTable
                                            , LocalProcess(processNode)
                                            , LocalNode(remoteTable)
                                            )

-- | A static value is one that is bound at top-level.
-- We represent it simply by a string
newtype Static a = Static String
  deriving (Typeable)

-- | A closure is a static value and an encoded environment
data Closure a = Closure (Static (ByteString -> a)) ByteString
  deriving (Typeable)

--------------------------------------------------------------------------------
-- Top-level API                                                              --
--------------------------------------------------------------------------------

-- | Create the closure, decoder, and metadata definitions for the given list
-- of functions
remotable :: [Name] -> Q [Dec] 
remotable ns = do
  (closures, decoders, inserts) <- unzip3 <$> mapM process ns
  rtable <- createMetaData inserts 
  return $ concat closures ++ concat decoders ++ rtable 

-- | Deserialize a closure
unClosure :: Typeable a => Closure a -> Process a
unClosure (Closure (Static label) env) = do
  dec <- lookupStatic label 
  return (dec env)

-- | Create a closure
mkClosure :: Name -> Q Exp
mkClosure = varE . closureName 

--------------------------------------------------------------------------------
-- Internal (Cloud Haskell state)                                             --
--------------------------------------------------------------------------------

lookupStatic :: Typeable a => String -> Process a
lookupStatic label = do
    rtable <- remoteTable . processNode <$> ask
    return $ fromDyn (rtable Map.! label) (throw typeError)
  where
    typeError = userError "lookupStatic type error"

instance Binary (Closure a) where
  put (Closure (Static label) env) = put label >> put env
  get = Closure <$> (Static <$> get) <*> get 

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
--  2. f__dec :: ByteString -> b
--  3. Map.insert "M.f" (toDyn f__dec)
process :: Name -> Q ([Dec], [Dec], Q Exp)
process n = do
  mType <- getType n
  case mType of
    Just (origName, ArrowT `AppT` arg `AppT` res) -> do
      (closure, label) <- generateClosure origName (return arg) (return res)
      decoder <- generateDecoder origName (return res)
      let decoderE = varE (decoderName n)
          insert   = [| Map.insert $(stringE label) (toDyn $decoderE) |]
      return (closure, decoder, insert)
    _ -> 
      fail $ "remotable: " ++ show n ++ " is not a function"
   
-- | Generate the closure creator (see 'process')
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

-- | Generate the decoder (see 'process')
generateDecoder :: Name -> Q Type -> Q [Dec]
generateDecoder n res = do 
  sequence [ sigD (decoderName n) [t| ByteString -> $res |]
           , sfnD (decoderName n) [| $(varE n) . decode |]
           ]

-- | The name for the function that generates the closure
closureName :: Name -> Name
closureName n = mkName $ nameBase n ++ "__closure"

-- | The name for the decoder
decoderName :: Name -> Name
decoderName n = mkName $ nameBase n ++ "__dec"

--------------------------------------------------------------------------------
-- Generic Template Haskell auxiliary functions                               --
--------------------------------------------------------------------------------

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
