# Battle-Tested Third-Party Libraries

Recommended libs for Cortex (Elixir) and the Go sidecar, organized by concern.

## Elixir / Phoenix

### Already Using
- **Phoenix** + **LiveView** — web framework + real-time UI
- **Ecto** + **SQLite** — database layer
- **GRPC** (elixir-grpc) — gRPC server for agent gateway
- **Credo** — static analysis / linting
- **Dialyzer** — type checking

### Recommended Additions

| Lib | Category | Why |
|-----|----------|-----|
| **[Oban](https://hex.pm/packages/oban)** | Job queue | Persistent async job processing (Postgres-backed). Replaces `Task.Supervisor` for API-triggered runs. Retries, scheduling, uniqueness, observability. The standard for async work in production Elixir. |
| **[Req](https://hex.pm/packages/req)** | HTTP client | Modern HTTP client by the Elixir core team. Cleaner than `:httpc`. Built on Finch for connection pooling. |
| **[Finch](https://hex.pm/packages/finch)** | HTTP connection pool | High-performance HTTP client with connection pooling. Used by Req under the hood. Good for outbound API calls. |
| **[Horde](https://hex.pm/packages/horde)** | Distributed supervisor | Distributed DynamicSupervisor + Registry across BEAM nodes. Drop-in replacement for local versions. Key for the dist-control-plane track. |
| **[Libcluster](https://hex.pm/packages/libcluster)** | Node discovery | Automatic Erlang node clustering (DNS, K8s, gossip strategies). Also for dist-control-plane. |
| **[Tesla](https://hex.pm/packages/tesla)** | HTTP client (alt) | Middleware-based HTTP client. Good if you want pluggable adapters (Finch, Hackney, etc.). |
| **[OpenTelemetry](https://hex.pm/packages/opentelemetry)** | Observability | Distributed tracing standard. Integrates with `:telemetry` events already in Cortex. Export to Jaeger, Honeycomb, Datadog. |
| **[ExPrometheus](https://hex.pm/packages/prom_ex)** | Metrics | Prometheus metrics with auto-instrumented Phoenix, Ecto, BEAM dashboards. Grafana dashboard auto-provisioning. |
| **[Bandit](https://hex.pm/packages/bandit)** | HTTP server | Modern HTTP server for Phoenix (replaces Cowboy). Better HTTP/2, WebSocket, and resource usage. Phoenix 1.8+ default. |
| **[Cachex](https://hex.pm/packages/cachex)** | Caching | In-memory cache with TTL, limits, stats. Good for Gateway.Registry query caching if needed. |

### For Testing

| Lib | Category | Why |
|-----|----------|-----|
| **[Mox](https://hex.pm/packages/mox)** | Mocking | Behaviour-based mocks by Jose Valim. Concurrent-safe, explicit. |
| **[StreamData](https://hex.pm/packages/stream_data)** | Property testing | Property-based / fuzz testing. Good for adversarial edge case discovery. |
| **[Mimic](https://hex.pm/packages/mimic)** | Mocking (alt) | Global mock that doesn't require behaviours. Easier for legacy code. |

---

## Go Sidecar

### Already Using
- **gRPC** (google.golang.org/grpc) — bidirectional streaming to gateway
- **chi** (go-chi/chi) — HTTP router
- **envconfig** (kelseyhightower/envconfig) — environment config
- **protobuf** (google.golang.org/protobuf) — proto serialization

### Recommended Additions

| Lib | Category | Why |
|-----|----------|-----|
| **[slog](https://pkg.go.dev/log/slog)** | Logging | Already using. Standard structured logging (Go 1.21+). |
| **[otelgrpc](https://pkg.go.dev/go.opentelemetry.io/contrib/instrumentation/google.golang.org/grpc/otelgrpc)** | Tracing | OpenTelemetry interceptors for gRPC. Auto-traces every RPC call. |
| **[otelhttp](https://pkg.go.dev/go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp)** | Tracing | OpenTelemetry middleware for HTTP handlers. |
| **[prometheus/client_golang](https://pkg.go.dev/github.com/prometheus/client_golang)** | Metrics | Prometheus metrics. Expose `/metrics` endpoint for scraping. |
| **[testify](https://pkg.go.dev/github.com/stretchr/testify)** | Testing | Assertions + mocks + suites. The Go testing standard. |
| **[goleak](https://pkg.go.dev/go.uber.org/goleak)** | Testing | Detects goroutine leaks in tests. |
| **[retry-go](https://pkg.go.dev/github.com/avast/retry-go/v4)** | Resilience | Retry with backoff, jitter. Good for reconnection logic. |
| **[afero](https://pkg.go.dev/github.com/spf13/afero)** | Filesystem | Abstract filesystem for testing (in-memory FS). |
| **[zerolog](https://pkg.go.dev/github.com/rs/zerolog)** | Logging (alt) | Zero-allocation structured logging. Faster than slog for high-throughput. |

### For Production Hardening

| Lib | Category | Why |
|-----|----------|-----|
| **[grpc-health](https://pkg.go.dev/google.golang.org/grpc/health)** | Health check | Standard gRPC health check protocol. K8s readiness/liveness probes. |
| **[pprof](https://pkg.go.dev/net/http/pprof)** | Profiling | Built-in Go profiler. Add `import _ "net/http/pprof"` for on-demand profiling. |
| **[golangci-lint](https://golangci-lint.run/)** | Linting | Meta-linter running 50+ linters. CI standard. |
