.PHONY: setup test check lint run server up down clean status proto proto-lint proto-breaking proto-check test-integration test-elixir-all e2e-local e2e-docker-simple e2e-docker-multi e2e-docker-simple-claude e2e-docker-multi-claude docker-integration e2e-shell e2e-elixir sidecar-build worker-build sidecar-test sidecar-lint sidecar-check docker-combo docker-combo-claude

# -- Development --

setup: ## Install deps, create DB, run migrations
	mix deps.get && mix ecto.create && mix ecto.migrate

test: ## Run all tests
	mix test

check: ## Full CI check: format + compile warnings + credo + tests
	mix format --check-formatted && \
	mix compile --warnings-as-errors && \
	mix credo --strict && \
	mix test

lint: ## Run Credo (strict) + Dialyzer
	mix credo --strict && mix dialyzer

fmt: ## Auto-format all files
	mix format

server: ## Start Phoenix server on port 4000
	mix phx.server

# -- Running Orchestrations --

run: ## Run a project config: make run CONFIG=path/to/orchestra.yaml
	@if [ -z "$(CONFIG)" ]; then echo "Usage: make run CONFIG=path/to/config.yaml"; exit 1; fi
	mix cortex.run $(CONFIG)

dry-run: ## Dry run (validate + show plan): make dry-run CONFIG=path/to/orchestra.yaml
	@if [ -z "$(CONFIG)" ]; then echo "Usage: make dry-run CONFIG=path/to/config.yaml"; exit 1; fi
	mix cortex.run $(CONFIG) --dry-run

# -- Observability Stack --

up: ## Start everything: Phoenix + Prometheus + Grafana
	@echo "Starting Prometheus + Grafana..."
	cd infra && docker compose up -d
	@echo ""
	@echo "Starting Cortex Phoenix server..."
	mix phx.server &
	@echo ""
	@echo "=== Everything is up ==="
	@echo "  Cortex UI:       http://localhost:4000"
	@echo "  LiveDashboard:   http://localhost:4000/dev/dashboard"
	@echo "  Health (live):   http://localhost:4000/health/live"
	@echo "  Health (ready):  http://localhost:4000/health/ready"
	@echo "  Prometheus:      http://localhost:4000/metrics"
	@echo "  Prometheus UI:   http://localhost:9090"
	@echo "  Grafana:         http://localhost:3000  (admin / cortex)"

infra-up: ## Start only Prometheus + Grafana (no Phoenix)
	cd infra && docker compose up -d
	@echo "Prometheus: http://localhost:9090"
	@echo "Grafana:    http://localhost:3000  (admin / cortex)"

down: ## Stop Prometheus + Grafana
	cd infra && docker compose down

infra-clean: ## Stop and remove all infra data (volumes)
	cd infra && docker compose down -v

# -- Health & Metrics --

health: ## Check system health
	@curl -s http://localhost:4000/health/ready | python3 -m json.tool 2>/dev/null || echo "Cortex not running. Start with: make server"

metrics: ## Dump raw Prometheus metrics
	@curl -s http://localhost:4000/metrics || echo "Cortex not running. Start with: make server"

status: ## Show run status from the DB
	@curl -s http://localhost:4000/api/runs | python3 -m json.tool 2>/dev/null || echo "Cortex not running. Start with: make server"

# -- Database --

db-reset: ## Drop and recreate the database
	mix ecto.reset

db-migrate: ## Run pending migrations
	mix ecto.migrate

# -- Proto / Code Generation --

proto: proto-lint proto-go ## Regenerate all proto stubs (Go + Elixir)
	@echo "Proto stubs regenerated. Elixir stubs are hand-maintained at lib/cortex/gateway/proto/"

proto-go: ## Generate Go gRPC stubs from proto
	protoc \
		--proto_path=proto \
		--go_out=sidecar/internal/proto/gatewayv1 \
		--go_opt=paths=source_relative \
		--go-grpc_out=sidecar/internal/proto/gatewayv1 \
		--go-grpc_opt=paths=source_relative \
		proto/cortex/gateway/v1/gateway.proto
	mv sidecar/internal/proto/gatewayv1/cortex/gateway/v1/gateway.pb.go sidecar/internal/proto/gatewayv1/
	mv sidecar/internal/proto/gatewayv1/cortex/gateway/v1/gateway_grpc.pb.go sidecar/internal/proto/gatewayv1/
	rm -rf sidecar/internal/proto/gatewayv1/cortex
	cd sidecar && go build ./internal/proto/...

proto-lint: ## Lint proto files (requires buf)
	@if command -v buf >/dev/null 2>&1; then \
		cd proto && buf lint; \
	else \
		echo "buf not installed — skipping lint (install: brew install bufbuild/buf/buf)"; \
		protoc --proto_path=proto --descriptor_set_out=/dev/null proto/cortex/gateway/v1/gateway.proto; \
	fi

proto-breaking: ## Check for wire-breaking changes vs main (requires buf)
	@if command -v buf >/dev/null 2>&1; then \
		cd proto && buf breaking --against '.git#branch=main'; \
	else \
		echo "buf not installed — skipping breaking change check"; \
	fi

proto-check: proto ## CI: regenerate stubs and verify no diff
	git diff --exit-code sidecar/internal/proto/ lib/cortex/gateway/proto/

# -- Testing --
#
# Test levels (see docs/testing.md for details):
#
#   Unit              — mocked, no external deps
#   Integration       — Docker API, gRPC, real processes (no Claude)
#   E2E               — full pipeline, mock agent by default, USE_CLAUDE=1 for real
#
# Quick reference:
#   make test                   Unit tests only (fast, CI default)
#   make test-elixir-all        All Elixir tests including integration + e2e tags
#   make sidecar-test           Go sidecar unit tests
#   make docker-integration     Docker API lifecycle (8 tests, no Cortex)
#   make e2e-docker-simple      Docker: single-team DAG (mock agent)
#   make e2e-docker-multi       Docker: 3-team multi-tier DAG (mock agent)
#   make e2e-docker-simple-claude  Docker: single-team DAG, real Claude
#   make e2e-docker-multi-claude   Docker: 3-team DAG, real Claude
#   make e2e-local              Local processes end-to-end (mock agent)

# --- Unit ---

test-integration: ## Elixir: only @tag :integration tests
	mix test --only integration

test-elixir-all: ## Elixir: ALL tests including integration + e2e tags
	mix test --include integration --include e2e

sidecar-test: ## Go: sidecar unit tests
	cd sidecar && make test

# --- Integration (no Claude, no API key) ---

docker-integration: ## Docker API lifecycle: container CRUD, networks, labels, logs
	cd e2e && go test -v -run "^TestDocker[^D]" -timeout 120s

e2e-elixir: ## Elixir-side ExternalAgent pipeline (mock sidecar, no containers)
	mix test test/e2e/ --include e2e

e2e-shell: ## Shell-based sidecar ↔ gRPC ↔ gateway protocol test
	./test/e2e/sidecar_e2e_test.sh

# --- E2E ---

e2e-local: sidecar-build worker-build ## Local processes: Cortex + sidecar + worker (mock agent)
	cd e2e && go test -v -run TestExternalAgentE2E -timeout 300s

e2e-docker-simple: sidecar-build worker-build ## Docker: single-team DAG (mock agent)
	cd e2e && go test -v -run TestDockerDAGSimple -timeout 300s

e2e-docker-multi: sidecar-build worker-build ## Docker: 3-team multi-tier DAG (mock agent)
	cd e2e && go test -v -run TestDockerDAGMultiTeam -timeout 300s

e2e-docker-simple-claude: docker-combo-claude sidecar-build worker-build ## Docker: single-team DAG, real Claude
	cd e2e && USE_CLAUDE=1 go test -v -run TestDockerDAGSimple -timeout 300s

e2e-docker-multi-claude: docker-combo-claude sidecar-build worker-build ## Docker: 3-team DAG, real Claude
	cd e2e && USE_CLAUDE=1 go test -v -run TestDockerDAGMultiTeam -timeout 300s

# --- Builds ---

sidecar-build: ## Build the Go sidecar binary
	cd sidecar && make build

worker-build: ## Build the Go agent-worker binary
	cd sidecar && make worker-build

sidecar-lint: ## Lint sidecar Go code
	cd sidecar && make lint

sidecar-check: sidecar-lint sidecar-test sidecar-build ## Full sidecar CI: lint + test + build

docker-combo: ## Build cortex-agent-worker:latest (mock mode, no Claude CLI)
	cd sidecar && docker build -t cortex-agent-worker:latest -f Dockerfile.combo .

docker-combo-claude: ## Build cortex-agent-worker:latest with Claude CLI
	cd sidecar && docker build -t cortex-agent-worker:latest -f Dockerfile.combo --build-arg INSTALL_CLAUDE=1 .

# -- Benchmarks --

bench: ## Run all benchmarks
	mix run bench/agent_bench.exs && \
	mix run bench/gossip_bench.exs && \
	mix run bench/dag_bench.exs

# -- Cleanup --

clean: ## Remove build artifacts
	rm -rf _build deps

help: ## Show this help
	@grep -E '^[a-zA-Z0-9_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-18s\033[0m %s\n", $$1, $$2}'

.DEFAULT_GOAL := help
