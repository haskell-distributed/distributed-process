{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE TemplateHaskell    #-}

--
-- -module(kitty_server).
-- -export([start_link/0, order_cat/4, return_cat/2, close_shop/1]).
module Control.Distributed.Examples.Kitty
    (
        startKitty,
        orderCat,
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
startKitty cats = startServer cats defaultServer {
  msgHandlers = [
    handleCall handleKitty,
    handleCast handleReturn
]}


-- %% Synchronous call
orderCat :: ServerId -> Name -> Color -> Description -> Process Cat
orderCat sid name color descr = do
    result <- callServer sid NoTimeout (OrderCat name color descr)
    case result of
        CatOrdered c -> return c
        _ -> error $ "Unexpected result " ++ show result



-- %% async call
returnCat :: ServerId -> Cat -> Process ()
returnCat sid cat = castServer sid (ReturnCat cat)



-- %% sync call
closeShop :: ServerId -> Process ()
closeShop sid = do
    result <- callServer sid NoTimeout CloseShop
    case result of
        ShopClosed -> return ()
        _ -> error $ "Unexpected result " ++ show result



--
-- %%% Server functions


handleKitty (OrderCat name color descr) = do
    cats <- getState
    trace $ "Kitty inventory: " ++ show cats
    case cats of
        [] -> do
            let cat = Cat name color descr
            putState (cat:cats)
            callOk (CatOrdered cat)
        (x:xs) -> do -- TODO find cat with same features
            putState xs
            callOk (CatOrdered x)

handleKitty CloseShop = do
    putState []
    callOk ShopClosed



handleReturn (ReturnCat cat) = do
    modifyState (cat :)
    castOk
