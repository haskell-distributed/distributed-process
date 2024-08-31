---
layout: wiki
title: Development
wiki: development
---

### Development

This section contains topics that are under development and have not
been formalized and added to formal specification or implemented.


#### Registry specification

*Problem: current specification doesn't cover the semantics of registry
if the remote processes can be put into registry and if we can send 
messages to such processes using `nsend`.*

Here is a prosal for semantics that is summary of the [email thread](https://groups.google.com/forum/?hl=en-GB#!topic/cloud-haskell-developers/120_WugguPg)

References are the following:

  * Uni  - stands for unified semantics for Future Erlang

  * Spec - stands for formal CH specification

  * ML   - stands for mailing list

**Semantics:**

  1. Registry.
      1. It should be possible to register remote processes in local registry (and local processes in remote registry)
         Rationale: [Uni. Sec 2.3]

      2. If a remote process is stored in registry then Node Controller starts monitoring that process
         Rationale:  (Implicit requirement in because node should be able to receive notification about process death)

      3. If a process dies and we get asynchronous notification then we remove process from registry
         Rationale: [Uni. Definition 18, Uni. Table 12] 

  2. `nsend` 

      1. `nsend` should be implemented in terms of lower level function `whereis` and `send`

      2. `nsend` is process does not exists in registry then message got silently dicarded.


Possible problems:

Current proposal opens space for race conditions, we should understand if those are relevant for us, and
could or could not be solved
  
a. 2.1 adds a possibility for changing label beetwen where is and send, so message will be
   sent to the wrong process.
