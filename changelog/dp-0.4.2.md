---
layout: changelog
title: distributed-process-0.4.2
date: 27-01-2013
status: Released
version: 0.4.2
commits: distributed-process-0.4.1...v0.4.2
release: 10006
---

### Notes

This is a small feature release containing process management enhancements and
a new tracing/debugging capability.

#### Bugs
* [DP-60](https://cloud-haskell.atlassian.net/browse/DP-60) - Fixes made for the distributed-process with strict bytestrings

#### Improvements
* [DP-61](https://cloud-haskell.atlassian.net/browse/DP-61) - Switched from Binary to cereal, allowed switching between lazy and strict ByteString
* [DP-31](https://cloud-haskell.atlassian.net/browse/DP-31) - Messages from the &quot;main channel&quot; as a receivePort
* [DP-35](https://cloud-haskell.atlassian.net/browse/DP-35) - Add variants of exit and kill for the current process
* [DP-50](https://cloud-haskell.atlassian.net/browse/DP-50) - Support for killing processes
* [DP-51](https://cloud-haskell.atlassian.net/browse/DP-51) - provide local versions of spawnLink and spawnMonitor
* [DP-13](https://cloud-haskell.atlassian.net/browse/DP-13) - Tracing and Debugging support]
