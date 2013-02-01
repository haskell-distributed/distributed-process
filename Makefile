# CI build

GHC ?= $(shell which ghc)
CABAL ?= $(shell which cabal)

BASE_GIT := git://github.com/haskell-distributed
REPOS=$(shell cat REPOS | sed '/^$$/d')

.PHONY: all
all: $(REPOS)

$(REPOS):
	git clone $(BASE_GIT)/$@.git

.PHONY: install
install: $(REPOS)
	$(CABAL) install --with-ghc=$(GHC)

.PHONY: ci
ci: install
