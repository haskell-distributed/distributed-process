module Test.Network.Transport.QUIC.Internal.QUICAddr (tests) where

import Control.Monad (replicateM)
import Data.List (intercalate)
import Hedgehog (Gen, forAll, property, tripping)
import Hedgehog.Gen qualified as Gen
import Hedgehog.Range qualified as Range
import Network.Socket (HostName, ServiceName)
import Network.Transport.QUIC.Internal (QUICAddr (QUICAddr), decodeQUICAddr, encodeQUICAddr)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.Hedgehog (testProperty)

tests :: TestTree
tests =
  testGroup
    "QUICAddr"
    [testQUICAddrToEndpointAddress]

testQUICAddrToEndpointAddress :: TestTree
testQUICAddrToEndpointAddress = testProperty "De/serialization of 'QUICAddr'" $ property $ do
  addr <- forAll $ QUICAddr <$> genHostName <*> genServiceName <*> Gen.integral (Range.linear 1 10)

  tripping addr encodeQUICAddr decodeQUICAddr

genHostName :: Gen HostName
genHostName = Gen.choice [genIPV4, genIPV6, genNamed]
  where
    genIPV4 :: Gen HostName
    genIPV4 =
      let fragment = Gen.word8 Range.constantBounded
       in intercalate "." <$> replicateM 4 (show <$> fragment)

    genIPV6 :: Gen HostName
    genIPV6 =
      let fragment = Gen.word16 Range.constantBounded
       in intercalate ":" <$> replicateM 6 (show <$> fragment)

    genNamed :: Gen HostName
    genNamed =
      (\domain extension -> domain <> "." <> extension)
        <$> (Gen.element ["google", "amazon", "aol"])
        <*> (Gen.element ["ca", "com", "fr", "co.uk/some-route"])

genServiceName :: Gen ServiceName
genServiceName = show <$> Gen.word16 Range.constantBounded -- port number from 0 to 2^16
