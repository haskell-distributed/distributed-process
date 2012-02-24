#!/bin/bash

set -e

if [ "$GHC" == "" ]; then 
  GHC=ghc
fi 

cd network-transport/
cabal.par install --with-ghc=$GHC

echo;echo
cd ../network-transport-pipes/
cabal.par install --with-ghc=$GHC

echo;echo
cd ../distributed-process/
cabal.par install --with-ghc=$GHC
