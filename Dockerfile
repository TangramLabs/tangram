ARG GO_VERSION="1.20"
ARG GIT_VERSION
ARG GIT_COMMIT
ARG RUNNER_IMAGE="gcr.io/distroless/static-debian11"

FROM golang:${GO_VERSION}-alpine as builder

WORKDIR /tangram

RUN apk add --no-cache \
    ca-certificates \
    build-base \
    linux-headers

COPY . .

RUN --mount=type=cache,target=/root/.cache/go-build \
    --mount=type=cache,target=/root/go/pkg/mod \
    go mod download

# Build tangramd binary
RUN --mount=type=cache,target=/root/.cache/go-build \
    --mount=type=cache,target=/root/go/pkg/mod \
    GOWORK=off go build \
    -mod=readonly \
    -tags "netgo,ledger,muslc" \
    -ldflags \
    "-X github.com/cosmos/cosmos-sdk/version.Name="tangram" \
    -X github.com/cosmos/cosmos-sdk/version.AppName="tangramd" \
    -X github.com/cosmos/cosmos-sdk/version.Version=${GIT_VERSION} \
    -X github.com/cosmos/cosmos-sdk/version.Commit=${GIT_COMMIT} \
    -X github.com/cosmos/cosmos-sdk/version.BuildTags='netgo,ledger,muslc' \
    -w -s -linkmode=external -extldflags '-Wl,-z,muldefs -static'" \
    -trimpath \
    -o /tangram/build/tangramd \
    /tangram/cmd/tangramd/main.go


FROM ${RUNNER_IMAGE}

COPY --from=builder /tangram/build/tangramd /bin/tangramd

ENV HOME /tangram

WORKDIR $HOME

EXPOSE 26656 26657 1317 9090 8545 8546

ENTRYPOINT ["tangramd"]