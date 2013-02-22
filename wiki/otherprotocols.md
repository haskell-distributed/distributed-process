---
layout: wiki
title: Applications and other protocols
wiki: Applications
---

### Applications

If you are using `Network.Transport` in your application, or if you are writing (or interested in writing) `Network.Transport` support for another protocol, please add a brief description to this page so that we can coordinate the efforts.

### HdpH

**H**askell **D**istributed **P**arallel **H**askell is a shallowly
  embedded parallel extension of Haskell that supports high-level
  semi-explicit parallelism. HdpH has a distributed memory model, that
  manages computations on more than one multicore node. In addition
  _high-level semi-explicit parallelism_ is supported by providing
  `spark` for implicit task placement, alleviating the job of dynamic
  load management to HdpH. Explicit task placement is supported with
  the `pushTo` primitive. Lastly, HdpH supports the node <-> node
  transfer of polymorphic closures. This enables the definition of
  both evaluation strategies and algorithmic skeletons by using a
  small set of polymorphic coordination primitives.

The communication layer in HdpH adopts the `Network.Transport.TCP`
realization of the network-transport API. The HdpH implementation is
on hackage and is open source on GitHub.

* IFL2011 paper: [Implementing a High-level Distributed-Memory Parallel Haskell in Haskell](http://www.macs.hw.ac.uk/~pm175/papers/Maier_Trinder_IFL2011_XT.pdf)
* SAC2013 paper: [Reliable Scalable Symbolic Computation: The Design of SymGridPar2](http://www.macs.hw.ac.uk/~rs46/papers/sac2013/Maier_Stewart_Trinder_SAC2013.pdf)
* Hackage: [http://hackage.haskell.org/package/hdph](http://hackage.haskell.org/package/hdph)
* Source code [https://github.com/PatrickMaier/HdpH](https://github.com/PatrickMaier/HdpH)

# Protocol Implementations

## CCI

The [CCI](http://cci-forum.com) project is an open-source communication interface that aims to
provide a simple and portable API, high performance, scalability for
the largest deployments, and robustness in the presence of faults. It
is developed and maintained by a partnership of research, academic,
and industry members.

[Parallel Scientific](http://www.parsci.com) is contributing with CCI development and promoting
its adoption as a portable API. We have developed [Haskell bindings](https://www.assembla.com/code/cci-haskell/git/nodes) for
the CCI alpha implementation, and are keen to have a CCI backend for
Cloud Haskell as resources allow.
