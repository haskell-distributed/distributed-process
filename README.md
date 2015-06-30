### network-transport-inmemory [![travis](https://secure.travis-ci.org/haskell-distributed/network-transport-inmemory.png?branch=master,development)](http://travis-ci.org/haskell-distributed/network-transport-inmemory)

network-transport-inmemory is a transport that could be used for local
communication in the same address space (i.e. one process).

It could be used either for testing purposes or for local communication that
requires the network-transport semantics.

*NB*: network-transport-inmemory does not support cross-transport
communication. All endpoints that want to communicate should be created using
the same transport.


This repository is part of Cloud Haskell.

See [official site](http://haskell-distributed.github.com) for documentation, user guides,
tutorials and assistance.

### License

network-transport-inmemory is made available under a BSD-3 license.
