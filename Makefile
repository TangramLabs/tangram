#!/usr/bin/make -f

PACKAGES_NOSIMULATION=$(shell go list ./... | grep -v '/simulation')
VERSION ?= $(shell echo $(shell git describe --tags --always) | sed 's/^v//')
TMVERSION := $(shell go list -m github.com/tendermint/tendermint | sed 's:.* ::')
COMMIT := $(shell git log -1 --format='%H')
LEDGER_ENABLED ?= true
BINDIR ?= $(GOPATH)/bin
TANGRAM_BINARY = tangramd
TANGRAM_DIR = tangram
BUILDDIR ?= $(CURDIR)/build
HTTPS_GIT := https://github.com/TangramLabs/tangram.git
DOCKER := $(shell which docker)
NAMESPACE := tangramlabs
PROJECT := tangram
DOCKER_IMAGE := $(NAMESPACE)/$(PROJECT)
COMMIT_HASH := $(shell git rev-parse --short=7 HEAD)
DOCKER_TAG := $(COMMIT_HASH)
# e2e env
MOUNT_PATH := $(shell pwd)/build/:/root/
E2E_SKIP_CLEANUP := false

# Default target executed when no arguments are given to make.
default_target: all

.PHONY: default_target

# process build tags

build_tags = netgo
ifeq ($(LEDGER_ENABLED),true)
  ifeq ($(OS),Windows_NT)
    GCCEXE = $(shell where gcc.exe 2> NUL)
    ifeq ($(GCCEXE),)
      $(error gcc.exe not installed for ledger support, please install or set LEDGER_ENABLED=false)
    else
      build_tags += ledger
    endif
  else
    UNAME_S = $(shell uname -s)
    ifeq ($(UNAME_S),OpenBSD)
      $(warning OpenBSD detected, disabling ledger support (https://github.com/cosmos/cosmos-sdk/issues/1988))
    else
      GCC = $(shell command -v gcc 2> /dev/null)
      ifeq ($(GCC),)
        $(error gcc not installed for ledger support, please install or set LEDGER_ENABLED=false)
      else
        build_tags += ledger
      endif
    endif
  endif
endif

ifeq (cleveldb,$(findstring cleveldb,$(COSMOS_BUILD_OPTIONS)))
  build_tags += gcc
endif
build_tags += $(BUILD_TAGS)
build_tags := $(strip $(build_tags))

# process linker flags

ldflags = -X github.com/cosmos/cosmos-sdk/version.Name=tangram \
          -X github.com/cosmos/cosmos-sdk/version.AppName=$(TANGRAM_BINARY) \
          -X github.com/cosmos/cosmos-sdk/version.Version=$(VERSION) \
          -X github.com/cosmos/cosmos-sdk/version.Commit=$(COMMIT) \
          -X github.com/tendermint/tendermint/version.TMCoreSemVer=$(TMVERSION)

# DB backend selection
ifeq (cleveldb,$(findstring cleveldb,$(COSMOS_BUILD_OPTIONS)))
  ldflags += -X github.com/cosmos/cosmos-sdk/types.DBBackend=cleveldb
endif
ifeq (badgerdb,$(findstring badgerdb,$(COSMOS_BUILD_OPTIONS)))
  ldflags += -X github.com/cosmos/cosmos-sdk/types.DBBackend=badgerdb
endif
# handle rocksdb
ifeq (rocksdb,$(findstring rocksdb,$(COSMOS_BUILD_OPTIONS)))
  CGO_ENABLED=1
  build_tags += rocksdb
  ldflags += -X github.com/cosmos/cosmos-sdk/types.DBBackend=rocksdb
endif
# handle boltdb
ifeq (boltdb,$(findstring boltdb,$(COSMOS_BUILD_OPTIONS)))
  build_tags += boltdb
  ldflags += -X github.com/cosmos/cosmos-sdk/types.DBBackend=boltdb
endif

# add build tags to linker flags
whitespace := $(subst ,, )
comma := ,
build_tags_comma_sep := $(subst $(whitespace),$(comma),$(build_tags))
ldflags += -X "github.com/cosmos/cosmos-sdk/version.BuildTags=$(build_tags_comma_sep)"

ifeq (,$(findstring nostrip,$(COSMOS_BUILD_OPTIONS)))
  ldflags += -w -s
endif
ldflags += $(LDFLAGS)
ldflags := $(strip $(ldflags))

BUILD_FLAGS := -tags "$(build_tags)" -ldflags '$(ldflags)'
# check for nostrip option
ifeq (,$(findstring nostrip,$(COSMOS_BUILD_OPTIONS)))
  BUILD_FLAGS += -trimpath
endif

# check if no optimization option is passed
# used for remote debugging
ifneq (,$(findstring nooptimization,$(COSMOS_BUILD_OPTIONS)))
  BUILD_FLAGS += -gcflags "all=-N -l"
endif

# # The below include contains the tools and runsim targets.
# include contrib/devtools/Makefile

###############################################################################
###                                  Build                                  ###
###############################################################################

BUILD_TARGETS := build install

build: BUILD_ARGS=-o $(BUILDDIR)/
build-linux:
	GOOS=linux GOARCH=amd64 LEDGER_ENABLED=false $(MAKE) build

$(BUILD_TARGETS): go.sum $(BUILDDIR)/
	go $@ $(BUILD_FLAGS) $(BUILD_ARGS) ./...

$(BUILDDIR)/:
	mkdir -p $(BUILDDIR)/

build-docker:
	# TODO replace with kaniko
	$(DOCKER) build -t ${DOCKER_IMAGE}:${DOCKER_TAG} .
	$(DOCKER) tag ${DOCKER_IMAGE}:${DOCKER_TAG} ${DOCKER_IMAGE}:latest
	# docker tag ${DOCKER_IMAGE}:${DOCKER_TAG} ${DOCKER_IMAGE}:${COMMIT_HASH}
	# update old container
	$(DOCKER) rm tangram || true
	# create a new container from the latest image
	$(DOCKER) create --name tangram -t -i ${DOCKER_IMAGE}:latest tangram
	# move the binaries to the ./build directory
	mkdir -p ./build/
	$(DOCKER) cp tangram:/usr/bin/tangramd ./build/

push-docker: build-docker
	$(DOCKER) push ${DOCKER_IMAGE}:${DOCKER_TAG}
	$(DOCKER) push ${DOCKER_IMAGE}:latest

$(MOCKS_DIR):
	mkdir -p $(MOCKS_DIR)

distclean: clean tools-clean

clean:
	rm -rf \
    $(BUILDDIR)/ \
    artifacts/ \
    tmp-swagger-gen/

all: build

build-all: tools build lint test vulncheck

.PHONY: distclean clean build-all

###############################################################################
###                          Tools & Dependencies                           ###
###############################################################################

TOOLS_DESTDIR  ?= $(GOPATH)/bin
STATIK         = $(TOOLS_DESTDIR)/statik
RUNSIM         = $(TOOLS_DESTDIR)/runsim

# Install the runsim binary with a temporary workaround of entering an outside
# directory as the "go get" command ignores the -mod option and will polute the
# go.{mod, sum} files.
#
# ref: https://github.com/golang/go/issues/30515
runsim: $(RUNSIM)
$(RUNSIM):
	@echo "Installing runsim..."
	@(cd /tmp && ${GO_MOD} go install github.com/cosmos/tools/cmd/runsim@master)

statik: $(STATIK)
$(STATIK):
	@echo "Installing statik..."
	@(cd /tmp && go install github.com/rakyll/statik@v0.1.6)

contract-tools:
ifeq (, $(shell which stringer))
	@echo "Installing stringer..."
	@go install golang.org/x/tools/cmd/stringer@latest
else
	@echo "stringer already installed; skipping..."
endif

ifeq (, $(shell which go-bindata))
	@echo "Installing go-bindata..."
	@go install github.com/kevinburke/go-bindata/go-bindata@latest
else
	@echo "go-bindata already installed; skipping..."
endif

ifeq (, $(shell which gencodec))
	@echo "Installing gencodec..."
	@go install github.com/fjl/gencodec@latest
else
	@echo "gencodec already installed; skipping..."
endif

ifeq (, $(shell which protoc-gen-go))
	@echo "Installing protoc-gen-go..."
	@go install github.com/fjl/gencodec@latest
	@go install google.golang.org/protobuf/cmd/protoc-gen-go@latest
else
	@echo "protoc-gen-go already installed; skipping..."
endif

ifeq (, $(shell which protoc-gen-go-grpc))
	@go install google.golang.org/grpc/cmd/protoc-gen-go-grpc@latest
else
	@echo "protoc-gen-go-grpc already installed; skipping..."
endif

ifeq (, $(shell which solcjs))
	@echo "Installing solcjs..."
	@npm install -g solc@0.5.11
else
	@echo "solcjs already installed; skipping..."
endif

tools: tools-stamp
tools-stamp: contract-tools docs-tools statik runsim
	# Create dummy file to satisfy dependency and avoid
	# rebuilding when this Makefile target is hit twice
	# in a row.
	touch $@

tools-clean:
	rm -f $(RUNSIM)
	rm -f tools-stamp

.PHONY: runsim statik tools contract-tools tools-stamp tools-clean

go.sum: go.mod
	echo "Ensure dependencies have not been modified ..." >&2
	go mod verify
	go mod tidy

vulncheck: $(BUILDDIR)/
	GOBIN=$(BUILDDIR) go install golang.org/x/vuln/cmd/govulncheck@latest
	$(BUILDDIR)/govulncheck ./...

###############################################################################
###                              Documentation                              ###
###############################################################################

update-swagger-docs: statik
	$(BINDIR)/statik -src=client/docs/swagger-ui -dest=client/docs -f -m
	@if [ -n "$(git status --porcelain)" ]; then \
        echo "\033[91mSwagger docs are out of sync!!!\033[0m";\
        exit 1;\
    else \
        echo "\033[92mSwagger docs are in sync\033[0m";\
    fi
.PHONY: update-swagger-docs

godocs:
	@echo "--> Wait a few seconds and visit http://localhost:6060/pkg/TangramLabs/tangram"
	godoc -http=:6060

###############################################################################
###                           Tests & Simulation                            ###
###############################################################################

test: test-unit
test-all: test-unit test-race
# For unit tests we don't want to execute the upgrade tests in tests/e2e but
# we want to include all unit tests in the subfolders (tests/e2e/*)
PACKAGES_UNIT=$(shell go list ./... | grep -v '/tests/e2e$$')
TEST_PACKAGES=./...
TEST_TARGETS := test-unit test-unit-cover test-race

# Test runs-specific rules. To add a new test target, just add
# a new rule, customise ARGS or TEST_PACKAGES ad libitum, and
# append the new rule to the TEST_TARGETS list.
test-unit: ARGS=-timeout=15m -race
test-unit: TEST_PACKAGES=$(PACKAGES_UNIT)

test-race: ARGS=-race
test-race: TEST_PACKAGES=$(PACKAGES_NOSIMULATION)
$(TEST_TARGETS): run-tests

test-unit-cover: ARGS=-timeout=15m -race -coverprofile=coverage.txt -covermode=atomic
test-unit-cover: TEST_PACKAGES=$(PACKAGES_UNIT)

test-upgrade:
	@if [ -z "$(TARGET_VERSION)" ]; then \
		echo "Building docker image from local codebase"; \
		make build-docker; \
	fi
	@mkdir -p ./build
	@rm -rf build/.tangramd
	@INITIAL_VERSION=$(INITIAL_VERSION) TARGET_VERSION=$(TARGET_VERSION) \
	E2E_SKIP_CLEANUP=$(E2E_SKIP_CLEANUP) MOUNT_PATH=$(MOUNT_PATH) CHAIN_ID=$(CHAIN_ID) \
	go test -v ./tests/e2e -run ^TestIntegrationTestSuite$

run-tests:
ifneq (,$(shell which tparse 2>/dev/null))
	go test -mod=readonly -json $(ARGS) $(EXTRA_ARGS) $(TEST_PACKAGES) | tparse
else
	go test -mod=readonly $(ARGS)  $(EXTRA_ARGS) $(TEST_PACKAGES)
endif

test-import:
	@go test ./tests/importer -v --vet=off --run=TestImportBlocks --datadir tmp \
	--blockchain blockchain
	rm -rf tests/importer/tmp

test-rpc:
	./scripts/integration-test-all.sh -t "rpc" -q 1 -z 1 -s 2 -m "rpc" -r "true"

test-rpc-pending:
	./scripts/integration-test-all.sh -t "pending" -q 1 -z 1 -s 2 -m "pending" -r "true"

.PHONY: run-tests test test-all test-import test-rpc $(TEST_TARGETS)

benchmark:
	@go test -mod=readonly -bench=. $(PACKAGES_NOSIMULATION)
.PHONY: benchmark

###############################################################################
###                                Linting                                  ###
###############################################################################

lint:
	golangci-lint run --out-format=tab
	solhint contracts/**/*.sol

lint-contracts:
	@cd contracts && \
	npm i && \
	npm run lint

lint-fix:
	golangci-lint run --fix --out-format=tab --issues-exit-code=0

lint-fix-contracts:
	@cd contracts && \
	npm i && \
	npm run lint-fix
	solhint --fix contracts/**/*.sol

.PHONY: lint lint-fix

format:
	find . -name '*.go' -type f -not -path "./vendor*" -not -path "*.git*" -not -path "./client/docs/statik/statik.go" -not -name '*.pb.go' | xargs gofumpt -w -l

.PHONY: format

###############################################################################
###                                Localnet                                 ###
###############################################################################

# Build image for a local testnet
localnet-build:
	@$(MAKE) -C networks/local

# Start a 4-node testnet locally
localnet-start: localnet-stop localnet-build
	@if ! [ -f build/node0/$(TANGRAM_BINARY)/config/genesis.json ]; then docker run --rm -v $(CURDIR)/build:/tangram:Z tangram/node "./tangramd testnet init-files --v 4 -o /tangram --keyring-backend=test --starting-ip-address 192.167.10.2"; fi
	docker-compose up -d

# Stop testnet
localnet-stop:
	docker-compose down

# Clean testnet
localnet-clean:
	docker-compose down
	sudo rm -rf build/*

 # Reset testnet
localnet-unsafe-reset:
	docker-compose down
ifeq ($(OS),Windows_NT)
	@docker run --rm -v $(CURDIR)\build\node0\tangramd:/tangram\Z tangram/node "./tangramd tendermint unsafe-reset-all --home=/tangram"
	@docker run --rm -v $(CURDIR)\build\node1\tangramd:/tangram\Z tangram/node "./tangramd tendermint unsafe-reset-all --home=/tangram"
	@docker run --rm -v $(CURDIR)\build\node2\tangramd:/tangram\Z tangram/node "./tangramd tendermint unsafe-reset-all --home=/tangram"
	@docker run --rm -v $(CURDIR)\build\node3\tangramd:/tangram\Z tangram/node "./tangramd tendermint unsafe-reset-all --home=/tangram"
else
	@docker run --rm -v $(CURDIR)/build/node0/tangramd:/tangram:Z tangram/node "./tangramd tendermint unsafe-reset-all --home=/tangram"
	@docker run --rm -v $(CURDIR)/build/node1/tangramd:/tangram:Z tangram/node "./tangramd tendermint unsafe-reset-all --home=/tangram"
	@docker run --rm -v $(CURDIR)/build/node2/tangramd:/tangram:Z tangram/node "./tangramd tendermint unsafe-reset-all --home=/tangram"
	@docker run --rm -v $(CURDIR)/build/node3/tangramd:/tangram:Z tangram/node "./tangramd tendermint unsafe-reset-all --home=/tangram"
endif

# Clean testnet
localnet-show-logstream:
	docker-compose logs --tail=1000 -f

.PHONY: localnet-build localnet-start localnet-stop

###############################################################################
###                                Releasing                                ###
###############################################################################

PACKAGE_NAME:=github.com/TangramLabs/tangram
GOLANG_CROSS_VERSION  = v1.20

release:
	@if [ ! -f ".release-env" ]; then \
		echo "\033[91m.release-env is required for release\033[0m";\
		exit 1;\
	fi
	docker run \
		--rm \
		--privileged \
		-e CGO_ENABLED=1 \
		--env-file .release-env \
		-v /var/run/docker.sock:/var/run/docker.sock \
		-v `pwd`:/go/src/$(PACKAGE_NAME) \
		-w /go/src/$(PACKAGE_NAME) \
		ghcr.io/goreleaser/goreleaser-cross:${GOLANG_CROSS_VERSION} \
		release --clean --skip-validate

.PHONY: release