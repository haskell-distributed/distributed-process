# CI build

GHC ?= $(shell which ghc)
CABAL ?= $(shell which cabal)
CABAL_DEV ?= $(shell which cabal-dev)

BASE_GIT := git://github.com/haskell-distributed
REPOS=$(shell cat REPOS | sed '/^$$/d')

.PHONY: all
all: dev-install

.PHONY: dev-install
ifneq (,$(CABAL_DEV))
dev-install:
	$(CABAL_DEV) install
else
dev-install:
	$(error install cabal-dev to proceed)
endif

.PHONY: ci
ci: travis-install travis-test

.PHONY: travis-install
travis-install: $(REPOS)
	$(CABAL) install QuickCheck-2.6 --force-reinstalls
	$(CABAL) install rematch --force-reinstalls
	$(CABAL) install --with-ghc=$(GHC) $(REPOS) --force-reinstalls
	$(CABAL) install

.PHONY: travis-test
travis-test:
	$(CABAL) configure --enable-tests
	$(CABAL) build
	$(CABAL) test --show-details=always

$(REPOS):
	git clone $(BASE_GIT)/$@.git
