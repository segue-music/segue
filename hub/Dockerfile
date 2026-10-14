# Built where the build runs, for the platform asked for (docker buildx --platform): Go cross-compiles, so an arm
# image needs no emulation.
FROM --platform=$BUILDPLATFORM golang:1.27 AS build
ARG TARGETOS TARGETARCH TARGETVARIANT
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH GOARM=${TARGETVARIANT#v} \
    go build -trimpath -ldflags=-s -o /segue-hub ./cmd/segue-hub
# The state's folder, made here, as scratch has no shell to make it.
RUN mkdir /data

# Just the binary, plus CA certificates for a media server reached over https, and the state's folder, which the
# hub's user owns: a volume mounted there takes it as its owner.
FROM scratch
COPY --from=build /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/
COPY --from=build /segue-hub /segue-hub
COPY --from=build --chown=65532:65532 /data /data
USER 65532:65532
ENV SEGUE_LISTEN=0.0.0.0:8480 SEGUE_STATE=/data/state.json
EXPOSE 8480
ENTRYPOINT ["/segue-hub"]
