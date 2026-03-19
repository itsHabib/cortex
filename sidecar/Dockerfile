# Stage 1: Build
FROM golang:1.22-alpine AS builder

WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -o /cortex-sidecar ./cmd/cortex-sidecar

# Stage 2: Runtime
FROM gcr.io/distroless/static-debian12

COPY --from=builder /cortex-sidecar /cortex-sidecar

EXPOSE 9090

ENTRYPOINT ["/cortex-sidecar"]
