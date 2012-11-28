#! /bin/sh

HPC_DIR=dist/hpc

cabal clean
cabal configure --enable-tests --enable-library-coverage
cabal build
cabal test

open ${HPC_DIR}/html/*/hpc-index.html
