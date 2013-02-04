CONF=./dist/setup-config
CABAL=distributed-process-platform.cabal
BUILD_DEPENDS=$(CONF) $(CABAL)

BASE_GIT := git://github.com/haskell-distributed
REPOS=$(shell cat REPOS | sed '/^$$/d')

.PHONY: all
all: build

.PHONY: test
test: build
	cabal test --show-details=always

.PHONY: build
build: configure
	cabal build

.PHONY: configure
configure: $(BUILD_DEPENDS)

.PHONY: ci
ci: $(REPOS) test

$(BUILD_DEPENDS):
	cabal configure --enable-tests

$(REPOS):
	git clone $(BASE_GIT)/$@.git
	cabal install ./$@ --force-reinstalls

.PHONY: clean
clean:
	cabal clean
