#!/bin/bash

if [ "$GHC" == "" ]; then
  GHC=ghc
fi
if [ "$CABAL" == "" ]; then
  CABAL=cabal
fi

$CABAL install --with-ghc=$GHC ./rank1dynamic ./distributed-static ./network-transport ./network-transport-tcp ./network-transport-inmemory ./distributed-process ./distributed-process-simplelocalnet --reinstall $*

