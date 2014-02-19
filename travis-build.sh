#!/usr/bin/env sh

rm -f build.mk || true
rm -f cloud-haskell || true
git clone git://github.com/haskell-distributed/cloud-haskell || true
git --git-dir=cloud-haskell/.git --work-tree=cloud-haskell checkout development
cp cloud-haskell/build.mk .
make -j BASE_DIR=`pwd` BRANCH=development install-deps
make -j BASE_DIR=`pwd` BRANCH=development test

