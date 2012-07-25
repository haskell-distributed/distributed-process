Haskell Distributed Project
===========================

This repository holds an implementation of [Cloud Haskell][1].

At present, this repository hosts 

* network-transport
* network-transport-tcp
* network-transport-inmemory (incomplete) 
* distributed-process
* distributed-process-simplelocalnet
* azure-service-api (skeleton only)

For more detailed information about the interfaces provided by these packages,
please refer to the [distributed-process repository wiki][2]. People who wish
to get started with Cloud Haskell should cabal install
distributed-process and possibly distributed-process-simplelocalnet and refer
to the corresponding Haddock documentation ([Control.Distributed.Process][3],
[Control.Distributed.Process.Closure][4],
[Control.Distributed.Process.Node][5], and
[Control.Distributed.Process.Backend.SimpleLocalnet][6]).

[1]: http://research.microsoft.com/en-us/um/people/simonpj/papers/parallel/remote.pdf
[2]: https://github.com/haskell-distributed/distributed-process/wiki
[3]: http://hackage.haskell.org/packages/archive/distributed-process/0.2.1.4/doc/html/Control-Distributed-Process.html
[4]: http://hackage.haskell.org/packages/archive/distributed-process/0.2.1.4/doc/html/Control-Distributed-Process-Closure.html
[5]: http://hackage.haskell.org/packages/archive/distributed-process/0.2.1.4/doc/html/Control-Distributed-Process-Node.html
[6]: http://hackage.haskell.org/packages/archive/distributed-process-simplelocalnet/0.2.0.3/doc/html/Control-Distributed-Process-Backend-SimpleLocalnet.html
