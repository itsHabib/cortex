.PHONY: setup test check run server up down clean status

# -- Development --

setup: ## Install deps, create DB, run migrations
	mix deps.get && mix ecto.create && mix ecto.migrate

test: ## Run all tests
	mix test

check: ## Full CI check: format + compile warnings + tests
	mix format --check-formatted && \
	mix compile --warnings-as-errors && \
	mix test

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

# -- Benchmarks --

bench: ## Run all benchmarks
	mix run bench/agent_bench.exs && \
	mix run bench/gossip_bench.exs && \
	mix run bench/dag_bench.exs

# -- Cleanup --

clean: ## Remove build artifacts
	rm -rf _build deps

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-15s\033[0m %s\n", $$1, $$2}'

.DEFAULT_GOAL := help
