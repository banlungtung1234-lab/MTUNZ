# Build a small static Linux binary for the remote signaling service.
FROM golang:1.27.3-alpine AS build
WORKDIR /src
COPY . .
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -ldflags="-s -w" -o /out/mtunz-signaling .

# The service is intentionally non-root and has a read-only runtime filesystem.
FROM alpine:3.24
RUN apk add --no-cache ca-certificates \
    && addgroup -S -g 10001 mtunz \
    && adduser -S -D -H -u 10001 -G mtunz mtunz
COPY --from=build --chown=10001:10001 /out/mtunz-signaling /usr/local/bin/mtunz-signaling
USER 10001:10001
ENV MTUNZ_ADDR=:8787
EXPOSE 8787
HEALTHCHECK --interval=30s --timeout=4s --start-period=5s --retries=3 \
  CMD wget -q -T 3 -O /dev/null http://127.0.0.1:8787/healthz || exit 1
ENTRYPOINT ["/usr/local/bin/mtunz-signaling"]
