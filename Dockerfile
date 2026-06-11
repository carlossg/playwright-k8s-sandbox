# Build stage
FROM golang:1.25 AS build
WORKDIR /src

# Download dependencies first for better layer caching
COPY go.mod go.sum ./
RUN go mod download && go mod verify

# Copy source and build
COPY . .
RUN CGO_ENABLED=0 GOOS=linux GOARCH=${TARGETARCH:-amd64} \
    go build -trimpath -ldflags='-s -w -extldflags "-static"' \
    -o /out/playwright-proxy ./cmd/playwright-proxy

# Runtime stage - use distroless for minimal attack surface
FROM gcr.io/distroless/static-debian12:nonroot

# Copy binary with appropriate permissions
COPY --from=build --chown=nonroot:nonroot /out/playwright-proxy /usr/local/bin/playwright-proxy

# Use non-root user (UID/GID 65532)
USER nonroot:nonroot

# Expose ports
EXPOSE 9000 9090

# Health check endpoint on management port
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD ["/usr/local/bin/playwright-proxy", "healthz"]

ENTRYPOINT ["/usr/local/bin/playwright-proxy"]
