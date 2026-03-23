# Testing Levels

## Definitions

| Level | Real Claude? | Real infra? | What it proves |
|-------|-------------|-------------|----------------|
| **Unit** | No | No | Logic correctness with mocks |
| **Integration** | No | Yes (Docker, gRPC, processes) | Infrastructure works, plumbing connects |
| **E2E / Smoke** | **Yes** | Yes | A real agent completes real work end-to-end |

"E2E" means a real Claude agent receives a task, does work, and returns a result
through the full pipeline. If there's no real agent at the end, it's integration.

## Make Targets

### Unit tests

```bash
mix test                    # All Elixir unit tests (mocked, no external deps)
make sidecar-test           # Go sidecar unit tests
```

### Integration tests

```bash
make docker-integration     # Docker API lifecycle: container CRUD, networks, labels, logs
make e2e-shell              # Sidecar <-> gRPC <-> Gateway protocol
make e2e-elixir             # Elixir-side ExternalAgent pipeline (mock sidecar)
```

### E2E / Smoke tests

```bash
make e2e                    # Local processes: Cortex + sidecar + worker + real Claude
make e2e-docker-dag         # Docker containers: Cortex spawns containers, real Claude
```

Both e2e targets use `USE_CLAUDE=1` to enable real Claude. Without it, a mock
script stands in (useful for CI where no API key is available, but this makes
the test an integration test, not a true e2e).

## What each e2e target exercises

### `make e2e` (local processes)

```
Cortex (mix phx.server)
  -> Executor sees provider: external, backend: local
  -> ExternalSpawner forks sidecar + worker as OS processes
  -> Sidecar registers with Gateway via gRPC
  -> Worker polls sidecar, gets task, runs claude -p
  -> Result flows: worker -> sidecar -> Gateway -> Cortex
  -> Run completes
```

### `make e2e-docker-dag` (Docker containers)

```
Cortex (mix phx.server)
  -> Executor sees provider: external, backend: docker
  -> SpawnBackend.Docker creates network + sidecar + worker containers
  -> Sidecar registers with Gateway via gRPC
  -> Worker polls sidecar, gets task, runs claude -p (inside container)
  -> Result flows: worker -> sidecar -> Gateway -> Cortex
  -> Executor calls stop -> containers + network removed
  -> Run completes
```

## Known gaps

- **K8s e2e**: No e2e test yet for `backend: k8s`. Needs `kind` or `minikube`.
- **Multi-team Docker e2e**: The `TestDockerDAGMultiTeam` test exists but hasn't
  been validated with real Claude in containers yet.
- **Result delivery race**: When Docker containers respond very fast (< 1s),
  there's a race between the executor cleaning up the pending task and the
  gRPC result arriving. Tracked as a known bug.
