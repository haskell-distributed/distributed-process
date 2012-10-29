Haskell Distributed Project
===========================

This repository holds an implementation of [Cloud Haskell][1].

At present, this repository hosts 

* network-transport: Generic Network.Transport API
* network-transport-tests: Test suite for Network.Transport instantiations
* network-transport-tcp: TCP instantiation of Network.Transport
* network-transport-inmemory: In-memory instantiation of Network.Transport (incomplete) 
* network-transport-composed: Compose two transports (incomplete)
* distributed-static: Support for static values
* distributed-process: The main Cloud Haskell package
* distributed-process-simplelocalnet: Simple backend for local networks
* distributed-process-azure: Azure backend for Cloud Haskell (work in progress)
* azure-service-api: Haskell bindings for the Azure service API (work in progress)
* rank1dynamic: Like Data.Dynamic and Data.Typeable but with support for polymorphic values

For more detailed information about the interfaces provided by these packages,
please refer to the [distributed-process repository wiki][2]. People who wish
to get started with Cloud Haskell should cabal install
distributed-process and possibly distributed-process-simplelocalnet and refer
to the corresponding Haddock documentation ([Control.Distributed.Process][3],
[Control.Distributed.Process.Closure][4],
[Control.Distributed.Process.Node][5], and
[Control.Distributed.Process.Backend.SimpleLocalnet][6]).

[1]: http://www.haskell.org/haskellwiki/Cloud_Haskell
[2]: https://github.com/haskell-distributed/distributed-process/wiki
[3]: http://hackage.haskell.org/packages/archive/distributed-process/0.2.1.4/doc/html/Control-Distributed-Process.html
[4]: http://hackage.haskell.org/packages/archive/distributed-process/0.2.1.4/doc/html/Control-Distributed-Process-Closure.html
[5]: http://hackage.haskell.org/packages/archive/distributed-process/0.2.1.4/doc/html/Control-Distributed-Process-Node.html
[6]: http://hackage.haskell.org/packages/archive/distributed-process-simplelocalnet/0.2.0.3/doc/html/Control-Distributed-Process-Backend-SimpleLocalnet.html
