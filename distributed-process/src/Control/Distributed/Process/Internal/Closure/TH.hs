-- | Template Haskell support
--
-- (In a separate file for convenience)
module Control.Distributed.Process.Internal.Closure.TH 
  ( -- * User-level API
    remotable
  , mkStatic
  , functionSDict
  , functionTDict
  ) where

import Prelude hiding (lookup)
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

import Control.Distributed.Process.Internal.Types (Process)
import Control.Distributed.Process.Serializable 
  ( SerializableDict(SerializableDict)
  )
import Control.Distributed.Static 
  ( RemoteTable
  , registerStatic
  , Static
  , staticLabel
  )
import Data.Rank1Dynamic (toDynamic)

{-
import Control.Distributed.Process.Internal.Types
  ( RemoteTable
  , Static(Static)
  , StaticLabel(StaticLabel)
  , remoteTableLabel
  , SerializableDict(SerializableDict)
  , Process
  )
-}

{-
import Control.Distributed.Process.Internal.Dynamic 
  ( Dynamic(..)
  , unsafeCoerce#
  , toDyn
  )
-}

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

-- | Construct a static value.
--
-- If @f : forall a1 .. an. T@ 
-- then @$(mkStatic 'f) :: forall a1 .. an. Static T@. 
-- Be sure to pass 'f' to 'remotable'. 
mkStatic :: Name -> Q Exp
mkStatic = varE . staticName

-- | If @f : T1 -> T2@ is a monomorphic function 
-- then @$(functionSDict 'f) :: Static (SerializableDict T1)@.
-- 
-- Be sure to pass 'f' to 'remotable'.
functionSDict :: Name -> Q Exp
functionSDict = varE . sdictName

-- | If @f : T1 -> Process T2@ is a monomorphic function
-- then @$(functionTDict 'f) :: Static (SerializableDict T2)@.
--
-- Be sure to pass 'f' to 'remotable'.
functionTDict :: Name -> Q Exp
functionTDict = varE . tdictName

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
    proc <- [t| Process |]
    mType <- getType n
    case mType of
      Just (origName, typ) -> do
        let (typVars, typ') = case typ of ForallT vars [] mono -> (vars, mono)
                                          _                    -> ([], typ)

        -- The main "static" entry                                  
        (static, register) <- makeStatic origName typVars typ' 
         
        -- If n :: T1 -> T2, static serializable dictionary for T1 
        -- TODO: we should check if arg is an instance of Serializable, but we cannot
        -- http://hackage.haskell.org/trac/ghc/ticket/7066
        (sdict, registerSDict) <- case (typVars, typ') of
          ([], ArrowT `AppT` arg `AppT` _res) -> 
            makeDict (sdictName origName) arg
          _ -> 
            return ([], [])
        
        -- If n :: T1 -> Process T2, static serializable dictionary for T2
        -- TODO: check if T2 is serializable (same as above)
        (tdict, registerTDict) <- case (typVars, typ') of
          ([], ArrowT `AppT` _arg `AppT` (proc' `AppT` res)) | proc' == proc -> 
            makeDict (tdictName origName) res 
          _ ->
            return ([], [])
        
        return ( concat [static, sdict, tdict]
               , concat [register, registerSDict, registerTDict]
               )
      _ -> 
        fail $ "remotable: " ++ show n ++ " not found"
  where
    makeStatic :: Name -> [TyVarBndr] -> Type -> Q ([Dec], [Q Exp])
    makeStatic origName typVars typ = do 
      static <- generateStatic origName typVars typ
      let dyn = case typVars of 
                  [] -> [| toDynamic $(varE origName) |]
                  _  -> [| toDynamic $(varE origName) |]
      return ( static
             , [ [| registerStatic $(stringE (show origName)) $dyn |] ]
             )

    makeDict :: Name -> Type -> Q ([Dec], [Q Exp]) 
    makeDict dictName typ = do
      sdict <- generateDict dictName typ 
      let dyn = [| toDynamic (SerializableDict :: SerializableDict $(return typ)) |]
      return ( sdict
             , [ [| registerStatic $(stringE (show dictName)) $dyn |] ] 
             )
      
-- | Generate a static value 
generateStatic :: Name -> [TyVarBndr] -> Type -> Q [Dec]
generateStatic n xs typ = do
    staticTyp <- [t| Static |]
    sequence
      [ sigD (staticName n) $ 
          return (ForallT xs 
                  (map typeable xs) 
                  (staticTyp `AppT` typ)
          )
      , sfnD (staticName n) [| staticLabel $(stringE (show n)) |]
      ]
  where
    typeable :: TyVarBndr -> Pred
    typeable (PlainTV v)    = ClassP (mkName "Typeable") [VarT v] 
    typeable (KindedTV v _) = ClassP (mkName "Typeable") [VarT v]

-- | Generate a serialization dictionary with name 'n' for type 'typ' 
generateDict :: Name -> Type -> Q [Dec]
generateDict n typ = do
    sequence
      [ sigD n $ [t| Static (SerializableDict $(return typ)) |]
      , sfnD n [| staticLabel $(stringE (show n))  |]
      ]

staticName :: Name -> Name
staticName n = mkName $ nameBase n ++ "__static"

sdictName :: Name -> Name
sdictName n = mkName $ nameBase n ++ "__sdict"

tdictName :: Name -> Name
tdictName n = mkName $ nameBase n ++ "__tdict"

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
