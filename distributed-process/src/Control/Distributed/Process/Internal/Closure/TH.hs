-- | Template Haskell support
--
-- (In a separate file for convenience)
module Control.Distributed.Process.Internal.Closure.TH 
  ( -- * User-level API
    remotable
  , mkClosure
  ) where

import Prelude hiding (lookup)
import Data.ByteString.Lazy (ByteString)
import Data.Binary (encode, decode)
import Data.Accessor ((^=))
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
  , StaticLabel(..)
  , Process
  , ProcessId
  , remoteTableLabel
  , remoteTableDict
  , SerializableDict(..)
  , RuntimeSerializableSupport(..)
  )
import Control.Distributed.Process.Internal.Dynamic (Dynamic, toDyn)
import Control.Distributed.Process.Internal.Process.Primitives (send)

--------------------------------------------------------------------------------
-- User-level API                                                             --
--------------------------------------------------------------------------------

-- | Create the closure, decoder, and metadata definitions for the given list
-- of functions
remotable :: [Name] -> Q [Dec] 
remotable ns = do
  (closures, inserts) <- unzip <$> mapM generateDefs ns
  rtable <- createMetaData inserts 
  return $ concat closures ++ rtable 

-- | Create a closure
-- 
-- If @f :: a -> b@ then @mkClosure :: a -> Closure b@. Make sure to pass 'f'
-- as an argument to 'remotable' too.
mkClosure :: Name -> Q Exp
mkClosure = varE . closureName 

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
generateDefs :: Name -> Q ([Dec], Q Exp)
generateDefs n = do
  serializableDict <- [t| SerializableDict |]
  mType <- getType n
  case mType of
    Just (origName, ArrowT `AppT` arg `AppT` res) -> do
      (closure, label) <- generateClosure origName (return arg) (return res)
      let decoder = generateDecoder origName (return res)
          insert  = [| registerLabel $(stringE label) (toDyn $decoder) |]
      return (closure, insert)
    Just (origName, sdict `AppT` a) | sdict == serializableDict -> 
      return ([], [| registerSerializableDict $(varE n) |])  
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

-- | Generate the decoder (see 'generateDefs')
generateDecoder :: Name -> Q Type -> Q Exp 
generateDecoder n res = [| $(varE n) . decode :: ByteString -> $res |]

-- | The name for the function that generates the closure
closureName :: Name -> Name
closureName n = mkName $ nameBase n ++ "__closure"

registerLabel :: String -> Dynamic -> RemoteTable -> RemoteTable
registerLabel label dyn = remoteTableLabel label ^= Just dyn 

registerSerializableDict :: forall a. SerializableDict a -> RemoteTable -> RemoteTable
registerSerializableDict SerializableDict = 
  let rss = RuntimeSerializableSupport {
                rssSend   = toDyn (send :: ProcessId -> a -> Process ()) 
              , rssReturn = toDyn (return . decode :: ByteString -> Process a)  
              }
  in remoteTableDict (typeOf (undefined :: a)) ^= Just rss 

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

