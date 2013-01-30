---
layout: wiki
title: Maintainers
wiki: Maintainers
---

### Maintainers

This guide is specifically for maintainers, and outlines the
development process and in particular, the branching strategy.

#### Branching/Merging Policy

The master branch is the **stable** branch, and should always be
in a *releasable* state. This means that on the whole, only small
self contained commits or topic branch merges should be applied
to master, and tagged releases should always be made against it.

#### Development Branches

Ongoing work can either be merged into master when complete or
merged into development. Development is effectively an integration
branch, to make sure ongoing changes and new features play nicely
with one another. On the other hand, master is a 'stable' branch
and therefore you should only merge into it if the result will be
releasable.

In general, we try to merge changes that belong to a major version
upgrade into development, whereas changes that will go into the
next minor version upgrade can be merged into master.

#### Keeping History

Try to make only clean commits, so that bisect will continue to work.
At the same time, it's best to avoid making destructive updates. If
you're planning on doing lots of squashing, then work in a branch
and don't commit directly to development - and **definitely** not to
master.

#### Follow the <a href="/wiki/contributing.html">Contributing guidelines</a>

What's good for the goose...

#### Making API documentation available on the website

Currently this is a manual process. If you don't sed/awk out the
reference/link paths, it'll be a mess. We will add a script to
handle this some time soon.

There is also an open ticket to set up nightly builds, which will
update the HEAD haddocks (on the website) and produce an 'sdist'
bundle and add that to the website too.

See https://cloud-haskell.atlassian.net/browse/INFRA-1 for details.

### Release Process

First of all, a few prior warnings. **Do not** tag any projects
until *after* you've finished the release. If you build and tag
three projects, only to find that a subsequent dependent package
needs a bit of last minute surgery, you'll be sorry you didn't
wait. With that in mind....

Before releasing any source code, make sure that all the jira tickets
added to the release are either resolved or remove them from the
release if you've decided to exclude them.

First, make sure all the version numbers and dependencies are aligned.

* bump the version numbers for each project that is being released
* bump the dependency versions across each project if needed
* make sure you've run a complete integration build and everything still installs ok
* bump the dependency version numbers in the cloud-haskell meta package

Now you'll want to go and update the change log and release notes for each
project. Change logs are stored in the individual project's git repository,
whilst release notes are stored on the wiki. This is easy to forget, as I
discovered! Change logs should be more concise than full blown release
notes.

Generate the packages with `cabal sdist` and test them all locally, then
upload them to hackage. Don't forget to upload the cloud-haskell meta-package
too!

#### After the release

**Now** you should tag all the projects with the relevant version number.
Since moving to individual git repositories, the tagging scheme is now
`x.y.z` and *not* `<project>-x.y.z`.

Once the release is out, you should go to [JIRA](https://cloud-haskell.atlassian.net)
and close all the tickets for the release. Jira has a nice 'bulk change'
feature that makes this very easy.

After that, it's time to tweet about the release, post to the parallel-haskell
mailing list, blog etc. Spread the word.
