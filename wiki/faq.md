---
layout: wiki
title: FAQ
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
