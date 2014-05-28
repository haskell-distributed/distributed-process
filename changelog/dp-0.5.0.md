---
layout: changelog
title: distributed-process-0.5.0
status: Released
date: 28-05-2014
version: 0.5.0
commits: distributed-process-0.4.2...master
release: 10008
---

### Notes

This is a full feature release containing important enhancements to inter-process messaging,
process and node management, debugging and tracing. Various bug-fixes have also been made.

#### Highlights

New advanced messaging APIs provide broader polymorphic primitives for receiving and processing message
regardless of the underlying (when decoded) types. Extended exit handling capabilities have been added,
to facilitate processing *exit signals* when the *exit reason* could be represented by a variety of
underlying types.

The performance of inter-process messaging has been optimised for intra-node use cases. Messages are no
longer sent over the network-transport infrastructure when the receiving process resides on the same node
as the sender. New unsafe APIs have been made available to allow code that uses intra-node messaging to
skip the serialization of messages, facilitating further performance benefits at the risk of altered
error handling semantics. More details are available in the [UnsafePrimitives documentation][1].

A new [Management API][2] has been added, giving user code the ability to receive and respond to a running
node's internal system events. The tracing and debugging support added in 0.4.2 has been [upgraded][3] to use
this API, which is more efficient and flexible.

#### Bugs

* [DP-68](https://cloud-haskell.atlassian.net/browse/DP-68) - Dependency on STM implicitly changed from 1.3 to 1.4, but was not reflected in the cabal file
* [DP-79](https://cloud-haskell.atlassian.net/browse/DP-79) - Race condition in local monitoring when using call
* [DP-94](https://cloud-haskell.atlassian.net/browse/DP-94) - mask does not work correctly if unmask is called by another process

#### Improvements

* [DP-20](https://cloud-haskell.atlassian.net/browse/DP-20) - Improve efficiency of local message passing
* [DP-77](https://cloud-haskell.atlassian.net/browse/DP-77) - nsend should use local communication channels
* [DP-39](https://cloud-haskell.atlassian.net/browse/DP-39) - Link Node Controller and Network Listener
* [DP-62](https://cloud-haskell.atlassian.net/browse/DP-62) - Label spawned processes using labelThread
* [DP-85](https://cloud-haskell.atlassian.net/browse/DP-85) - Relax upper bound on syb in the cabal manifest
* [DP-78](https://cloud-haskell.atlassian.net/browse/DP-78) - Bump binary version to include 0.7.*
* [DP-92](https://cloud-haskell.atlassian.net/browse/DP-92) - Expose process info
* [DP-92](https://cloud-haskell.atlassian.net/browse/DP-92) - Expose node statistics
* [DP-91](https://cloud-haskell.atlassian.net/browse/DP-91) - Move tests to https://github.com/haskell-distributed/distributed-process-tests

#### New Features

* [DP-7](https://cloud-haskell.atlassian.net/browse/DP-7) - Polymorphic expect, see details [here](https://hackage.haskell.org/package/distributed-process-0.5.0/docs/Control-Distributed-Process.html#g:5)
* [DP-57](https://cloud-haskell.atlassian.net/browse/DP-57) - Expose Message type and broaden scope of polymorphic expect
* [DP-84](https://cloud-haskell.atlassian.net/browse/DP-84) - Management API (for working with internal/system events)
* [DP-83](https://cloud-haskell.atlassian.net/browse/DP-83) - Report node statistics for monitoring/management

[1]: https://hackage.haskell.org/package/distributed-process-0.5.0/docs/Control-Distributed-Process-UnsafePrimitives.html
[2]: https://hackage.haskell.org/package/distributed-process-0.5.0/docs/Control-Distributed-Process-Management.html
[3]: https://hackage.haskell.org/package/distributed-process-0.5.0/docs/Control-Distributed-Process-Debug.html
