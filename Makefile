# CI build

GHC ?= $(shell which ghc)
CABAL ?= $(shell which cabal)

BASE_GIT := git://github.com/haskell-distributed
REPOS=$(shell cat REPOS | sed '/^$$/d')

.PHONY: all
all: $(REPOS)

$(REPOS):
	git clone $(BASE_GIT)/$@.git
	cd $@ && $(CABAL) install --with-ghc=$(GHC) --force-reinstall

.PHONY: install
install: $(REPOS)
	$(CABAL) install

.PHONY: ci
ci: install test

.PHONY: test
test:
	$(CABAL) configure --enable-tests
	$(CABAL) build
	$(CABAL) test --show-details=always
