{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE TemplateHaskell    #-}

--
-- -module(kitty_server).
-- -export([start_link/0, order_cat/4, return_cat/2, close_shop/1]).
module GenServer.Kitty
    (
        startKitty,
        terminateKitty,
        orderCat,
        orderCatAsync,
        returnCat,
        closeShop,
        Cat(..)
    ) where

import           Control.Distributed.Platform.GenServer

import           Data.Binary                            (Binary (..), getWord8,
                                                         putWord8)
import           Data.DeriveTH
import           Data.Typeable                          (Typeable)

--
-- % Records/Data Types
-- -record(cat, {name, color=green, description}).

type Color = String
type Description = String
type Name = String

data Cat = Cat {
    catName  :: Name,
    catColor :: Color,
    catDescr :: Description }
        deriving (Show, Typeable)
$( derive makeBinary ''Cat )

data CatCmd
    = OrderCat String String String
    | CloseShop
        deriving (Show, Typeable)
$( derive makeBinary ''CatCmd )

data ReturnCat
    = ReturnCat Cat
        deriving (Show, Typeable)
$( derive makeBinary ''ReturnCat )

data CatEv
    = CatOrdered Cat
    | ShopClosed
        deriving (Show, Typeable)
$( derive makeBinary ''CatEv )

--
-- %% Client API
-- start_link() -> spawn_link(fun init/0).
-- | Start a counter server
startKitty :: [Cat] -> Process ServerId
startKitty cats = start cats defaultServer {
    initHandler         = do
        --cs <- getState
        --trace $ "Kitty init: " ++ show cs
        initOk Infinity,
    terminateHandler    = const $ return (),
        --trace $ "Kitty terminate: " ++ show r,
    handlers            = [
        handle handleKitty,
        handle handleReturn
]}

-- | Stop the kitty server
terminateKitty :: ServerId -> Process ()
terminateKitty sid = terminate sid ()

-- %% Synchronous call
orderCat :: ServerId -> Name -> Color -> Description -> Process Cat
orderCat sid name color descr = do
    result <- call sid Infinity (OrderCat name color descr)
    case result of
        CatOrdered c -> return c
        _ -> error $ "Unexpected result " ++ show result

-- | Async call
orderCatAsync :: ServerId -> Name -> Color -> Description -> Process (Async Cat)
orderCatAsync sid name color descr = callAsync sid (OrderCat name color descr)

-- %% cast
returnCat :: ServerId -> Cat -> Process ()
returnCat sid cat = cast sid (ReturnCat cat)

-- %% sync call
closeShop :: ServerId -> Process ()
closeShop sid = do
    result <- call sid Infinity CloseShop
    case result of
        ShopClosed -> return ()
        _ -> error $ "Unexpected result " ++ show result

--
-- %%% Server functions

handleKitty :: Handler [Cat] CatCmd CatEv
handleKitty (OrderCat name color descr) = do
    cats <- getState
    case cats of
        [] -> do
            let cat = Cat name color descr
            putState (cat:cats)
            ok (CatOrdered cat)
        (x:xs) -> do -- TODO find cat with same features
            putState xs
            ok (CatOrdered x)

handleKitty CloseShop = do
    putState []
    ok ShopClosed

handleReturn :: Handler [Cat] ReturnCat ()
handleReturn (ReturnCat cat) = do
    modifyState (cat :)
    ok ()
