module Main (main) where

import Test.Network.Transport.QUIC qualified (tests)
import Test.Network.Transport.QUIC.Internal.QUICAddr qualified (tests)
import Test.Network.Transport.QUIC.Internal.Messaging qualified (tests)
import Test.Tasty (defaultMain, testGroup)

main :: IO ()
main =
    defaultMain $
        testGroup
            "network-transport-quic"
            [ Test.Network.Transport.QUIC.Internal.Messaging.tests
            , Test.Network.Transport.QUIC.Internal.QUICAddr.tests
            , Test.Network.Transport.QUIC.tests
            ]
