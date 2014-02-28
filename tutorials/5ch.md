---
layout: tutorial
categories: tutorial
sections: ['Introduction']
title: 5. Supervision Principles
---

### Introduction

In previous tutorial, we've looked at utilities for linking processes together
and monitoring their lifecycle as it changes. The ability to link and monitor are
foundational tools for building _reliable_ systems, and are the bedrock principles
on which Cloud Haskell's supervision capabilities are built.

The [`Supervisor`][1] provides a means to manage a set of _child processes_ and to construct
a tree of processes, where some children are workers (e.g., regular processes) and
others are themselves supervisors.

The supervisor process is started with a list of _child specifications_, which
tell the supervisor how to interact with its children. Each specification provides
the supervisor with the following information about the child process:

1. [`ChildKey`][2]: used to identify the child once it has been started
2. [`ChildType`][3]: indicating whether the child is a worker or another (nested) supervisor
3. [`RestartPolicy`][4]: tells the supervisor under what circumstances the child should be restarted
4. [`ChildTerminationPolicy`][5]: tells the supervisor how to terminate the child, should it need to
5. [`ChildStart`][6]: provides a means for the supervisor to start/spawn the child process

TBC

[1]: /static/doc/distributed-process-platform/Control-Distributed-Process-Platform-Supervisor.html
[2]: /static/doc/distributed-process-platform/Control-Distributed-Process-Platform-Supervisor.html
[3]: /static/doc/distributed-process-platform/Control-Distributed-Process-Platform-Supervisor.html
[4]: /static/doc/distributed-process-platform/Control-Distributed-Process-Platform-Supervisor.html
[5]: /static/doc/distributed-process-platform/Control-Distributed-Process-Platform-Supervisor.html
[6]: /static/doc/distributed-process-platform/Control-Distributed-Process-Platform/Supervisor.html
