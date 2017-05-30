# network-transport-inmemory
[![travis](https://secure.travis-ci.org/haskell-distributed/network-transport-inmemory.svg)](http://travis-ci.org/haskell-distributed/network-transport-inmemory)
[![Release](https://img.shields.io/hackage/v/network-transport-inmemory.svg)](http://hackage.haskell.org/package/network-transport-inmemory)

network-transport-inmemory is a transport for local
communication in the same address space (i.e. a single operating system process). This is useful for testing purposes or for local communication that requires the network-transport semantics.

*NB*: network-transport-inmemory does not support cross-transport
communication. All endpoints that want to communicate should be created using
the same transport.


This repository is part of Cloud Haskell.

See http://haskell-distributed.github.com for documentation, user guides,
tutorials and assistance.

## Getting Help / Raising Issues

Please visit the [bug tracker](https://github.com/haskell-distributed/network-transport-inmemory/issues) to submit issues. You can contact the distributed-haskell@googlegroups.com mailing list for help and comments.

## License

This package is made available under a 3-clause BSD-style license.


