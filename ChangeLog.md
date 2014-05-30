2014-05-30  Tim Watson  <watson.timothy@gmail.com>  0.4.0.0

#### Bug Fixes

* [62171](https://github.com/haskell-distributed/network-transport/commit/6217173abd87c55e5c34565931b5ba41d729fe62) - Fix build for GHC 7.4 - thanks mboes!
* [5d0aa](https://github.com/haskell-distributed/network-transport/commit/5d0aacf421031eb155122d3381b1b401cd59f477) - Allow transformers above v5
* [NT-7](https://cloud-haskell.atlassian.net/browse/NT-7) - Bump binary version to include 0.7.*

#### Improvements

* [44672](https://github.com/haskell-distributed/network-transport/commit/44672be03c9d0d66926416fdac23555477f99229) - Binary instance for 'Reliability' - thanks mboes!
* [9c5d0c](https://github.com/haskell-distributed/network-transport/commit/9c5d0c7f84d59eae72075c4e327e3b7b7954f5aa) - Hashable instance for 'EndPointAddress'

2012-11-22  Edsko de Vries  <edsko@well-typed.com>  0.3.0.1

* Relax bounds on Binary

2012-10-03  Edsko de Vries  <edsko@well-typed.com>  0.3.0

* Clarify disconnection
* Require that 'connect' be "as asynchronous as possible"
* Added strictness annotations

2012-07-16  Edsko de Vries  <edsko@well-typed.com>  0.2.0.2

* Base 4.6 compatible test suites
* Relax package constraints for bytestring

2012-07-16  Edsko de Vries  <edsko@well-typed.com>  0.2.0.1

* Hide catch only for base < 4.6

2012-07-07  Edsko de Vries  <edsko@well-typed.com>  0.2.0

* Initial release.
