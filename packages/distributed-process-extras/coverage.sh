#! /bin/sh

travis_retry curl -L https://github.com/rubik/stack-hpc-coveralls/releases/download/v0.0.4.0/shc-linux-x64-$GHCVER.tar.bz2 | tar -xj
shc -- --hpc-dir=$(stack $ARGS path --local-install-root)`/hpc/combined --dont-send combined all
