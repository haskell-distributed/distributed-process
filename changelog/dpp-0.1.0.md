---
layout: changelog
code: DPP
project: distributed-process-platform
status: Released
date: 28-05-2014
version: 0.5.0
commits: b3dee891...master
release: 10003
---

### Notes / Highlights

This is the first release of distributed-process-platform.
Modelled after Erlang's OTP, this framework provides similar
facilities for Cloud Haskell, grouping essential practices
into a set of modules and standards designed to help you build
concurrent, distributed applications with relative ease.

#### Highlights

* [UnsafePrimitives][2] - Extended version of the [UnsafePrimitives module from distributed-process][1]
* [Time][3] - API for working with time delays and timeouts
* [Timer][4] - Timer API (for running code or sending messages based on timers)
* [Async][21] - API for spawning asynchronous operations, waiting for results, cancelling, etc
* [Async - STM][22] - Async implementation built on STM
* [Async - Chan][23] - Async implementation built on Typed Channels
* [Managed Processes][5] - Build complex 'Processes' by abstracting out management of the process' mailbox, reply/response handling, timeouts, process hiberation, error handling and shutdown/stop procedures
* [Managed Processes - Prioritised Mailbox][6] - Prioritised Message Processing
* [Managed Processes - Restricted Execution][7] - Restricted (pure) execution environment
* [Managed Processes - Client API][8] - Client facing `ManagedProcess` API
* [Managed Processes - Unsafe Clients][9] - Unsafe client API
* [Process Supervision][10] - A generic API for supervising trees of managed processes
* [Execution Framework][11] - Framework for managing non-functional implementation aspects such as load regulation
* [Execution - Buffers][12] - Mailbox bounding and buffering
* [Execution - Routing][13] - The "exchange" message routing pattern
* [Execution - Event Handling][14] - Generic *event handling* mechanism
* [Task Framework][15] - Task management, work scheduling and execution management
* [Task Framework - Queues][16] - Bounded (i.e., blocking) work queues
* [Service Framework][17] - Framework for developing re-usable service components
* [Service - Monitoring][18] - Node monitoring API
* [Service - Registry][19] - General Purpose Extended Process Registry
* [Service - System Log][20] - Extensible System Logging Capability

#### Improvements / New Features

* [DPP-68](https://cloud-haskell.atlassian.net/browse/DPP-68) - a variant of `link` that only signals in case of abnormal termination
* [DPP-4](https://cloud-haskell.atlassian.net/browse/DPP-4) - Managed Processes (aka gen-server)
* [DPP-74](https://cloud-haskell.atlassian.net/browse/DPP-74) - Priority Queue based Managed Process
* [DPP-71](https://cloud-haskell.atlassian.net/browse/DPP-71) - ManagedProcess API consistency
* [DPP-7](https://cloud-haskell.atlassian.net/browse/DPP-7) - Channel vs Process based GenServer
* [DPP-1](https://cloud-haskell.atlassian.net/browse/DPP-1) - Supervision trees
* [DPP-79](https://cloud-haskell.atlassian.net/browse/DPP-79) - Add support for Akka-style routers
* [DPP-81](https://cloud-haskell.atlassian.net/browse/DPP-81) - Have two Supervisor.ChildSpec constructors, one for RemoteChild (current one) and one for LocalChild 

#### Bugs

Since this is the first release, see [github](https://github.com/haskell-distributed/distributed-process-platform/commits) for
a view on bugs that have been filed and fixed during the development process.

[1]: https://hackage.haskell.org/package/distributed-process-0.5.0/docs/Control-Distributed-Process-UnsafePrimitives.html
[2]: https://hackage.haskell.org/package/distributed-process-platform-0.1.0/docs/Control-Distributed-Process-Platform-UnsafePrimitives.html
[3]: https://hackage.haskell.org/package/distributed-process-0.5.0/docs/Control-Distributed-Process-Platform-Time.html
[4]: https://hackage.haskell.org/package/distributed-process-0.5.0/docs/Control-Distributed-Process-Platform-Timer.html
[5]: https://hackage.haskell.org/package/distributed-process-0.5.0/docs/Control-Distributed-Process-Platform-ManagedProcess.html
[6]: https://hackage.haskell.org/package/distributed-process-0.5.0/docs/Control-Distributed-Process-Platform-ManagedProcess-Server-Priority.html
[7]: https://hackage.haskell.org/package/distributed-process-0.5.0/docs/Control-Distributed-Process-Platform-ManagedProcess-Server-Restricted.html
[8]: https://hackage.haskell.org/package/distributed-process-0.5.0/docs/Control-Distributed-Process-Platform-ManagedProcess-Client.html
[9]: https://hackage.haskell.org/package/distributed-process-0.5.0/docs/Control-Distributed-Process-Platform-ManagedProcess-UnsafeClient.html
[10]: https://hackage.haskell.org/package/distributed-process-0.5.0/docs/Control-Distributed-Process-Platform-Supervisor.html
[11]: https://hackage.haskell.org/package/distributed-process-0.5.0/docs/Control-Distributed-Process-Platform-Execution.html
[12]: https://hackage.haskell.org/package/distributed-process-0.5.0/docs/Control-Distributed-Process-Platform-Execution-Mailbox.html
[13]: https://hackage.haskell.org/package/distributed-process-0.5.0/docs/Control-Distributed-Process-Platform-Execution-Exchange.html
[14]: https://hackage.haskell.org/package/distributed-process-0.5.0/docs/Control-Distributed-Process-Platform-Execution-EventManager.html
[15]: https://hackage.haskell.org/package/distributed-process-0.5.0/docs/Control-Distributed-Process-Platform-Task.html
[16]: https://hackage.haskell.org/package/distributed-process-0.5.0/docs/Control-Distributed-Process-Platform-Task=Queue-BlockingQueue.html
[17]: https://hackage.haskell.org/package/distributed-process-0.5.0/docs/Control-Distributed-Process-Platform-Service.html
[18]: https://hackage.haskell.org/package/distributed-process-0.5.0/docs/Control-Distributed-Process-Platform-Service-Monitoring.html
[19]: https://hackage.haskell.org/package/distributed-process-0.5.0/docs/Control-Distributed-Process-Platform-Service-Registry.html
[20]: https://hackage.haskell.org/package/distributed-process-0.5.0/docs/Control-Distributed-Process-Platform-Service-SystemLog.html
[21]: https://hackage.haskell.org/package/distributed-process-0.5.0/docs/Control-Distributed-Process-Platform-Async.html
[22]: https://hackage.haskell.org/package/distributed-process-0.5.0/docs/Control-Distributed-Process-Platform-Async-AsyncSTM.html
[23]: https://hackage.haskell.org/package/distributed-process-0.5.0/docs/Control-Distributed-Process-Platform-Async-AsyncChan.html
