{-|
Attemp to tranlsate a basic, naive (non-OTP based) server from Erland to Cloud Haskell

This is a naive Erlang server implementation in CloudHaskell whose main purpose is to ground
the evolution of the API into a proper form that is typed and leverages Haskell strenghts.

This sample was taken from here:

See: http://learnyousomeerlang.com/what-is-otp#the-basic-server
-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE TemplateHaskell #-}

--
-- -module(kitty_server).
-- -export([start_link/0, order_cat/4, return_cat/2, close_shop/1]).
module Control.Distributed.Naive.Kitty
    (
        startKitty,
        orderCat,
        returnCat,
        closeShop,
        Cat(..)
    ) where
import           Prelude hiding (catch)
import           Control.Exception(SomeException)
import           Data.Binary                         (Binary (..), putWord8, getWord8)
import           Data.DeriveTH
import           Data.Typeable                       (Typeable)
import           Control.Monad                       (liftM3, void)
import           Control.Distributed.Process         (Process, getSelfPid, ProcessId, liftIO, spawnLocal, catch, say, send, expect)

--
-- % Records/Data Types
-- -record(cat, {name, color=green, description}).
type Color = String
type Description = String
type Name = String

newtype Id a = Id ProcessId deriving Show

data Cat = Cat {
    catName :: Name,
    catColor :: Color,
    catDescr :: Description }
        deriving (Show, Typeable)

$( derive makeBinary ''Cat )

newtype CatId = CatId ProcessId deriving Show

data CatCmd
    = OrderCat String String String
    | ReturnCat Cat
    | CloseShop
        deriving (Show, Typeable)

$( derive makeBinary ''CatCmd )

data CatEv
    = CatOrdered Cat
    | ShopClosed
        deriving (Show, Typeable)

$( derive makeBinary ''CatEv )


--
-- %% Client API
-- start_link() -> spawn_link(fun init/0).
startKitty :: [Cat] -> Process ProcessId
startKitty cats = spawnLocal $ initCat cats `catch` \e -> do
        say $ show (e :: SomeException)
        initCat cats -- restart ... likely a bad idea!

-- %% Synchronous call
orderCat :: ProcessId -> Name -> Color -> Description -> Process Cat
orderCat pid name color descr = do
    say "-- Ordering cat ..."
    from <- getSelfPid
    send pid (from, OrderCat name color descr)
    r@(CatOrdered cat) <- expect
    say $ "-- Got REPLY: " ++ show r
    return cat

-- %% async call
returnCat :: ProcessId -> Cat -> Process ()
returnCat pid cat = do
        say $ "-- ReturnCat: " ++ show cat
        send pid ((), ReturnCat cat)

-- %% sync call
closeShop :: ProcessId -> Process ()
closeShop pid = do
    say "-- Closing shop ..."
    from <- getSelfPid
    send pid (from, CloseShop)
    reply <- expect :: Process CatEv
    say $ "-- Got REPLY: " ++ show reply
    return ()

--
-- %%% Server functions
initCat :: [Cat] -> Process ()
initCat args = do
    say "Starting Kitty ..."
    loopCat args

loopCat :: [Cat] -> Process ()
loopCat cats = do
    say $ "Kitty inventory: " ++ show cats
    (from, cmd) <- expect
    say $ "Got CMD from " ++ show from ++ " : " ++ show cmd
    case cmd of
        cmd@(OrderCat n c d) -> case cats of
                                    [] -> do
                                        send from $ CatOrdered (Cat n c d)
                                        loopCat []
                                    x:xs ->  do
                                        send from $ CatOrdered x
                                        loopCat xs
        cmd@(ReturnCat cat) -> loopCat (cat:cats)
        cmd@CloseShop -> do
            send from ShopClosed
            terminateKitty cats
        _ -> do
            say $ "Unknown CMD: " ++ show cmd
            loopCat cats

-- %%% Private functions
terminateKitty :: [Cat] -> Process ()
terminateKitty cats = do
    mapM_ (\c -> say $ show c ++ " set free!") cats
    return ()
