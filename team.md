---
layout: team
title: Cloud Haskell Team
---

### Origins

Cloud Haskell was originally the brainchild of Jeff Epstein, Simon Peyton Jones
and Dr Andrew Black, whose joint paper for the Tokyo Haskell Symposium
[Towards Haskell in the Cloud][1], was expanded in Epstein's 2011 masters thesis
[Functional programming for the data centre][2].

[Jeff] [7] wrote the original implementation of Cloud Haskell, which is still
available in the published [remote package][3].

### Well Typed

[Well-Typed][4] is a consultancy specialising in Haskell/GHC development. A team
of developers from Well-Typed rewrote Jeff's [remote][3] package from the ground
up as part of the [Parallel Haskell Project][5]. Well-Typed remain closely involved
in Cloud Haskell.

### Maintainers

[Tim Watson][6] and [Jeff Epstein][7] are currently the [official maintainers][9]
of Cloud Haskell as a whole. [Edsko De Vries][13], a member of Well-Typed and the
author of much of the new implementation we have today, is still closely involved
as well.

Most of the packages are maintained by the haskell-distributed
organization, with people from Well Typed, Tweag, and other companies
that are involved.

The core [disributed-process][8] library is maintained by
[Facundo Domínguez][14], and the platform libaries are maintained by
[Tim Watson][6].

Some libraries are maintained my third parties, most notably d-p-p2p.

[Jeff][7] is the author of [distributed-process-global][11], a re-implementation of
Erlang's [global][12] (locking, registration and cluster management) API for
Cloud Haskell.

A number of other community members have contributed to the new implementation,
in various ways - here are at least some of them:

Duncan Coutts, Simon Marlow, Ryan Newton, Eric Kow, Adam Foltzer, Nicolas Wu
@rodlogic (github), Takayuki Muranushi, Alen Ribic, Pankaj More, Mark Wright

[1]: http://research.microsoft.com/en-us/um/people/simonpj/papers/parallel/remote.pdf
[2]: http://research.microsoft.com/en-us/um/people/simonpj/papers/parallel/epstein-thesis.pdf
[3]: http://hackage.haskell.org/package/remote-0.1.1
[4]: http://www.well-typed.com
[5]: http://www.haskell.org/haskellwiki/Parallel_GHC_Project
[6]: https://github.com/hyperthunk
[7]: https://github.com/jepst
[8]: https://github.com/haskell-distributed/disributed-process
[9]: http://hackage.haskell.org/trac/ghc/wiki/Contributors
[10]: http://en.wikipedia.org/wiki/Open_Telecom_Platform
[11]: https://github.com/jepst/distributed-process-global
[12]: http://www.erlang.org/doc/man/global.html
[13]: https://github.com/edsko
[14]: https://github.com/facundominguez
