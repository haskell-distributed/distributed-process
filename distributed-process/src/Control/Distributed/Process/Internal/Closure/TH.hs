-- | Template Haskell support
--
-- (In a separate file for convenience)
{-# LANGUAGE MagicHash #-}
module Control.Distributed.Process.Internal.Closure.TH 
  ( -- * User-level API
    remotable
  , mkStatic
  , functionSDict
  ) where

import Prelude hiding (lookup)
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
  , Type(AppT, ForallT, VarT, ArrowT)
  , Info(VarI)
  , TyVarBndr(PlainTV, KindedTV)
  , Pred(ClassP)
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
  , Static(Static)
  , StaticLabel(StaticLabel)
  , remoteTableLabel
  , SerializableDict(SerializableDict)
  )
import Control.Distributed.Process.Internal.Dynamic 
  ( Dynamic(..)
  , unsafeCoerce#
  , toDyn
  )

--------------------------------------------------------------------------------
-- User-level API                                                             --
--------------------------------------------------------------------------------

-- | Create the closure, decoder, and metadata definitions for the given list
-- of functions
remotable :: [Name] -> Q [Dec] 
remotable ns = do
  (closures, inserts) <- unzip <$> mapM generateDefs ns
  rtable <- createMetaData (concat inserts)
  return $ concat closures ++ rtable 

-- | Construct a static value
mkStatic :: Name -> Q Exp
mkStatic = varE . staticName

-- | Serialization dictionary for a function argument (see module header)
functionSDict :: Name -> Q Exp
functionSDict = varE . sdictName

{-
-- | Create a closure
-- 
-- See module documentation header for "Control.Distributed.Process.Closure"
-- for a detailed explanation and examples.
mkClosure :: Name -> Q Exp
mkClosure = varE . closureName 
-}

--------------------------------------------------------------------------------
-- Internal (Template Haskell)                                                --
--------------------------------------------------------------------------------

-- | Generate the code to add the metadata to the CH runtime
createMetaData :: [Q Exp] -> Q [Dec]
createMetaData is = 
  [d| __remoteTable :: RemoteTable -> RemoteTable ;
      __remoteTable = $(compose is)
    |]

generateDefs :: Name -> Q ([Dec], [Q Exp])
generateDefs n = do
  mType <- getType n
  case mType of
    Just (origName, typ) -> do
      let (typVars, typ') = case typ of ForallT vars [] mono -> (vars, mono)
                                        _                    -> ([], typ)
      (static, register) <- do
        static <- generateStatic origName typVars typ' 
        let dyn = case typVars of 
                    [] -> [| toDyn $(varE origName) |]
                    _  -> [| Dynamic (error "Polymorphic value") 
                                     (unsafeCoerce# $(varE origName)) 
                           |]
        return ( static
               , [ [| registerStatic $(stringE (show origName)) $dyn |] ]
               )

      (sdict, registerSDict) <- case (typVars, typ') of
        ([], ArrowT `AppT` arg `AppT` _res) -> do
          -- TODO: we should check if arg is an instance of Serializable, but we cannot
          -- http://hackage.haskell.org/trac/ghc/ticket/7066
          sdict <- generateSDict origName arg
          let dyn' = [| toDyn (SerializableDict :: SerializableDict $(return arg)) |]
          return ( sdict
                 , [ [| registerStatic $(stringE (show (sdictName origName))) $dyn' |] ]
                 )
        _ ->
          return ([], [])
      
      return ( static ++ sdict
             , register ++ registerSDict
             )
    _ -> 
      fail $ "remotable: " ++ show n ++ " not found"

registerStatic :: String -> Dynamic -> RemoteTable -> RemoteTable
registerStatic label dyn = remoteTableLabel label ^= Just dyn 

-- | Generate a static value 
generateStatic :: Name -> [TyVarBndr] -> Type -> Q [Dec]
generateStatic n xs typ = do
    staticTyp <- [t| Static |]
    sequence
      [ sigD (staticName n) $ return (ForallT xs 
                                             (map typeable xs) 
                                             (staticTyp `AppT` typ)
                                     )
      , sfnD (staticName n) [| Static $ StaticLabel 
                                 $(stringE (show n)) 
                                 (typeOf (undefined :: $(return typ)))
                             |]
      ]
  where
    typeable :: TyVarBndr -> Pred
    typeable (PlainTV v)    = ClassP (mkName "Typeable") [VarT v] 
    typeable (KindedTV v _) = ClassP (mkName "Typeable") [VarT v]

-- | Generate a function serialization dictionary
generateSDict :: Name -> Type -> Q [Dec]
generateSDict n typ = do
    sequence
      [ sigD (sdictName n) $ [t| Static (SerializableDict $(return typ)) |]
      , sfnD (sdictName n) [| Static $ StaticLabel 
                                 $(stringE (show (sdictName n))) 
                                 (typeOf (undefined :: SerializableDict $(return typ)))
                             |]
      ]

staticName :: Name -> Name
staticName n = mkName $ nameBase n ++ "__static"

sdictName :: Name -> Name
sdictName n = mkName $ nameBase n ++ "__sdict"

{-
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
    Just (origName, ForallT vars [] tp) -> do
      (closure, label) <- generatePolyClosure origName vars tp
      return (closure, [| registerLabel $(stringE label) (Dynamic (error "Polymorphic closure") (unsafeCoerce# $(varE origName))) |])
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
    label = show n

-- | Generate a polymorphic closure
generatePolyClosure :: Name -> [TyVarBndr] -> Type -> Q ([Dec], String)
generatePolyClosure n xs typ = do
    closureTyp <- [t| Closure |]
    closure <- sequence
      [ sigD (closureName n) (return (ForallT xs (map typeable xs) (closureTyp `AppT` typ)) )
      , sfnD (closureName n) [| Closure (Static (PolyStatic ($(stringE label)))) (encode (typeOf (undefined :: $(return typ)))) |]
      ]
    return (closure, label)
  where
    label :: String
    label = show n

    typeable :: TyVarBndr -> Pred
    typeable (PlainTV v)    = ClassP (mkName "Typeable") [VarT v] 
    typeable (KindedTV v _) = ClassP (mkName "Typeable") [VarT v]

-- | Generate the decoder (see 'generateDefs')
generateDecoder :: Name -> Q Type -> Q Exp 
generateDecoder n res = [| $(varE n) . decode :: ByteString -> $res |]

-- | The name for the function that generates the closure
closureName :: Name -> Name
closureName n = mkName $ nameBase n ++ "__closure"

registerSerializableDict :: forall a. SerializableDict a -> RemoteTable -> RemoteTable
registerSerializableDict SerializableDict = 
  let rss = RuntimeSerializableSupport {
                rssSend   = toDyn (send :: ProcessId -> a -> Process ()) 
              , rssReturn = toDyn (return . decode :: ByteString -> Process a)  
              , rssExpect = toDyn (expect :: Process a)
              }
  in remoteTableDict (typeOf (undefined :: a)) ^= Just rss 
-}

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
