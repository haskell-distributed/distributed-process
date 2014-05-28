---
layout: changelog
title: distributed-process-0.4.2
date: Sun Jan 27 15:12:02 UTC 2013
status: Released
version: 0.4.2
commits: distributed-process-0.4.1...v0.4.2
hackage: https://hackage.haskell.org/package/distributed-process
release: https://cloud-haskell.atlassian.net/browse/DP/fixforversion/10006
feed_url: https://cloud-haskell.atlassian.net/sr/jira.issueviews:searchrequest-rss/temp/SearchRequest.xml?jqlQuery=project+%3D+DP+AND+status+%3D+Closed+AND+fixVersion+%3D+0.4.2&tempMax=1000
---
---------
<h4>Notes</h4>

This is a small feature release containing process management enhancements and
a new tracing/debugging capability.

---------
<h4>Bugs</h4>
<ul>
<li>[<a href='https://cloud-haskell.atlassian.net/browse/DP-60'>DP-60</a>] - Fixes made for the distributed-process with strict bytestrings
</li>
</ul>

<h4>Improvements</h4>
<ul>
<li>[<a href='https://cloud-haskell.atlassian.net/browse/DP-61'>DP-61</a>] - Switched from Binary to cereal, allowed switching between lazy and strict ByteString
</li>
<li>[<a href='https://cloud-haskell.atlassian.net/browse/DP-31'>DP-31</a>] - Messages from the &quot;main channel&quot; as a receivePort
</li>
<li>[<a href='https://cloud-haskell.atlassian.net/browse/DP-35'>DP-35</a>] - Add variants of exit and kill for the current process
</li>
<li>[<a href='https://cloud-haskell.atlassian.net/browse/DP-50'>DP-50</a>] - Support for killing processes
</li>
<li>[<a href='https://cloud-haskell.atlassian.net/browse/DP-51'>DP-51</a>] - provide local versions of spawnLink and spawnMonitor
</li>
<li>[<a href="https://cloud-haskell.atlassian.net/browse/DP-13"> - Tracing and Debugging support]
</li>
</ul>
