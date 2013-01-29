---
layout: wiki
title: Maintainers
wiki: Maintainers
---

### Maintainers

This guide is specifically for maintainers, and outlines the
development process and in particular, the branching strategy.

#### Master == Stable

The master branch is the **stable** branch, and should always be
in a *releasable* state. This means that on the whole, only small
self contained commits or topic branch merges should be applied
to master, and tagged releases should always be made against it.

#### Development

Ongoing work can either be merged into master when complete or
merged into development. Development is effectively an integration
branch, to make sure ongoing changes and new features play nicely
with one another.

#### Releases

Remember to update the change log for each project when releasing it.
I forgot to add the changes to the changelog when tagging the recent
distributed-process-0.4.2 release, but in general they should be added
*before* tagging the release.

#### Follow the <a href="/wiki/contributing.html">Contributing guidelines</a>

What's good for the goose...

#### After releasing, send out a mail

To the Parallel Haskell Mailing List, and anywhere else that makes
sense.
