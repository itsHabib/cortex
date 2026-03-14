# Cortex

## Quick Start
```bash
mix deps.get && mix ecto.create && mix ecto.migrate && mix test
```

## Architecture
- Agent GenServer: lib/cortex/agent/
- Orchestration: lib/cortex/orchestration/
- Gossip: lib/cortex/gossip/
- Web: lib/cortex_web/
- Store: lib/cortex/store/
- Telemetry: lib/cortex/telemetry.ex
- Performance: lib/cortex/perf/

## Coding Style
- @moduledoc, @doc, @spec on all public functions
- defstruct with @enforce_keys for required fields
- Pattern match in function heads
- Return {:ok, value} | {:error, reason} from fallible functions
- Tests mirror lib/ structure, use async: true where safe

## Commands
```bash
mix test                           # run all tests
mix test --trace                   # verbose
mix test test/cortex/agent/        # specific dir
mix compile --warnings-as-errors   # CI compile check
mix format --check-formatted       # CI format check
mix phx.server                     # start web server (port 4000)
mix run bench/agent_bench.exs      # agent benchmarks
mix run bench/gossip_bench.exs     # gossip benchmarks
mix run bench/dag_bench.exs        # DAG benchmarks
```

## Before You Commit
1. mix format
2. mix compile --warnings-as-errors
3. mix test (all pass)
4. No IO.inspect or dbg() left in code
