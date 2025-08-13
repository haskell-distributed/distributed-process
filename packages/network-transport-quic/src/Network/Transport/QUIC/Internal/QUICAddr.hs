{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}

module Network.Transport.QUIC.Internal.QUICAddr (
    EndPointId (..),
    QUICAddr (..),
    encodeQUICAddr,
    decodeQUICAddr,
) where

import Data.Binary (Binary)
import Data.ByteString.Char8 qualified as BS8
import Data.ByteString.Char8 qualified as BSC (unpack)
import Data.Word (Word32)
import Network.Socket (HostName, ServiceName)
import Network.Transport (EndPointAddress (EndPointAddress))

{- | Represents the unique ID of an endpoint within a transport.

This is used by endpoints to identify remote endpoints, even though
the remote endpoints are all backed by the same QUIC address.
-}
newtype EndPointId = EndPointId Word32
    deriving newtype (Eq, Show, Ord, Read, Bounded, Enum, Real, Integral, Num, Binary)

-- A QUICAddr represents the unique address an `endpoint` has, which involves
-- pointing to the transport (HostName, ServiceName) and then specific
-- endpoint spawned by that transport (EndpointId)
data QUICAddr = QUICAddr
    { quicBindHost :: !HostName
    , quicBindPort :: !ServiceName
    , quicEndpointId :: !EndPointId
    }
    deriving (Eq, Ord, Show)

-- | Encode a 'QUICAddr' to 'EndPointAddress'
encodeQUICAddr :: QUICAddr -> EndPointAddress
encodeQUICAddr (QUICAddr host port ix) =
    EndPointAddress
        (BS8.pack $ host <> ":" <> port <> ":" <> show ix)

-- | Decode end point address
decodeQUICAddr ::
    EndPointAddress ->
    Either String QUICAddr
decodeQUICAddr (EndPointAddress bs) =
    case splitMaxFromEnd (== ':') 2 $ BSC.unpack bs of
        [host, port, endPointIdStr] ->
            case reads endPointIdStr of
                [(endPointId, "")] -> Right $ QUICAddr host port endPointId
                _ -> Left $ "Undecodeable 'EndPointAddress': " <> show bs
        _ ->
            Left $ "Undecodeable 'EndPointAddress': " <> show bs

{- | @spltiMaxFromEnd p n xs@ splits list @xs@ at elements matching @p@,
returning at most @p@ segments -- counting from the /end/

> splitMaxFromEnd (== ':') 2 "ab:cd:ef:gh" == ["ab:cd", "ef", "gh"]
-}
splitMaxFromEnd :: (a -> Bool) -> Int -> [a] -> [[a]]
splitMaxFromEnd p = \n -> go [[]] n . reverse
  where
    -- go :: [[a]] -> Int -> [a] -> [[a]]
    go accs _ [] = accs
    go ([] : accs) 0 xs = reverse xs : accs
    go (acc : accs) n (x : xs) =
        if p x
            then go ([] : acc : accs) (n - 1) xs
            else go ((x : acc) : accs) n xs
    go _ _ _ = error "Bug in splitMaxFromEnd"
