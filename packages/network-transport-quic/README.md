# `network-transport-quic`

This package provides an implementation of the `network-transport` interface, where networking is done via the QUIC protocol. The primary use-case for this package is as a Cloud Haskell backend.

QUIC has many advantages over TCP, including:

* No head-of-line blocking. Independent streams mean packet loss on one stream doesn't stall others;
* Connection migration. Connections survive IP address changes, which is important when a device switches from e.g. WIFI to 5G;
* Built-in encryption via TLS 1.3;

In benchmarks, `network-transport-quic` performs better than `network-transport-tcp` in dense network topologies. For example, if every `EndPoint` in your network connects to every other `EndPoint`, you might benefit greatly from switching to `network-transport-quic`! 

## Usage example

Provided you have a TLS 1.3 certificate, you can create a `Transport` like so:

```haskell
import Data.List.NonEmpty qualified as NonEmpty
import Network.Transport.QUIC (QUICTransportConfig(..), createTransport, credentialLoadX509)

main = do
    let certificate = "path/to/cert.crt"
        key = "path/to/cert.key"

    creds <- credentialLoadX509 certificate key
    case creds of
        Left error_message -> error error_message
        Right credential -> do
            let config = QUICTransportConfig
                            { hostName = "my.hostname.com" -- or some IP address
                            , serviceName = "https" -- alternatively, some port number
                            , credentials = NonEmpty.singleton credential
                            , validateCredentials = True -- should be 'False' for self-signed certificate
                            }
            transport <- createTransport config
            ...
```

There are tools online to help create self-signed TLS 1.3 certificates.
