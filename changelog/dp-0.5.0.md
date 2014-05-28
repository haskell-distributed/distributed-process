---
layout: changelog
title: distributed-process-0.5.0
status: Released
date: Wen May 28 12:15:02 UTC 2014
version: 0.5.0
commits: distributed-process-0.4.2...master
hackage: https://hackage.haskell.org/package/distributed-process
release: https://cloud-haskell.atlassian.net/browse/DP/fixforversion/10008
feed_url: https://cloud-haskell.atlassian.net/sr/jira.issueviews:searchrequest-rss/temp/SearchRequest.xml?jqlQuery=project+%3D+DP+AND+status+%3D+Closed+AND+fixVersion+%3D+0.5.0&tempMax=1000
---
---------
<h4>Notes</h4>

This is a full feature release containing important enhancements to inter-process messaging,
process and node management, debugging and tracing. Various bug-fixes have also been made.

<h5><b>Highlights</b></h5>

New advanced messaging APIs provide broader polymorphic primitives for receiving and processing message
regardless of the underlying (when decoded) types. Extended exit handling capabilities have been added,
to facilitate processing *exit signals* when the *exit reason* could be represented by a variety of
underlying types.

The performance of inter-process messaging has been optimised for intra-node use cases. Messages are no
longer sent over the network-transport infrastructure when the receiving process resides on the same node
as the sender. New `unsafe` APIs have been made available to allow code that uses intra-node messaging to
skip the serialization of messages, facilitating further performance benefits at the risk of altered
error handling semantics. More details are available in the [`UnsafePrimitives` documentation][1].

A new [*Management API*][2] has been added, giving user code the ability to receive and respond to a running
node's internal system events. The tracing and debugging support added in 0.4.2 has been [upgraded][3] to use
this API, which is more efficient and flexible.

---------

<h4>Bugs</h4>
<ul>
<li>[<a href='https://cloud-haskell.atlassian.net/browse/DP-68'>DP-68</a>] - Dependency on STM implicitly changed from 1.3 to 1.4, but was not reflected in the .cabal file</li>
<li>[<a href='https://cloud-haskell.atlassian.net/browse/DP-79'>DP-79</a>] - Race condition in local monitoring when using `call`</li>
<li>[<a href='https://cloud-haskell.atlassian.net/browse/DP-94'>DP-94</a>] - mask does not work correctly if unmask is called by another process</li>
</ul>

<h4>Improvements</h4>
<ul>
<li>[<a href='https://cloud-haskell.atlassian.net/browse/DP-20'>DP-20</a>] - Improve efficiency of local message passing</li>
<li>[<a href='https://cloud-haskell.atlassian.net/browse/DP-77'>DP-77</a>] - nsend should use local communication channels</li>
<li>[<a href='https://cloud-haskell.atlassian.net/browse/DP-39'>DP-39</a>] - Link Node Controller and Network Listener</li>
<li>[<a href='https://cloud-haskell.atlassian.net/browse/DP-62'>DP-62</a>] - Label spawned processes using labelThread</li>
<li>[<a href='https://cloud-haskell.atlassian.net/browse/DP-85'>DP-85</a>] - Relax upper bound on syb in the cabal manifest</li>
<li>[<a href='https://cloud-haskell.atlassian.net/browse/DP-78'>DP-78</a>] - Bump binary version to include 0.7.*</li>
<li>[<a href='https://cloud-haskell.atlassian.net/browse/DP-91'>DP-91</a>] - Move tests to https://github.com/haskell-distributed/distributed-process-tests</li>
<li>[<a href='https://cloud-haskell.atlassian.net/browse/DP-92'>DP-92</a>] - Expose process info</li>
<li>[<a href='https://cloud-haskell.atlassian.net/browse/DP-92'>DP-92</a>] - Expose node statistics</li>
</ul>

<h4>New Features</h4>
<ul>
<li>[<a href='https://cloud-haskell.atlassian.net/browse/DP-7'>DP-7</a>] - Polymorphic expect (see details <a href='https://hackage.haskell.org/package/distributed-process-0.5.0/docs/Control-Distributed-Process.html#g:5'>here</a>)</li>
<li>[<a href='https://cloud-haskell.atlassian.net/browse/DP-57'>DP-57</a>] - Expose Message and broaden the scope of polymorphic expect</li>
<li>[<a href='https://cloud-haskell.atlassian.net/browse/DP-84'>DP-84</a>] - Provide an API for working with internal (system) events</li>
<li>[<a href='https://cloud-haskell.atlassian.net/browse/DP-83'>DP-83</a>] - Report node statistics for monitoring/management</li>
</ul>


[1]: https://hackage.haskell.org/package/distributed-process-0.5.0/docs/Control-Distributed-Process-UnsafePrimitives.html
[2]: https://hackage.haskell.org/package/distributed-process-0.5.0/docs/Control-Distributed-Process-Management.html
[3]: https://hackage.haskell.org/package/distributed-process-0.5.0/docs/Control-Distributed-Process-Debug.html
