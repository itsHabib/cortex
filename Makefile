.PHONY: setup test check lint run server up down clean status proto proto-lint proto-breaking proto-check test-integration test-all e2e e2e-shell e2e-elixir sidecar-build sidecar-test sidecar-lint sidecar-check

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

# -- Integration & E2E Tests --

test-integration: ## Run only @tag :integration tests (requires real claude CLI)
	mix test --only integration

test-all: ## Run ALL tests including integration (requires real claude CLI)
	mix test --include integration

e2e: sidecar-build ## Run full e2e: start Cortex, run Go sidecar test, clean up
	@echo "Starting Cortex server..."
	@CORTEX_GATEWAY_TOKEN=e2e-test-token mix phx.server &>/dev/null & \
		CORTEX_PID=$$!; \
		cleanup() { kill $$CORTEX_PID 2>/dev/null; wait $$CORTEX_PID 2>/dev/null; }; \
		trap cleanup EXIT; \
		echo "Waiting for Cortex to start..."; \
		for i in $$(seq 1 30); do \
			curl -sf http://localhost:4000/api/runs?limit=1 >/dev/null 2>&1 && break; \
			sleep 1; \
		done; \
		if ! curl -sf http://localhost:4000/api/runs?limit=1 >/dev/null 2>&1; then \
			echo "ERROR: Cortex did not start within 30s"; \
			exit 1; \
		fi; \
		echo "Cortex is up. Running e2e tests..."; \
		cd e2e && go test -v -timeout 90s; \
		EXIT_CODE=$$?; \
		echo "Cleaning up..."; \
		exit $$EXIT_CODE

e2e-shell: ## Run shell-based e2e sidecar ↔ gRPC ↔ gateway test
	./test/e2e/sidecar_e2e_test.sh

e2e-elixir: ## Run Elixir e2e test (WIP, requires ports 4011/9091 free)
	mix test test/e2e/ --include e2e

# -- Sidecar (Go) --

sidecar-build: ## Build the Go sidecar binary
	cd sidecar && make build

sidecar-test: ## Run sidecar Go tests
	cd sidecar && make test

sidecar-lint: ## Lint sidecar Go code
	cd sidecar && make lint

sidecar-check: sidecar-lint sidecar-test sidecar-build ## Full sidecar CI: lint + test + build

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
