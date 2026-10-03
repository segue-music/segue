FROM golang:1.27 AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -trimpath -ldflags=-s -o /segue-hub ./cmd/segue-hub

# Just the binary, plus CA certificates for a media server reached over https.
FROM scratch
COPY --from=build /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/
COPY --from=build /segue-hub /segue-hub
USER 65532:65532
ENV SEGUE_LISTEN=0.0.0.0:8480
EXPOSE 8480
ENTRYPOINT ["/segue-hub"]
