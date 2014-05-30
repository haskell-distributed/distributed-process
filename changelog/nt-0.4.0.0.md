---
layout: changelog
code: NT
project: network-transport
date: 28-01-2013
status: Released
version: 0.4.0.0
commits: network-transport-0.3.0.1...v0.4.0.0
---

### Notes

Minor improvements to support the latest cloud haskell.

#### Bug Fixes

* [62171](https://github.com/haskell-distributed/network-transport/commit/6217173abd87c55e5c34565931b5ba41d729fe62) - Fix build for GHC 7.4 - thanks mboes!
* [5d0aa](https://github.com/haskell-distributed/network-transport/commit/5d0aacf421031eb155122d3381b1b401cd59f477) - Allow transformers above v5
* [NT-7](https://cloud-haskell.atlassian.net/browse/NT-7) - Bump binary version to include 0.7.*

#### Improvements

* [44672](https://github.com/haskell-distributed/network-transport/commit/44672be03c9d0d66926416fdac23555477f99229) - Binary instance for 'Reliability' - thanks mboes!
* [9c5d0c](https://github.com/haskell-distributed/network-transport/commit/9c5d0c7f84d59eae72075c4e327e3b7b7954f5aa) - Hashable instance for 'EndPointAddress'
