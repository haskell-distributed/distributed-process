# CI build

GHC ?= $(shell which ghc)
CABAL ?= $(shell which cabal)

.PHONY: install
install:
	$(CABAL) install --with-ghc=$(GHC)

.PHONY: ci
ci: install
