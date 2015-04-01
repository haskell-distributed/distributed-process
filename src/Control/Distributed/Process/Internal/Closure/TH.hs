-- | Template Haskell support
{-# LANGUAGE TemplateHaskell, CPP #-}
module Control.Distributed.Process.Internal.Closure.TH
  ( -- * User-level API
    remotable
  , remotableDecl
  , mkStatic
  , functionSDict
  , functionTDict
  , mkClosure
  , mkStaticClosure
  ) where

import Prelude hiding (succ, any)
import Control.Applicative ((<$>))
import Language.Haskell.TH
  ( -- Q monad and operations
    Q
  , reify
  , Loc(loc_module)
  , location
    -- Names
  , Name
  , mkName
  , nameBase
    -- Algebraic data types
  , Dec(SigD)
  , Exp
  , Type(AppT, ForallT, VarT, ArrowT)
  , Info(VarI)
  , TyVarBndr(PlainTV, KindedTV)
#if ! MIN_VERSION_template_haskell(2,10,0)
  , Pred
#endif
  , varT
  , classP
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
import Data.Maybe (catMaybes)
import Data.Binary (encode)
import Data.Generics (everywhereM, mkM, gmapM)
import Data.Rank1Dynamic (toDynamic)
import Data.Rank1Typeable
  ( Zero
  , Succ
  , TypVar
  )
import Control.Distributed.Static
  ( RemoteTable
  , registerStatic
  , Static
  , staticLabel
  , closure
  , staticCompose
  , staticClosure
  )
import Control.Distributed.Process.Internal.Types (Process)
import Control.Distributed.Process.Serializable
  ( SerializableDict(SerializableDict)
  )
import Control.Distributed.Process.Internal.Closure.BuiltIn (staticDecode)

#if MIN_VERSION_template_haskell(2,10,0)
type Pred = Type
#endif

--------------------------------------------------------------------------------
-- User-level API                                                             --
--------------------------------------------------------------------------------

-- | Create the closure, decoder, and metadata definitions for the given list
-- of functions
remotable :: [Name] -> Q [Dec]
remotable ns = do
    types <- mapM getType ns
    (closures, inserts) <- unzip <$> mapM generateDefs types
    rtable <- createMetaData (mkName "__remoteTable") (concat inserts)
    return $ concat closures ++ rtable

-- | Like 'remotable', but parameterized by the declaration of a function
-- instead of the function name. So where for 'remotable' you'd do
--
-- > f :: T1 -> T2
-- > f = ...
-- >
-- > remotable ['f]
--
-- with 'remotableDecl' you would instead do
--
-- > remotableDecl [
-- >    [d| f :: T1 -> T2 ;
-- >        f = ...
-- >      |]
-- >  ]
--
-- 'remotableDecl' creates the function specified as well as the various
-- dictionaries and static versions that 'remotable' also creates.
-- 'remotableDecl' is sometimes necessary when you want to refer to, say,
-- @$(mkClosure 'f)@ within the definition of @f@ itself.
--
-- NOTE: 'remotableDecl' creates @__remoteTableDecl@ instead of @__remoteTable@
-- so that you can use both 'remotable' and 'remotableDecl' within the same
-- module.
remotableDecl :: [Q [Dec]] -> Q [Dec]
remotableDecl qDecs = do
    decs <- concat <$> sequence qDecs
    let types = catMaybes (map typeOf decs)
    (closures, inserts) <- unzip <$> mapM generateDefs types
    rtable <- createMetaData (mkName "__remoteTableDecl") (concat inserts)
    return $ decs ++ concat closures ++ rtable
  where
    typeOf :: Dec -> Maybe (Name, Type)
    typeOf (SigD name typ) = Just (name, typ)
    typeOf _               = Nothing

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

-- | If @f : T1 -> T2@ then @$(mkClosure 'f) :: T1 -> Closure T2@.
--
-- TODO: The current version of mkClosure is too polymorphic
-- (@forall a. Binary a => a -> Closure T2).
mkClosure :: Name -> Q Exp
mkClosure n =
  [|   closure ($(mkStatic n) `staticCompose` staticDecode $(functionSDict n))
     . encode
  |]

-- | Make a 'Closure' from a static function.  This is useful for
-- making a closure for a top-level @Process ()@ function, because
-- using 'mkClosure' would require adding a dummy @()@ argument.
--
mkStaticClosure :: Name -> Q Exp
mkStaticClosure n = [| staticClosure $( mkStatic n ) |]

--------------------------------------------------------------------------------
-- Internal (Template Haskell)                                                --
--------------------------------------------------------------------------------

-- | Generate the code to add the metadata to the CH runtime
createMetaData :: Name -> [Q Exp] -> Q [Dec]
createMetaData name is =
  sequence [ sigD name [t| RemoteTable -> RemoteTable |]
           , sfnD name (compose is)
           ]

generateDefs :: (Name, Type) -> Q ([Dec], [Q Exp])
generateDefs (origName, fullType) = do
    proc <- [t| Process |]
    let (typVars, typ') = case fullType of ForallT vars [] mono -> (vars, mono)
                                           _                    -> ([], fullType)

    -- The main "static" entry
    (static, register) <- makeStatic typVars typ'

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
  where
    makeStatic :: [TyVarBndr] -> Type -> Q ([Dec], [Q Exp])
    makeStatic typVars typ = do
      static <- generateStatic origName typVars typ
      let dyn = case typVars of
                  [] -> [| toDynamic $(varE origName) |]
                  _  -> [| toDynamic ($(varE origName) :: $(monomorphize typVars typ)) |]
      return ( static
             , [ [| registerStatic $(showFQN origName) $dyn |] ]
             )

    makeDict :: Name -> Type -> Q ([Dec], [Q Exp])
    makeDict dictName typ = do
      sdict <- generateDict dictName typ
      let dyn = [| toDynamic (SerializableDict :: SerializableDict $(return typ)) |]
      return ( sdict
             , [ [| registerStatic $(showFQN dictName) $dyn |] ]
             )

-- | Turn a polymorphic type into a monomorphic type using ANY and co
monomorphize :: [TyVarBndr] -> Type -> Q Type
monomorphize tvs =
    let subst = zip (map tyVarBndrName tvs) anys
    in everywhereM (mkM (applySubst subst))
  where
    anys :: [Q Type]
    anys = map typVar (iterate succ zero)

    typVar :: Q Type -> Q Type
    typVar t = [t| TypVar $t |]

    zero :: Q Type
    zero = [t| Zero |]

    succ :: Q Type -> Q Type
    succ t = [t| Succ $t |]

    applySubst :: [(Name, Q Type)] -> Type -> Q Type
    applySubst s (VarT n) =
      case lookup n s of
        Nothing -> return (VarT n)
        Just t  -> t
    applySubst s t = gmapM (mkM (applySubst s)) t

-- | Generate a static value
generateStatic :: Name -> [TyVarBndr] -> Type -> Q [Dec]
generateStatic n xs typ = do
    staticTyp <- [t| Static |]
    sequence
      [ sigD (staticName n) $ do
          txs <- sequence $ map typeable xs
          return (ForallT xs
                  txs
                  (staticTyp `AppT` typ))
      , sfnD (staticName n) [| staticLabel $(showFQN n) |]
      ]
  where
    typeable :: TyVarBndr -> Q Pred
    typeable tv = classP (mkName "Typeable") [varT (tyVarBndrName tv)]

-- | Generate a serialization dictionary with name 'n' for type 'typ'
generateDict :: Name -> Type -> Q [Dec]
generateDict n typ = do
    sequence
      [ sigD n $ [t| Static (SerializableDict $(return typ)) |]
      , sfnD n [| staticLabel $(showFQN n) |]
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
getType :: Name -> Q (Name, Type)
getType name = do
  info <- reify name
  case info of
    VarI origName typ _ _ -> return (origName, typ)
    _                     -> fail $ show name ++ " not found"

-- | Variation on 'funD' which takes a single expression to define the function
sfnD :: Name -> Q Exp -> Q Dec
sfnD n e = funD n [clause [] (normalB e) []]

-- | The name of a type variable binding occurrence
tyVarBndrName :: TyVarBndr -> Name
tyVarBndrName (PlainTV n)    = n
tyVarBndrName (KindedTV n _) = n

-- | Fully qualified name; that is, the name and the _current_ module
--
-- We ignore the module part of the Name argument (which may or may not exist)
-- because we construct various names (`staticName`, `sdictName`, `tdictName`)
-- and those names certainly won't have Module components.
showFQN :: Name -> Q Exp
showFQN n = do
  loc <- location
  stringE (loc_module loc ++ "." ++ nameBase n)
