-- | /Towards Haskell in the Cloud/ (Epstein et al, Haskell Symposium 2011) 
-- introduces the concept of /static/ values: values that are known at compile
-- time. In a distributed setting where all nodes are running the same 
-- executable, static values can be serialized simply by transmitting a code
-- pointer to the value. This however requires special compiler support, which
-- is not yet available in ghc. We can mimick the behaviour by keeping an 
-- explicit mapping ('RemoteTable') from labels to values (and making sure that
-- all distributed nodes are using the same 'RemoteTable'). In this module
-- we implement this mimickry and various extensions.
--
-- [Dynamic type checking]
--
-- The paper stipulates that 'Static' values should have a free 'Binary'
-- instance:
--
-- > instance Binary (Static a) 
--
-- This however is not (runtime) type safe: for instance, what would be the
-- behaviour of
--
-- > f :: Static Int -> Static Bool 
-- > f = decode . encode 
--
-- For this reason we work only with 'Typeable' terms in this module, and
-- implement runtime checks
--
-- > instance Typeable a => Binary (Static a)
--
-- The above function 'f' typechecks but throws an exception if executed. The
-- type representation we use, however, is not the standard
-- 'Data.Typeable.TypeRep' from "Data.Typeable" but
-- 'Data.Rank1Typeable.TypeRep' from "Data.Rank1Typeable". This means that we
-- can represent polymorphic static values (see below for an example).
--
-- Since the runtime mapping ('RemoteTable') contains values of different types,
-- it maps labels ('String's) to 'Data.Rank1Dynamic.Dynamic' values. Again, we
-- use the implementation from "Data.Rank1Dynamic" so that we can store 
-- polymorphic dynamic values.
--
-- [Compositionality]
--
-- Static values as described in the paper are not compositional: there is no
-- way to combine two static values and get a static value out of it. This
-- makes sense when interpreting static strictly as /known at compile time/,
-- but it severely limits expressiveness. However, the main motivation for
-- 'static' is not that they are known at compile time but rather that 
-- /they provide a free/ 'Binary' /instance/.  We therefore provide two basic
-- constructors for 'Static' values:
--
-- > staticLabel :: String -> Static a
-- > staticApply :: Static (a -> b) -> Static a -> Static b
--
-- The first constructor refers to a label in a 'RemoteTable'. The second 
-- allows to apply a static function to a static argument, and makes 'Static'
-- compositional: once we have 'staticApply' we can implement numerous derived
-- combinators on 'Static' values (we define a few in this module; see
-- 'staticCompose', 'staticSplit', and 'staticConst'). 
--
-- [Closures]
--
-- Closures in functional programming arise when we partially apply a function.
-- A closure is a code pointer together with a runtime data structure that
-- represents the value of the free variables of the function. A 'Closure'
-- represents these closures explicitly so that they can be serialized:
--
-- > data Closure a = Closure (Static (ByteString -> a)) ByteString
--
-- See /Towards Haskell in the Cloud/ for the rationale behind representing
-- the function closure environment in serialized ('ByteString') form. Any
-- static value can trivially be turned into a 'Closure' ('staticClosure'). 
-- Moreover, since 'Static' is now compositional, we can also define derived
-- operators on 'Closure' values ('closureApplyStatic', 'closureApply',
-- 'closureCompose', 'closureSplit').
--
-- [Monomorphic example]
--
-- Suppose we are working in the context of some distributed environment, with
-- a monadic type 'Process' representing processes, 'NodeId' representing node
-- addresses and 'ProcessId' representing process addresses. Suppose further 
-- that we have a primitive 
-- 
-- > sendInt :: ProcessId -> Int -> Process ()
--
-- We might want to define
--
-- > sendIntClosure :: ProcessId -> Closure (Int -> Process ())
--
-- In order to do that, we need a static version of 'send', and a static
-- decoder for 'ProcessId':
--
-- > sendIntStatic :: Static (ProcessId -> Int -> Process ())
-- > sendIntStatic = staticLabel "$send"
--
-- > decodeProcessIdStatic :: Static (ByteString -> Int)
-- > decodeProcessIdStatic = staticLabel "$decodeProcessId"
--
-- where of course we have to make sure to use an appropriate 'RemoteTable':
--
-- > rtable :: RemoteTable
-- > rtable = registerStatic "$send" (toDynamic sendInt)
-- >        . registerStatic "$decodeProcessId" (toDynamic (decode :: ByteString -> Int))
-- >        $ initRemoteTable
--
-- We can now define 'sendIntClosure':
--
-- > sendIntClosure :: ProcessId -> Closure (Int -> Process ())
-- > sendIntClosure pid = Closure decoder (encode pid)
-- >   where
-- >     decoder :: Static (ByteString -> Int -> Process ()) 
-- >     decoder = sendIntStatic `staticCompose` decodeProcessIdStatic
--
-- [Polymorphic example]
--
-- Suppose we wanted to define a primitive
--
-- > sendIntResult :: ProcessId -> Closure (Process Int) -> Closure (Process ())
--
-- which turns a process that computes an integer into a process that computes
-- the integer and then sends it someplace else.
--
-- We can define 
-- 
-- > bindStatic :: (Typeable a, Typeable b) => Static (Process a -> (a -> Process b) -> Process b)
-- > bindStatic = staticLabel "$bind"
--
-- provided that we register this label:
--
-- > rtable :: RemoteTable
-- > rtable = ...
-- >        . registerStatic "$bind" ((>>=) :: Process ANY1 -> (ANY1 -> Process ANY2) -> Process ANY2)
-- >        $ initRemoteTable
--
-- (Note that we are using the special 'Data.Rank1Typeable.ANY1' and
-- 'Data.Rank1Typeable.ANY2' types from "Data.Rank1Typeable" to represent this
-- polymorphic value.) Once we have a static bind we can define 
--
-- > sendIntResult :: ProcessId -> Closure (Process Int) -> Closure (Process ())
-- > sendIntResult pid cl = bindStatic `closureApplyStatic` cl `closureApply` sendIntClosure pid
--
-- [Dealing with qualified types]
--
-- In the above we were careful to avoid qualified types. Suppose that we have
-- instead
--
-- > send :: Binary a => ProcessId -> a -> Process ()
--
-- If we now want to define 'sendClosure', analogous to 'sendIntClosure' above,
-- we somehow need to include the 'Binary' instance in the closure -- after
-- all, we can ship this closure someplace else, where it needs to accept an
-- 'a', /then encode it/, and send it off. In order to do this, we need to turn
-- the Binary instance into an explicit dictionary:
--
-- > data BinaryDict a where
-- >   BinaryDict :: Binary a => BinaryDict a
-- >
-- > sendDict :: BinaryDict a -> ProcessId -> a -> Process ()
-- > sendDict BinaryDict = send
--
-- Now 'sendDict' is a normal polymorphic value:
-- 
-- > sendDictStatic :: Static (BinaryDict a -> ProcessId -> a -> Process ())
-- > sendDictStatic = staticLabel "$sendDict"
-- >
-- > rtable :: RemoteTable
-- > rtable = ...
-- >        . registerStatic "$sendDict" (sendDict :: BinaryDict ANY -> ProcessId -> ANY -> Process ())
-- >        $ initRemoteTable
-- 
-- so that we can define
--
-- > sendClosure :: Static (BinaryDict a) -> Process a -> Closure (a -> Process ())
-- > sendClosure dict pid = Closure decoder (encode pid)
-- >   where
-- >     decoder :: Static (ByteString -> a -> Process ())
-- >     decoder = (sendDictStatic `staticApply` dict) `staticCompose` decodeProcessIdStatic 
--
-- [Word of Caution]
--
-- You should not /define/ functions on 'ANY' and co. For example, the following
-- definition of 'rtable' is incorrect:
-- 
-- > rtable :: RemoteTable
-- > rtable = registerStatic "$sdictSendPort" sdictSendPort
-- >        $ initRemoteTable
-- >   where
-- >     sdictSendPort :: SerializableDict ANY -> SerializableDict (SendPort ANY)
-- >     sdictSendPort SerializableDict = SerializableDict
--
-- This definition of 'sdictSendPort' ignores its argument completely, and 
-- constructs a 'SerializableDict' for the /monomorphic/ type @SendPort ANY@,
-- which isn't what you want. Instead, you should do
--
-- > rtable :: RemoteTable
-- > rtable = registerStatic "$sdictSendPort" (sdictSendPort :: SerializableDict ANY -> SerializableDict (SendPort ANY))
-- >        $ initRemoteTable
-- >   where
-- >     sdictSendPort :: forall a. SerializableDict a -> SerializableDict (SendPort a)
-- >     sdictSendPort SerializableDict = SerializableDict
module Control.Distributed.Static 
  ( -- * Static values 
    Static
  , staticLabel
  , staticApply
    -- * Derived static combinators
  , staticCompose
  , staticSplit
  , staticConst
    -- * Closures
  , Closure
  , closure
    -- * Derived closure combinators
  , staticClosure
  , closureApplyStatic
  , closureApply
  , closureCompose
  , closureSplit
    -- * Resolution 
  , RemoteTable
  , initRemoteTable
  , registerStatic
  , unstatic 
  , unclosure 
  ) where

import Data.Binary 
  ( Binary(get, put)
  , Put
  , Get
  , putWord8
  , getWord8
  , encode
  , decode
  )
import Data.ByteString.Lazy (ByteString, empty)
import Data.Map (Map)
import qualified Data.Map as Map (lookup, empty, insert)
import Control.Applicative ((<$>), (<*>))
import Control.Arrow as Arrow ((***), app)
import Data.Rank1Dynamic (Dynamic, toDynamic, fromDynamic, dynApply)
import Data.Rank1Typeable 
  ( Typeable
  , typeOf
  , ANY1
  , ANY2
  , ANY3
  , ANY4
  , isInstanceOf
  )

--------------------------------------------------------------------------------
-- Introducing static values                                                  --
--------------------------------------------------------------------------------

data StaticLabel =
    StaticLabel String
  | StaticApply StaticLabel StaticLabel
  deriving (Typeable, Show)

-- | A static value. Static is opaque; see 'staticLabel' and 'staticApply'.
newtype Static a = Static StaticLabel 
  deriving (Typeable, Show)

instance Typeable a => Binary (Static a) where
  put (Static label) = putStaticLabel label >> put (typeOf (undefined :: a))
  get = do
    label   <- getStaticLabel
    typeRep <- get
    case typeOf (undefined :: a) `isInstanceOf` typeRep of
      Left err -> fail $ "Static.get: type error: " ++ err
      Right () -> return (Static label)

-- We don't want StaticLabel to be its own Binary instance
putStaticLabel :: StaticLabel -> Put
putStaticLabel (StaticLabel string) = 
  putWord8 0 >> put string 
putStaticLabel (StaticApply label1 label2) = 
  putWord8 1 >> putStaticLabel label1 >> putStaticLabel label2

getStaticLabel :: Get StaticLabel
getStaticLabel = do
  header <- getWord8
  case header of
    0 -> StaticLabel <$> get
    1 -> StaticApply <$> getStaticLabel <*> getStaticLabel
    _ -> fail "StaticLabel.get: invalid" 
 
-- | Create a primitive static value.
-- 
-- It is the responsibility of the client code to make sure the corresponding
-- entry in the 'RemoteTable' has the appropriate type.
staticLabel :: String -> Static a
staticLabel = Static . StaticLabel 

-- | Apply two static values
staticApply :: Static (a -> b) -> Static a -> Static b
staticApply (Static f) (Static x) = Static (StaticApply f x)

--------------------------------------------------------------------------------
-- Eliminating static values                                                  --
--------------------------------------------------------------------------------

-- | Runtime dictionary for 'unstatic' lookups 
newtype RemoteTable = RemoteTable (Map String Dynamic)

-- | Initial remote table
initRemoteTable :: RemoteTable
initRemoteTable = 
      registerStatic "$compose"       (toDynamic ((.)    :: (ANY2 -> ANY3) -> (ANY1 -> ANY2) -> ANY1 -> ANY3))
    . registerStatic "$const"         (toDynamic (const  :: ANY1 -> ANY2 -> ANY1))
    . registerStatic "$split"         (toDynamic ((***)  :: (ANY1 -> ANY3) -> (ANY2 -> ANY4) -> (ANY1, ANY2) -> (ANY3, ANY4)))
    . registerStatic "$app"           (toDynamic (app    :: (ANY1 -> ANY2, ANY1) -> ANY2))
    . registerStatic "$decodeEnvPair" (toDynamic (decode :: ByteString -> (ByteString, ByteString)))
    $ RemoteTable Map.empty

-- | Register a static label
registerStatic :: String -> Dynamic -> RemoteTable -> RemoteTable
registerStatic label dyn (RemoteTable rtable)
  = RemoteTable (Map.insert label dyn rtable)

-- Pseudo-type: RemoteTable -> Static a -> a
resolveStaticLabel :: RemoteTable -> StaticLabel -> Either String Dynamic
resolveStaticLabel (RemoteTable rtable) (StaticLabel label) = 
  case Map.lookup label rtable of
    Nothing -> Left $ "Invalid static label '" ++ label ++ "'"
    Just d  -> Right d
resolveStaticLabel rtable (StaticApply label1 label2) = do
  f <- resolveStaticLabel rtable label1 
  x <- resolveStaticLabel rtable label2
  f `dynApply` x

-- | Resolve a static value
unstatic :: Typeable a => RemoteTable -> Static a -> Either String a
unstatic rtable (Static static) = do 
  dyn <- resolveStaticLabel rtable static 
  fromDynamic dyn

--------------------------------------------------------------------------------
-- Closures                                                                   -- 
--------------------------------------------------------------------------------

-- | A closure is a static value and an encoded environment
data Closure a = Closure (Static (ByteString -> a)) ByteString
  deriving (Typeable, Show)

instance Typeable a => Binary (Closure a) where
  put (Closure static env) = put static >> put env
  get = Closure <$> get <*> get 

closure :: Static (ByteString -> a) -- ^ Decoder
        -> ByteString               -- ^ Encoded closure environment
        -> Closure a
closure = Closure        

-- | Resolve a closure
unclosure :: Typeable a => RemoteTable -> Closure a -> Either String a
unclosure rtable (Closure static env) = do 
  f <- unstatic rtable static
  return (f env)

-- | Convert a static value into a closure.
staticClosure :: Typeable a => Static a -> Closure a
staticClosure static = closure (staticConst static) empty

--------------------------------------------------------------------------------
-- Predefined static values                                                   --
--------------------------------------------------------------------------------

-- | Static version of ('Prelude..')
composeStatic :: (Typeable a, Typeable b, Typeable c) 
              => Static ((b -> c) -> (a -> b) -> a -> c)
composeStatic = staticLabel "$compose" 

-- | Static version of 'const'
constStatic :: (Typeable a, Typeable b)
            => Static (a -> b -> a)
constStatic = staticLabel "$const"           

-- | Static version of ('Arrow.***')
splitStatic :: (Typeable a, Typeable a', Typeable b, Typeable b') 
            => Static ((a -> b) -> (a' -> b') -> (a, a') -> (b, b')) 
splitStatic = staticLabel "$split"

-- | Static version of 'Arrow.app'
appStatic :: (Typeable a, Typeable b)
          => Static ((a -> b, a) -> b)
appStatic = staticLabel "$app"

--------------------------------------------------------------------------------
-- Combinators on static values                                               --
--------------------------------------------------------------------------------

-- | Static version of ('Prelude..') 
staticCompose :: (Typeable a, Typeable b, Typeable c)
              => Static (b -> c) -> Static (a -> b) -> Static (a -> c)
staticCompose g f = composeStatic `staticApply` g `staticApply` f

-- | Static version of ('Control.Arrow.***')
staticSplit :: (Typeable a, Typeable a', Typeable b, Typeable b') 
            => Static (a -> b) -> Static (a' -> b') -> Static ((a, a') -> (b, b'))
staticSplit f g = splitStatic `staticApply` f `staticApply` g

-- | Static version of 'Prelude.const'
staticConst :: (Typeable a, Typeable b)
            => Static a -> Static (b -> a)
staticConst x = constStatic `staticApply` x 

--------------------------------------------------------------------------------
-- Combinators on Closures                                                    --
--------------------------------------------------------------------------------

-- | Apply a static function to a closure
closureApplyStatic :: (Typeable a, Typeable b)
                   => Static (a -> b) -> Closure a -> Closure b
closureApplyStatic f (Closure decoder env) = 
  closure (f `staticCompose` decoder) env

decodeEnvPairStatic :: Static (ByteString -> (ByteString, ByteString))
decodeEnvPairStatic = staticLabel "$decodeEnvPair"

-- | Closure application
closureApply :: forall a b. (Typeable a, Typeable b)
             => Closure (a -> b) -> Closure a -> Closure b
closureApply (Closure fdec fenv) (Closure xdec xenv) = 
    closure decoder (encode (fenv, xenv))
  where
    decoder :: Static (ByteString -> b)
    decoder = appStatic 
            `staticCompose`
              (fdec `staticSplit` xdec)
            `staticCompose`
              decodeEnvPairStatic 

-- | Closure composition
closureCompose :: (Typeable a, Typeable b, Typeable c)
               => Closure (b -> c) -> Closure (a -> b) -> Closure (a -> c)
closureCompose g f = composeStatic `closureApplyStatic` g `closureApply` f

-- | Closure version of ('Arrow.***')
closureSplit :: (Typeable a, Typeable a', Typeable b, Typeable b') 
             => Closure (a -> b) -> Closure (a' -> b') -> Closure ((a, a') -> (b, b'))
closureSplit f g = splitStatic `closureApplyStatic` f `closureApply` g 
