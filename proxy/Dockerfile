FROM golang:1.25 AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags='-s -w' \
    -o /out/playwright-proxy ./cmd/playwright-proxy

FROM gcr.io/distroless/static:nonroot
COPY --from=build /out/playwright-proxy /usr/local/bin/playwright-proxy
USER nonroot
EXPOSE 9000 9090
ENTRYPOINT ["/usr/local/bin/playwright-proxy"]
