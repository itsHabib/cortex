# Prompt: Beef Up Sidecar & Worker Container Logs

## Context

When running `docker logs` on the sidecar or worker containers, the output is nearly empty. The worker logs ~5 lines total (start, sidecar healthy, received task, completed, submitted). The sidecar logs ~3 lines (start, HTTP server, shutdown). This makes it impossible to debug issues without shelling into the container.

The bigger problem: the Claude CLI NDJSON output (tool calls, assistant messages, token usage) is captured by the worker's `cmd.Output()` at `sidecar/cmd/agent-worker/main.go:184`, parsed for the result, then discarded. None of it reaches `docker logs` or the Cortex UI.

## Goals

1. **Worker: stream Claude NDJSON to stderr** so it appears in `docker logs`
2. **Worker: log lifecycle events** — polling status, task receipt details (prompt length, timeout), execution phases
3. **Sidecar: log gateway lifecycle** — gRPC connect/disconnect, registration success/failure, heartbeat sends, task dispatch/result relay
4. **Sidecar: log HTTP API calls** — request method, path, status code, duration (lightweight access log)

## Files to Change

### Worker (`sidecar/cmd/agent-worker/main.go`)

**Stream Claude output to stderr while collecting it:**

Currently (line 176-184):
```go
cmd := exec.Command(command, args...)
var stderrBuf bytes.Buffer
cmd.Stderr = io.MultiWriter(os.Stderr, &stderrBuf)
output, err := cmd.Output()
```

Change to use `cmd.StdoutPipe()` + `io.TeeReader` so each NDJSON line is:
1. Written to stderr (→ `docker logs`) with a `[claude]` prefix
2. Collected in a buffer for parsing

Something like:
```go
stdout, _ := cmd.StdoutPipe()
cmd.Stderr = io.MultiWriter(os.Stderr, &stderrBuf)
cmd.Start()

var outputBuf bytes.Buffer
scanner := bufio.NewScanner(io.TeeReader(stdout, &outputBuf))
for scanner.Scan() {
    line := scanner.Text()
    // Log a summary of each event (type, tool name, token delta) — NOT the full line
    logClaudeEvent(logger, line)
}
cmd.Wait()
```

**Add a `logClaudeEvent` helper** that parses the JSON type and logs a one-liner:
- `type: "assistant"` → log "assistant message" + tool names if present
- `type: "result"` → log "result received" + cost + tokens
- `type: "system"` → log "session started" + session_id
- Other types → log type name only

**Add more lifecycle logging:**
- Log poll attempt count / idle time when waiting
- Log prompt length and timeout when task received
- Log submit response details

### Sidecar — Gateway Client (`sidecar/internal/gateway/client.go`)

Add logging for:
- gRPC dial attempt + success/failure
- Registration request sent + response received (agent_id assigned)
- Heartbeat sent (every interval — use Debug level)
- Task request received from gateway
- Task result forwarded to gateway
- Stream errors / reconnection attempts
- Disconnect / shutdown

### Sidecar — HTTP API (`sidecar/internal/api/server.go` or `router.go`)

Add lightweight request logging middleware:
```go
func loggingMiddleware(logger *slog.Logger, next http.Handler) http.Handler {
    return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
        start := time.Now()
        // wrap ResponseWriter to capture status code
        next.ServeHTTP(w, r)
        logger.Info("http request", "method", r.Method, "path", r.URL.Path, "duration", time.Since(start))
    })
}
```

For the `/task` endpoint specifically, log when a task is dequeued vs when the queue is empty (at Debug level to avoid noise from polling).

## Log Level Guidelines

- `Info` — lifecycle events (start, connect, register, task received/completed, shutdown)
- `Warn` — retries, timeouts, unexpected states
- `Error` — failures (gRPC disconnect, submit failed, claude crashed)
- `Debug` — heartbeats, empty polls, full NDJSON lines (for verbose mode)

## What NOT to Do

- Don't log full NDJSON lines at Info level — too noisy. Log a one-line summary per event.
- Don't log the full prompt text — it can be huge. Log the length.
- Don't add a log file writer — `docker logs` (stderr) is the right output channel for containers.
- Don't change the result parsing logic or gRPC protocol — this is purely additive logging.

## Verification

After changes, running a Docker e2e test (`mix test test/e2e/` or manual) should produce meaningful output from `docker logs <worker>` and `docker logs <sidecar>` that shows the full lifecycle:

```
# docker logs cortex-...-worker
time=... level=INFO msg="agent-worker starting" sidecar_url=http://... poll_interval=500ms
time=... level=INFO msg="sidecar is healthy"
time=... level=INFO msg="received task" task_id=abc-123 prompt_len=1452 timeout_ms=1800000
time=... level=INFO msg="claude event" type=system session_id=sess-xyz
time=... level=INFO msg="claude event" type=assistant tools=["Read","Edit"]
time=... level=INFO msg="claude event" type=assistant tools=["Bash"]
time=... level=INFO msg="claude event" type=result cost_usd=0.034 tokens=2341
time=... level=INFO msg="claude completed" task_id=abc-123 duration=45.2s input_tokens=1800 output_tokens=541
time=... level=INFO msg="result submitted" task_id=abc-123 status=completed

# docker logs cortex-...-sidecar
time=... level=INFO msg="starting cortex sidecar" version=dev gateway_url=host.docker.internal:4001
time=... level=INFO msg="starting HTTP server" addr=0.0.0.0:9091
time=... level=INFO msg="gRPC connected" gateway=host.docker.internal:4001
time=... level=INFO msg="registered" agent_id=agt-789 name=backend
time=... level=INFO msg="task dispatched to worker" task_id=abc-123
time=... level=INFO msg="task result forwarded" task_id=abc-123 status=completed duration=45.2s
time=... level=INFO msg="shutdown signal received, draining..."
time=... level=INFO msg="sidecar stopped"
```

## Nice to Have: Volume-Mount Full Logs Back to Host

The summary logging above covers quick debugging via `docker logs`. For full NDJSON logs (identical to what the CLI provider writes), a future enhancement would mount the host log directory into the worker container so Claude CLI output is written directly to `.cortex/logs/<run_id>/<team_name>.log`.

**YAML config:**
```yaml
defaults:
  backend: docker
  docker:
    mount_logs: true   # default: false
```

**Elixir side (`lib/cortex/spawn_backend/docker.ex`):**

When `mount_logs: true`, add a bind mount to `build_worker_spec`:
```elixir
"HostConfig" => %{
  "NetworkMode" => network_name,
  "Binds" => ["#{host_log_dir}:/cortex-logs"]
}
```

And pass `CORTEX_LOG_PATH=/cortex-logs/<team_name>.log` as an env var.

**Worker side (`sidecar/cmd/agent-worker/main.go`):**

If `CORTEX_LOG_PATH` is set, open that file and use `io.MultiWriter` to tee Claude's stdout to both the parse buffer and the log file (raw NDJSON, not summaries). This makes the UI logs tab work for Docker runs the same way it does for local CLI runs.

This is additive — the stderr summary logging from the main goals should work independently of whether volume mounting is enabled.
