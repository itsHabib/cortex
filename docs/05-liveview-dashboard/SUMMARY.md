# Phase 5: LiveView Dashboard — Summary

> 380 tests, 0 failures. Cortex now has a web UI.

## What Was Built

Phase 5 converts Cortex from a headless CLI tool into a Phoenix web app with a real-time dashboard. You can now watch orchestration runs execute in a browser.

### Phoenix + Ecto Infrastructure

**What changed:** The plain Mix project became a full Phoenix app.

- **Phoenix endpoint** — web server on port 4000
- **LiveView** — real-time UI without writing JavaScript. Pages update automatically via WebSocket.
- **Ecto + SQLite** — database for persisting run history, team results, and events
- **EventSink** — a background process that listens to all PubSub events and saves them to the database

**New dependencies:** Phoenix, LiveView, Ecto, SQLite3, Tailwind CSS, Plug/Cowboy.

### Database Schema

Three tables:

- **runs** — each orchestration run (name, status, cost, duration, config YAML)
- **team_runs** — each team within a run (status, cost, result summary, prompt, log path)
- **event_logs** — every event that happened (agent started/stopped, tier completed, etc.)

### The Pages

#### Dashboard (`/`)
The landing page. Shows:
- Stat cards: total runs, active runs, total cost
- Recent runs (last 10) with status badges
- Quick-start button to launch a new run
- Updates in real-time via PubSub

#### Run List (`/runs`)
All historical runs in a sortable, filterable table:
- Sort by name, status, cost, duration
- Filter by status (all, running, completed, failed)
- Pagination (20 per page)
- Click any row to see run details

#### Run Detail (`/runs/:id`) — The Main Event
This is the most important page. It shows:

**DAG Visualization (SVG):**
- Teams rendered as colored rectangles arranged by tier (left to right)
- Dependencies shown as connecting lines/arrows
- Color-coded: gray=pending, blue=running, green=done, red=failed
- Updates in real-time as teams complete

**Team Cards** below the DAG:
- Each team shows name, role, status, cost, duration
- Click to see full details

#### Team Detail (`/runs/:id/teams/:name`)
Deep-dive into a specific team's execution:
- **Result tab** — what the team accomplished (summary text)
- **Log tab** — raw `claude -p` output (monospace, scrollable)
- **Config tab** — the team's section from orchestra.yaml
- **Prompt tab** — the exact prompt that was sent to Claude

#### New Run (`/new`)
Launch a new orchestration:
- Paste orchestra.yaml content in a textarea (or enter a file path)
- Click "Validate" — shows errors and warnings
- If valid, shows a preview: project name, teams, DAG visualization
- Click "Launch" — creates the run, starts execution, redirects to run detail

### How to Try It

```bash
cd cortex
mix deps.get
mix ecto.create
mix ecto.migrate
mix phx.server

# Open http://localhost:4000 in your browser
```

### What's Real-Time

LiveView connects to the server via WebSocket. When an orchestration is running:
- The dashboard updates as new runs appear
- The run detail page updates team colors in the DAG as they complete
- Cost and duration numbers update as teams finish
- No page refreshes needed — it just happens

### Design Choices

- **Tailwind CDN** — using the CDN for simplicity. A production build would use the bundled Tailwind.
- **Dark theme** — dark gray backgrounds with light text. Matches the terminal-native feel of the tool.
- **Minimal JavaScript** — LiveView handles all interactivity server-side. Zero custom JS.
- **SQLite** — perfect for a local-first tool. No database server to manage. Just a file.
