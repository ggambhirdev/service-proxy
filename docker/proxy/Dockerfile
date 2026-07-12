FROM golang:1.26 AS builder
WORKDIR /src
COPY go.mod go.sum* ./
RUN go mod download 2>/dev/null || true
COPY cmd/proxy ./cmd/proxy
COPY internal ./internal
RUN CGO_ENABLED=0 go build -o /out/proxy ./cmd/proxy

FROM alpine:3.24
COPY --from=builder /out/proxy /proxy
EXPOSE 8080
ENTRYPOINT ["/proxy"]
