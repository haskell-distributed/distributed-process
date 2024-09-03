---
layout: wiki
title: Fault Tolerance
wiki: reliability
---

### Reliability

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
process failures in a generic manner, by drawing on the [OTP][1] concept of
[supervision trees][2]. Erlang's [supervisor module][3] implements a process
which supervises other processes called child processes. The supervisor process
is responsible for starting, stopping, monitoring and even restarting its
child processes. A supervisors *children* can be either worker processes or
supervisors, which allows us to build hierarchical process structures (called
supervision trees in Erlang parlance).

[1]: http://en.wikipedia.org/wiki/Open_Telecom_Platform
[2]: http://www.erlang.org/doc/design_principles/sup_princ.html
[3]: http://www.erlang.org/doc/man/supervisor.html
