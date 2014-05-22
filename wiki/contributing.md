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

## Common Repository Format and Git Branches

All Cloud Haskell repositories should conform to a common structure, with the
exception of website and/or documentation projects. The structure is basically
that of a cabal library or executable project, with a couple of additional files.

```
- project-name
  - project-name.cabal
  - Makefile
  - LICENCE
  - README.md
  - src/
  - tests/
  - benchmarks/
  - examples/
  - regressions/
```

All repositories must use the same git branch structure: 

* ongoing development takes place on the `master` branch
* the code that goes into a release must be tagged as soon as it is uploaded to hackage
* each release tag must then get its own release-x.y.z branch, branched from the tagged commit
* after a release, the *release branch* is not merged back into `master`
* patches can be submitted via branches off `master`, or from a `release-x.y.z` branch
* features and bug-fixes that are compatible with `master` can be merged in directly
* interim bug-fixes we **don't** want included (i.e., bug-fix only releases)
  * are merged into a new release-x.y.z branch (taken from the prior release branch) instead
  * these can, but do not have to be, merged into `master`

### __1. Check to see if your patch is likely to be accepted__

We have a rather full backlog, so your help will be most welcome assisting
us in clearing that. You can view the exiting open issues on the
[jira issue tracker](https://cloud-haskell.atlassian.net/issues/?filter=10001).

If you wish to submit a new issue there, you cannot do so without logging in
creating an account (by providing your email address) and logging in.

It is also helpful to work out which component or sub-system should be
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

## add and commit your changes
## base them on master for bugfixes or development for new features

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
3. always include the issue number (of the form `PROJECT_CODE #resolve Fixed`) in the final commit message for the patch - pull requests without an issue are unlikely to have been discussed (see above)
4. use Unix conventions for line endings. If you are on Windows, ensure that git handles line-endings sanely by running `git config --global core.autocrlf false`
5. make sure you have setup git to use the correct name and email for your commits - see the [github help guide](https://help.github.com/articles/setting-your-email-in-git) - otherwise you won't be attributed in the scm history!

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

* new features should branch off `master`
* bug fixes can branch off `master` or a `release-x.y.z` branch

If you branch from the wrong place then you will be asked to rework your changes
so try to get this right in the first place. If you're unsure whether a patch
should be considered a feature or a bug-fix then discuss this when opening a new
github issue.

### General Style

A lot of this **is** taken from the GHC Coding Style entry [here](http://hackage.haskell.org/trac/ghc/wiki/Commentary/CodingStyle).
In particular, please follow **all** the advice on that wiki page when it comes 
to including comments in your code.

I am also grateful to @tibbe for his
[haskell-style-guide](https://github.com/tibbe/haskell-style-guide), from
which some of these rules have been taken.

As a general rule, stick to the same coding style as is already used in the file 
you're editing. It **is** much better to write code that is transparent than to 
write code that is short. Please don't assume everyone is a minimalist - self
explanatory code is **much** better in the long term than pithy one-liners.
Having said that, we *do* like reusing abstractions where doing so adds to the
clarity of the code as well as minimising repetitious boilerplate.

### Formatting

#### Line Length

Maximum line length is *80 characters*. This might seem antiquated
to you, but some of us do things like github pull-request code
reviews on our mobile devices on the way to work, and long lines
make this horrendously difficult. Besides which, some of us are
also emacs users and have this rule set up for all of our source
code editing modes.

#### Indentation

Tabs are illegal. Use **only** spaces for indenting.
Indentation is usually 2 spaces, with 4 spaces used in some places.
We're pretty chilled about this, but try to remain consistent.

#### Blank Lines

One blank line between top-level definitions.  No blank lines between
type signatures and function definitions.  Add one blank line between
functions in a type class instance declaration if the functions bodies
are large. As always, use your judgement.

#### Whitespace

Do not introduce trailing whitespace. If you find trailing whitespace,
feel free to strip it out - in a separate commit of course!

Surround binary operators with a single space on either side.  Use
your better judgement for the insertion of spaces around arithmetic
operators but always be consistent about whitespace on either side of
a binary operator.

#### Alignment

When it comes to alignment, there's probably a mix of things in the codebase
right now. Personally, I tend not to align import statements as these change
quite frequently and it is pain keeping the indentation consistent.

The one exception to this is probably imports/exports, which we *are* a
bit finicky about: 

{% highlight haskell %}
import qualified Foo.Bar.Baz as Bz
import Data.Binary
  ( Binary (..),
  , getWord8
  , putWord8
  )
import Data.Blah
import Data.Boom (Typeable)
{% endhighlight %}

We generally don't care *that much* about alignment for other things,
but as always, try to follow the convention in the file you're editing
and don't change things just for the sake of it.

### Comments

#### Punctuation

Write proper sentences; start with a capital letter and use proper
punctuation.

#### Top-Level Definitions

Comment every top level function (particularly exported functions),
and provide a type signature; use Haddock syntax in the comments.
Comment every exported data type. Function example:

{% highlight haskell %}
-- | Send a message on a socket. The socket must be in a connected
-- state.  Returns the number of bytes sent. Applications are
-- responsible for ensuring that all data has been sent.
send :: Socket      -- ^ Connected socket
     -> ByteString  -- ^ Data to send
     -> IO Int      -- ^ Bytes sent
{% endhighlight %}

For functions, the documentation should give enough information to
apply the function without looking at the function's definition.

### Naming

Use `mixedCase` when naming functions and `CamelCase` when naming data
types.

For readability reasons, don't capitalize all letters when using an
abbreviation.  For example, write `HttpServer` instead of
`HTTPServer`.  Exception: Two letter abbreviations, e.g. `IO`.

#### Modules

Use singular when naming modules e.g. use `Data.Map` and
`Data.ByteString.Internal` instead of `Data.Maps` and
`Data.ByteString.Internals`.

