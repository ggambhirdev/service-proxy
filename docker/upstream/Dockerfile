FROM golang:1.26 AS builder
WORKDIR /src
COPY go.mod ./
COPY cmd/echo-upstream ./cmd/echo-upstream
COPY internal ./internal
RUN CGO_ENABLED=0 go build -o /out/echo-upstream ./cmd/echo-upstream

FROM alpine:3.24
RUN apk add --no-cache wget
COPY --from=builder /out/echo-upstream /echo-upstream
EXPOSE 9000
ENTRYPOINT ["/echo-upstream"]
