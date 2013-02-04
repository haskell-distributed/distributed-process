---
layout: wiki
title: FAQ/Getting Help
wiki: FAQ
---

### FAQ

#### Do I need to install a network-transport backend?

Yes. The `Network.Transport` component provides only the API - an actual
backend that implements this will be required in order to start a CH node.

#### What guarantees are there for message ordering, sending, etc

Take a look at the formal semantics for answers to *all* such questions.
They're actually quite pithy and readable, and fairly honest about where
there are still gaps.

You can find them via the *resources* tab just above this page.

#### Will I have to register a Jira account to submit issues?

Yes, you will need to provide a name and email address.

#### Why are you using Jira instead of Github Issues? It seems more complicated.

Jira **is** a bit more complicated than github's bug tracker, and it's certainly
not perfect. It is, however, a lot better suited to managing and planning a
project of this size. Cloud Haskell consists of no less than **13** individual
projects at this time, and that's not to mention some of the experimental ones
that have been developed by community members and *might* end up being absorbed
by the team.

### Help

If the documentation doesn't answer your question, queries about Cloud Haskell
can be directed to the Parallel Haskell Mailing List
(parallel-haskell@googlegroups.com), which is pretty active. If you think
you've found a bug, or would like to request a new feature, please visit the
[Jira Issue Tracker](https://cloud-haskell.atlassian.net) and submit a bug.
You **will** need to register with your email address to create new issues,
though you can freely browse the existing tickets without doing so.


### Getting Involved

If you're interested in hacking Cloud Haskell then please read the
[Contributing](/wiki/contributing.html) wiki page. Additional help can be obtained through the
[Developers Forum/Mailing List](https://groups.google.com/forum/?fromgroups=#!forum/cloud-haskell-developers)
or Parallel Haskell mailing list.
