# Cloud Haskell contributor guidelines

See [README](README.md) for how to build from source.

The Cloud Haskell project is made up of a number of independent
repositories. The cloud-haskell repository includes all other
repositories as submodules, for convenience. If you want to hack on
any Cloud Haskell package and contribute changes upstream, don't
checkout each individual repository in its own directory. Instead (if
you have [hub][hub] installed),

```
$ hub clone --recursive haskell-distributed/cloud-haskell
```

which clones all Cloud Haskell repositories as submodules inside the
`cloud-haskell` directory. You can then hack on each submodule as
usual, committing as usual.

[hub]: https://hub.github.com/

## Contributing changes upstream

### Contributing changes to a single package

To contribute changes, you first need a fork:

```
$ cd <submodule-dir>
$ hub fork
```

Then publish branches and submit pull requests as usual:

```
$ stack test        # Check that everything works before proceeding.
$ git push --set-upstream <username> <branch-name>
$ hub pull-request
```

### Contributing related changes to multiple packages

The vast majority of changes only affect a single package. But some
changes break compatibility with older versions of dependent packages.
In this case, you need to submit a separate PR for each package.
Before doing so,

```
$ stack test
```

in the top-level repository to test that all packages work together.
Submit the PR's as in the single package case, then additionally
follow the same instructions to submit a PR against the
`cloud-haskell` repository. This PR should normally only include
updates to the submodule references. The objective of this PR is to
kick the CI system into providing evidence to the Cloud Haskell
maintainers that with all the related changes to each package the
whole does compile and pass tests.
