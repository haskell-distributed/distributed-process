# CI build

GHC ?= $(shell which ghc)
CABAL ?= $(shell which cabal)
CABAL_DEV ?= $(shell which cabal-dev)
PWD = $(shell pwd)
SANDBOX ?= $(PWD)/cabal-dev
BRANCH ?= $(shell git branch | grep '*' | awk '/.*/ { print $NF }')
GIT_BASE ?= git://github.com/haskell-distributed
USE_LOCAL_UMBRELLA ?=
REPOS=$(shell cat REPOS | sed '/^$$/d')

.PHONY: all
all:
	$(info branch = ${BRANCH})

.PHONY: clean
clean:
	rm -rf ${REPOS} ./dist ./cabal-dev

.PHONY: dev-install
ifneq (,$(CABAL_DEV))
dev-install: $(REPOS)
	$(CABAL_DEV) install --enable-tests
else
dev-install:
	$(error install cabal-dev to proceed)
endif

.PHONY: ci
ci: travis-install travis-test

.PHONY: travis-install
travis-install: $(REPOS)
	$(CABAL) install --with-ghc=$(GHC) $(REPOS) --force-reinstalls
	$(CABAL) install

.PHONY: travis-test
travis-test:
	$(CABAL) configure --enable-tests
	$(CABAL) build
	$(CABAL) test --show-details=always

ifneq (,$(USE_LOCAL_UMBRELLA))
define clone
	git clone $(GIT_BASE)/$1 $1
endef
else
define clone
	git clone $(GIT_BASE)/$1.git $1
endef
endif

$(REPOS):
	$(call clone,$@)
	git --git-dir=$@/.git \
		--work-tree=$@ \
		checkout $(BRANCH)
	cd $@ && $(CABAL_DEV) install --sandbox=$(SANDBOX)

./build:
	mkdir -p build
