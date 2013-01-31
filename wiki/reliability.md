---
layout: wiki
title: Fault Tolerance
wiki: reliability
---

### reliability

We do not consider the presence of side effects a barrier to fault tolerance
and automated process restarts. We **do** recognise that it's easier to
reason about restarting remote processes if they're stateless, and so we
provide a wrapper for the `ManagedProcess` API that ensures all user defined
callbacks are side effect free.

The choice, about whether or not it is safe to restart a process that *might*
produce side effects, is left to the user. The `ManagedProcess` API provides
explicit support for evaluating user defined callbacks when a process has
decided (for some reason) to shut down. We also give the user options about
how to initialise and/or re-initialise a process that has been previously
terminated.

When it comes to failure recovery, we defer to Erlang's approach for handling
process failures in a generic manner, by drawing on the [OTP][13] concept of
[supervision trees][15]. Erlang's [supervisor module][16] implements a process
which supervises other processes called child processes. The supervisor process
is responsible for starting, stopping, monitoring and even restarting its
child processes. A supervisors *children* can be either worker processes or
supervisors, which allows us to build hierarchical process structures (called
supervision trees in Erlang parlance).

The supervision APIs are a work in progress.

[1]: http://www.haskell.org/haskellwiki/Cloud_Haskell
[2]: https://github.com/haskell-distributed/distributed-process
[3]: https://github.com/haskell-distributed/distributed-process-platform
[4]: http://hackage.haskell.org/package/distributed-static
[5]: http://hackage.haskell.org/package/rank1dynamic
[6]: http://hackage.haskell.org/packages/network-transport
[7]: http://hackage.haskell.org/packages/network-transport-tcp
[8]: https://github.com/haskell-distributed/distributed-process/network-transport-inmemory
[9]: https://github.com/haskell-distributed/distributed-process/network-transport-composed
[10]: http://hackage.haskell.org/package/distributed-process-simplelocalnet
[11]: http://hackage.haskell.org/package/distributed-process-azure
[12]: http://research.microsoft.com/en-us/um/people/simonpj/papers/parallel/remote.pdf
[13]: http://en.wikipedia.org/wiki/Open_Telecom_Platform
[14]: http://hackage.haskell.org/packages/remote
[15]: http://www.erlang.org/doc/design_principles/sup_princ.html
[16]: http://www.erlang.org/doc/man/supervisor.html
[17]: /static/doc/distributed-process-platform/Control-Distributed-Process-Platform-Async.html
[18]: https://github.com/haskell-distributed/distributed-process-platform
[19]: http://hackage.haskell.org/package/async
[20]: /wiki/networktransport.html
[21]: /static/doc/distributed-process-platform/Control-Distributed-Process-Platform-ManagedProcess.html
[22]: /tutorials/3.managedprocess.html

