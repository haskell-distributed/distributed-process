#!/bin/bash

if [ "$GHC" == "" ]; then
  GHC=ghc
fi
if [ "$CABAL" == "" ]; then
  CABAL=cabal
fi

$CABAL install --with-ghc=$GHC ./network-transport ./network-transport-tcp ./network-transport-inmemory ./distributed-process ./distributed-process-simplelocalnet --reinstall $*

