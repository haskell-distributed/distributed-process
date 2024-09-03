#!/bin/sh
cabal clean
cabal configure --enable-library-profiling --enable-executable-profiling
