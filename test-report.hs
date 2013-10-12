#! /bin/sh

HPC_DIR=dist/hpc

cabal-dev clean
cabal-dev configure --enable-tests --enable-library-coverage
cabal-dev build
cabal-dev test

open ${HPC_DIR}/html/*/hpc-index.html
