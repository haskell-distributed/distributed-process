# CI build

GHC ?= $(shell which ghc)
CABAL ?= $(shell which cabal)

BASE_GIT := git://github.com/haskell-distributed
REPOS=$(shell cat REPOS | sed '/^$$/d')

.PHONY: all
all: $(REPOS)

$(REPOS):
	git clone $(BASE_GIT)/$@.git
	$(CABAL) install --with-ghc=$(GHC) ./$@ --force-reinstalls

.PHONY: install
install: $(REPOS)
	$(CABAL) install

.PHONY: ci
ci: $(REPOS) test

.PHONY: deps
deps:
	$(CABAL) install data-accessor-transformers
	$(CABAL) install lockfree-queue
	$(CABAL) install test-framework-quickcheck2

.PHONY: test
test: deps
	$(CABAL) configure --enable-tests
	$(CABAL) build
	$(CABAL) test --show-details=always

.PHONY: itest
itest:
	$(CABAL) configure --enable-tests -f use-mock-network
	$(CABAL) build
	$(CABAL) test --show-details=always
