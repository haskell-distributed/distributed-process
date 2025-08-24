module Network.Transport.QUIC.Internal.QUICAddr (
    QUICAddr (..),
    encodeQUICAddr,
    decodeQUICAddr,
) where

import Data.Attoparsec.Text (Parser, endOfInput, parseOnly, (<?>))
import Data.Attoparsec.Text qualified as A
import Data.ByteString.Char8 qualified as BS8
import Data.Text qualified as Text (unpack)
import Data.Text.Encoding (decodeUtf8Lenient)
import Net.IPv4 (IPv4)
import Net.IPv4 qualified as IPv4
import Net.IPv6 (IPv6)
import Net.IPv6 qualified as IPv6
import Network.Socket (HostName, ServiceName)
import Network.Transport (EndPointAddress (EndPointAddress))
import Network.Transport.QUIC.Internal.TransportState (EndpointId)

-- A QUICAddr represents the unique address an `endpoint` has, which involves
-- pointing to the transport (HostName, ServiceName) and then specific
-- endpoint spawned by that transport (EndpointId)
data QUICAddr = QUICAddr
    { quicBindHost :: !HostName
    , quicBindPort :: !ServiceName
    , quicEndpointId :: !EndpointId
    }
    deriving (Eq, Ord, Show)

-- | Encode a 'QUICAddr' to 'EndPointAddress'
encodeQUICAddr :: QUICAddr -> EndPointAddress
encodeQUICAddr (QUICAddr host port ix) =
    EndPointAddress
        (BS8.pack $ host <> ":" <> port <> ":" <> show ix)

-- | Decode a 'QUICAddr' from an 'EndPointAddress'
decodeQUICAddr :: EndPointAddress -> Either String QUICAddr
decodeQUICAddr (EndPointAddress bytes) =
    parseOnly (parser <* endOfInput) (decodeUtf8Lenient bytes)
  where
    parser =
        QUICAddr
            <$> (parseHostName <* A.char ':')
            <*> (parseServiceName <* A.char ':')
            <*> A.decimal

    parseHostName :: Parser HostName
    parseHostName =
        renderHostNameChoice
            <$> A.choice
                [ IPV6 <$> IPv6.parser <?> "IPv6"
                , IPV4 <$> IPv4.parser <?> "IPv4"
                , (Named . Text.unpack <$> A.takeTill (== ':')) <?> "Named host"
                ]
                <?> "Host name"

    parseServiceName :: Parser ServiceName
    parseServiceName = Text.unpack <$> A.takeTill (== ':') <?> "Service name"

data HostNameChoice
    = IPV4 IPv4
    | IPV6 IPv6
    | Named HostName

renderHostNameChoice :: HostNameChoice -> HostName
renderHostNameChoice (IPV4 ipv4) = IPv4.encodeString ipv4
renderHostNameChoice (IPV6 ipv6) = Text.unpack $ IPv6.encode ipv6
renderHostNameChoice (Named hostName) = hostName