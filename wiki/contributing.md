---
layout: wiki
title: Contributor Guide
wiki: contributing
---

# Contributing

Community contributions are most welcome! These should be submitted via Github's
*pull request* mechanism. Following the guidelines described here will ensure
that pull requests require a minimum of effort to deal with, hopefully
allowing the maintainer who is merging your changes to focus on the substance
of the patch rather than stylistic concerns and/or handling merge conflicts.

This document is quite long, but don't let that put you off! Most of the things
we're saying here are just common sense and none of them is hard to follow.

With this in mind, please try to observe the following guidelines when
submitting patches.

### __1. Check to see if your patch is likely to be accepted__

We have a rather full backlog, so your help will be most welcome assisting
us in clearing that. You can view the exiting open issues on the
[jira issue tracker](https://cloud-haskell.atlassian.net/issues/?filter=10001).

If you wish to submit an issue there, you can do so without logging in,
although you obviously won't get any email notifications unless you create
an account and provide your email address.

It is also important to work out which component or sub-system should be
changed. You may wish to email the maintainers to discuss this first.

### __2. Make sure your patch merges cleanly__

Working through pull requests is time consuming and this project is entirely
staffed by volunteers. Please make sure your pull requests merge cleanly
whenever possible, so as to avoid wasting everyone's time.

The best way to achieve this is to fork the main repository on github, and then
make your changes in a local branch. Before submitting your pull request, fetch
and rebase any changes to the upstream source branch and merge these into your
local branch. For example:

{% highlight bash %}
## on your local repository, create a branch to work in

$ git checkout -b bugfix-issue123

## make, add and commit your changes

$ git checkout master
$ git remote add upstream git://github.com/haskell-distributed/distributed-process.git
$ git fetch upstream
$ git rebase upstream/master

## and now rebase (or merge) against your work

$ git checkout bugfix-issue123
$ git merge master

## make sure you resolve any merge conflicts
## and commit before sending a pull request!
{% endhighlight %}

### __3. Follow the patch submission *rules of thumb*__

These are pretty simple and are mostly cribbed from the GHC wiki's git working
conventions page [here](http://hackage.haskell.org/trac/ghc/wiki/WorkingConventions/Git).

1. try to make small patches - the bigger they are, the longer the pull request QA process will take
2. strictly separate all changes that affect functionality from those that just affect code layout, indentation, whitespace, filenames etc
3. always include the issue number (of the form `fixes #N`) in the final commit message for the patch - pull requests without an issue are unlikely to have been discussed (see above)
4. use Unix conventions for line endings. If you are on Windows, ensure that git handles line-endings sanely by running `git config --global core.autocrlf false`
5. make sure you have setup git to use the correct name and email for your commits - see the [github help guide](https://help.github.com/articles/setting-your-email-in-git)

### __4. Make sure all the tests pass__

If there are any failing tests then your pull request will not be merged. Please
don't rely on the maintainers to deal with these, unless of course the tests are
failing already on the branch you've diverged from. In that case, please submit
an issue so that we can fix the failing tests asap!

### __5. Try to eliminate compiler warnings__

Code should be compilable with `-Wall -Werror`. There should be no
warnings. We *may* make some exceptions to this rule, but pull requests that
contain multitudinous compiler warnings will take longer to QA.

### __6. Always branch from the right place__

Please be aware of whether or not your changes are actually a bugfix or a new
feature, and branch from the right place accordingly. The general rule is:

* new features must branch off `development`
* bug fixes must branch off `master` (which is the stable, production branch)

If you branch from the wrong place then you will be asked to rework your changes
so try to get this right in the first place. If you're unsure whether a patch
should be considered a feature or a bug-fix then discuss this when opening a new
github issue.

### General Style

Please carefully review the [Style Guide](/wiki/style.html) and stick to the
conventions set out there as best you can.
