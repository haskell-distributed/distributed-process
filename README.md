### network-transport-inmemory [![travis](https://secure.travis-ci.org/haskell-distributed/network-transport-inmemory.png?branch=master,development)](http://travis-ci.org/haskell-distributed/network-transport-inmemory)

Network transport inmemory is a transport that could be used for local
communication in the same address space (i.e. one process). N-t-inmemory
is based on `STM` primitives. Such transport could be used either for
debug test purposes, or for local communication that require full
network-transport semantics.

*NB*: network-tranpsport-inmemory does not support cross transport
communication, all endpoints that want to comminicate should be
created using same transport.


This repository is part of Cloud Haskell.

See [official site](http://haskell-distributed.github.com) for documentation, user guides,
tutorials and assistance.

### License

network-transport-inmemory is made available under a BSD-3 license.
