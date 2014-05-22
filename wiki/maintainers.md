---
layout: wiki
title: Maintainers
wiki: Maintainers
---

### Maintainers

This part of the guide is specifically for maintainers, and outlines the development
process and in particular, the branching strategy. We also point out Cloud Haskell's
various bits of infrastructure as they stand at the moment.

Perhaps the most important thing to do as a maintainer, is to make other developers
aware of what you're working on by assigning the Jira issue to yourself!

----
#### Releases

All releases are published to [hackage][3]. At some point we may start to
make *nightly builds* available on this website. We need some help setting that
up though.

----

#### Community

We keep in touch through the [parallel-haskell google group][7], and once you've
joined the group, by posting to the mailing list address: parallel-haskell@googlegroups.com.
This is a group for **all** things related to concurrent and parallel Haskell. There is
also a maintainer/developer centric [cloud-haskell-developers google group][9], which is
more for in-depth questions about contributing to or maintaining Cloud Haskell.

You might also find some of us hanging out at #haskell-distributed on
freenode from time to time.

We have a twitter account! [@CloudHaskell](https://twitter.com/CloudHaskell)
will be used to make announcements (of new releases, etc) on a regular basis.

----

### Bug/Issue Tracking and Continuous Integration

Our bug tracker is a hosted/on-demand Jira, for which a free open source
project license was kindly donated by [Atlassian][6]. You can browse all
issues without logging in, however to report new issues/bugs you will
need to provide an email address and create an account.

If you have any difficulties doing so, please post an email to the
[parallel-haskell mailing list][7] at parallel-haskell@googlegroups.com.

We currently use [travis-ci][11] for continuous integration. We do however,
have an open source license for Atlassian Bamboo, which we will be migrating
to over time - this process is quite involved so we don't have a picture of
the timescales yet.

----

### Branching/Merging Policy

The master branch is the *active development* branch. Small changes can be committed
directly to `master`, or committed to a branche before getting merged. When we're
ready to release, the project is tagged using the format `vX.Y.Z` once it has been
published. Each release then gets its own `release-x.y.z` branch, created from the
tagged commit. These can be used to produce interim/bug-fix releases if necessary.

A release tag should be of the form `x.y.z` and should **not** be prefixed with the
repository name. Older tags use the latter form as they date from a time when all the
Cloud Haskell source code lived under one git repository.

Patches should be made against `master` **unless** they represent an interim bug-fix
to a given `release-x-y-z` branch. The latter should be created against the branch
they intend to fix.

#### Development Branches

Development should usually take place on a `feature-X` or `bugfix-Y` branch. The
old `development` branch is defunct and will be removed at some point in the future.

#### Interim and bug-fix only releases

The complexity around *interim* releases is necessary to deal with situations where we
need to patch a release, but `master` has already moved on, making the patch irrelevant
for the next major release. For example, assuming a project is at version 1.2.3 and we
find a bug in module `Foo.hs`. Users who're on v1.2.3 will want the fix asap for any
production deployments, yet `Foo.hs` has been completely re-written/replaced on `master`
and the bugfix isn't needed there. To support user's who do not wish to wait for v2.0.0
to be released, we create a `release-1.2.4` branch and merge the bugfix into that, but
we do **not** merge this back into master, since the patch won't apply.
This way, subsequent bug fixes to the 1.2.x series can also continue in parallel with
changes to `master` if necessary.

What happens if we have a patch for `release-1.2.3` that *is* applicable to master, but
won't apply cleanly due to changes since the release was tagged? In this situation, we
create a bug-fix release branch as usual, into which the patch is merged. A maintainer
will then have to retro-fit the patch so that it can be applied to `master`. This is
a somewhat ugly, since if we wish to create subsequent bug-fixes and create another
1.2.5 branch (viz the example above), we'll may have to manually transplant some changes
from `master` in the process.

#### Keeping History

Try to make only clean commits, so that bisect will continue to work. At the same time,
it can be helpful to avoid making destructive updates. If you're planning on doing lots
of squashes, then work in a branch and don't commit directly to `master` until you're
finished and ready to QA and merge.

#### Committing without triggering CI builds

Whilst we're on travis-ci, you can do this by putting the text `[ci skip]` anywhere in
the commit message. Please, please **do not** put this on the first line of the commit
message.

Once we migrate to Bamboo, this may change.

#### Changing Jira bugs/issues via commit messages

You can make complex changes to one or more Jira issues with a single commit message.
As with skipping CI builds, please **do not** put this messy text into the first line
of your commit messages.

Details of the format/syntax required to do this can be found on
[this Jira documentation page](https://confluence.atlassian.com/display/AOD/Processing+JIRA+issues+with+commit+messages)

----

#### Follow the <a href="/wiki/contributing.html">Contributing guidelines</a>

What's good for the goose...

#### Making API documentation available on the website

There is an open ticket to set up nightly builds, which will update
the HEAD haddocks (on the website) and produce an 'sdist' bundle and
add that to the website too.

See https://cloud-haskell.atlassian.net/browse/INFRA-1 for details.

### Release Process

First of all, a few prior warnings. **Do not** tag any projects until *after*
you've finished and uploaded the release. If you build and tag three projects,
only to find that a subsequent dependent package needs a bit of last minute
surgery, you'll be sorry you didn't wait. With that in mind....

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
`x.y.z` and *not* `<project>-x.y.z`. Once you've tagged the release, create
a branch named `release-x.y.z` and push both the newly created tag(s) and the
branch(es).

Once the release is out, you should go to [JIRA](https://cloud-haskell.atlassian.net)
and close all the tickets for the release. Jira has a nice 'bulk change' feature
that makes this very easy.

After that, it's time to tweet about the release, post to the parallel-haskell
mailing list, blog etc. Spread the word.

[1]: https://github.com/haskell-distributed
[2]: https://github.com/haskell-distributed/haskell-distributed.github.com
[3]: http://hackage.haskell.org
[4]: http://git-scm.com/book/en/Git-Basics-Tagging
[5]: https://cloud-haskell.atlassian.net/secure/Dashboard.jspa
[6]: http://atlassian.com/
[7]: https://groups.google.com/forum/?fromgroups=#!forum/parallel-haskell
[8]: /team.html
[9]: https://groups.google.com/forum/?fromgroups#!forum/cloud-haskell-developers
[10]: http://en.wikipedia.org/wiki/Greenwich_Mean_Time
[11]: https://travis-ci.org/
