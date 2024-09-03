# Cloud Haskell contributor guidelines

## Building

After cloning, you should be able to build all packages in this repository like so:

```
$ cabal build all
```

You can also build a specific package like so:

```
cabal build <some-package>
```

You can have more control over the behavior of `cabal` by configuring, first. For example, if you want to disable optimizations for faster compilation:

```
$ cabal configure --disable-optimization
$ cabal build all
```

The allowed arguments for `cabal configure` are [documented here](https://cabal.readthedocs.io/en/stable/cabal-project-description-file.html#global-configuration-options).

Tests for all packages can be run with:

```
$ cabal test all
```

or again, you can test a specific package `<some-package>` using:

```
$ cabal test <some-package>
```

### Building with specific dependencies

Often, we want to build a package with a specific version of a dependency, for testing or debugging purposes. In this case, recall that you can always constrain cabal using the `--constraint` flag. For example, if I want to build `distributed-process-async` with `async==2.2.5`:

```
$ cabal build distributed-process-async --constraint="async==2.2.5"
```

## Contributing changes upstream

To contribute changes, you first need a fork. First, fork the `distributed-process` repository following the [instructions here](https://docs.github.com/en/pull-requests/collaborating-with-pull-requests/working-with-forks/fork-a-repo).

Then publish branches:

```
$ cabal test all        # Check that everything works before proceeding.
$ git push --set-upstream <username> <branch-name>
```

Then you can [create a pull-request](https://docs.github.com/en/pull-requests/collaborating-with-pull-requests/proposing-changes-to-your-work-with-pull-requests/creating-a-pull-request) to contribute changes back to `distributed-process`.
