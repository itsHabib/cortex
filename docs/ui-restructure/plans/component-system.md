# Component System Plan — Component Architect

## You are in PLAN MODE.

### Project
I want to do a **UI restructure of the Cortex web layer**.

**Goal:** build a **shared component system** in which we **replace duplicated inline rendering across 10 LiveViews with composable, tested, reusable HEEx function components** — enabling the 4-page navigation redesign (Overview, Agents, Workflows, Runs) without each page re-inventing cards, badges, feeds, and topology graphs.

### Role + Scope
- **Role:** Component Architect
- **Scope:** Design the shared component modules that the restructured pages will consume. I own the component API contracts, composition patterns, and module organization. I do NOT own page-level LiveViews, routing, information architecture, or backend changes.
- **File you will write:** `/docs/ui-restructure/plans/component-system.md`
- **No-touch zones:** do not edit any other files; do not write code.

---

## Functional Requirements
- **FR1:** Agent card component with grid, list, and compact display modes — used in Agents page, Workflow agent picker, and Run team list.
- **FR2:** Mode selector component — DAG/Mesh/Gossip picker with visual mode indicators and inline config panel slot.
- **FR3:** Topology visualizer — generalized SVG renderer supporting DAG (tiered left-to-right), Mesh (radial full-mesh), and Gossip (radial with configurable topology strategy). Interactive node selection with click events.
- **FR4:** Unified status badge system — single component covering agent status, run status, team status, mesh member state, and gateway agent status with consistent color coding.
- **FR5:** Activity feed component — timestamped event stream with icon/color coding, max-height scroll, and optional team/source filtering.
- **FR6:** Log viewer component — sortable (asc/desc), expandable entries, team selector, max-line cap, monospace rendering.
- **FR7:** Token/cost display components — review and unify existing `token_display`, `token_detail`, and inline token rendering (mesh/gossip) into a consistent set.
- **Tests required:** Unit tests for each component module using `Phoenix.LiveViewTest` — render snapshots, attribute validation, slot rendering.
- **Metrics required:** N/A — no Prometheus for UI components at MVP.

## Non-Functional Requirements
- Language/runtime: Elixir/Phoenix LiveView, HEEx function components, Tailwind CSS (dark mode)
- Local dev: `mix phx.server` — no additional setup
- Observability: N/A for UI components
- Safety: Components must escape user-provided strings by default (HEEx handles this). No `raw/1` without explicit sanitization.
- Documentation: `@moduledoc`, `@doc`, `@spec` on all public components. `attr` and `slot` declarations for every component (Phoenix standard).
- Performance: Components should avoid re-computing layout on every render; use assigns efficiently so LiveView diffing works. Topology SVGs should handle up to 50 nodes without jank.

---

## Assumptions / System Model
- Deployment environment: local dev via `mix phx.server`; components are purely web-layer and deployment-agnostic.
- Failure modes: Components receive `nil` or empty data — all components must render a sensible empty/placeholder state rather than crashing.
- Delivery guarantees: N/A — components are stateless render functions.
- Multi-tenancy: N/A for MVP.

---

## Data Model (as relevant to this role)

Components do not define persistence schemas. They consume data passed as assigns. The key data shapes components must handle:

- **Agent (for agent card)**
  - name (string), role (string | nil), capabilities (list of strings), status (atom: :idle, :working, :draining, :disconnected), transport (atom: :grpc, :websocket | nil), last_heartbeat (DateTime | nil), registered_at (DateTime | nil), id (string)
  - Validation: name is required; all other fields have safe defaults.

- **Status (unified)**
  - Covers: run status strings ("pending", "running", "completed", "failed", "stopped", "stalled"), mesh member states (:alive, :suspect, :dead, :left), gossip node status (:online, :converged, :offline), gateway agent status (:idle, :working, :draining, :disconnected)
  - Strategy: Accept both strings and atoms; normalize internally.

- **Activity entry**
  - type (atom), name (string), detail (string | nil), timestamp (DateTime)

- **Log entry**
  - id (string), timestamp (DateTime | nil), source (string), level (atom | string), content (string), raw (string | nil)

- **Topology node**
  - name (string), x (integer), y (integer), state/status (atom), selected (boolean)

- **Topology edge**
  - from (string), to (string), highlighted (boolean)

Versioning: N/A — component APIs will use Phoenix's `attr` declarations, which provide compile-time validation.

---

## APIs (as relevant to this role)

Components expose HEEx function component APIs. Each component is a public function in its module, called via `<.component_name attr={value} />` syntax.

### `CortexWeb.Components.AgentComponents`

```
<.agent_card agent={agent} mode={:grid | :list | :compact} on_click={handler} />
<.agent_grid agents={agents} on_select={handler} />
<.agent_list agents={agents} on_select={handler} selected={name} />
```

- `agent_card`: Renders a single agent with name, role, capabilities, status badge, transport badge. `mode` controls layout density.
- `agent_grid`: Wraps multiple `agent_card` in responsive CSS grid (grid mode).
- `agent_list`: Table layout with sortable columns.

### `CortexWeb.Components.StatusComponents`

```
<.status_badge status={status} />
<.status_dot status={status} pulse={true | false} />
<.transport_badge transport={:grpc | :websocket} />
<.mode_badge mode={"dag" | "mesh" | "gossip"} />
```

- `status_badge`: Replaces the current `CoreComponents.status_badge/1` plus all the inline `state_badge_class`, `gateway_status_badge_class`, `agent_status_badge_class` scattered across LiveViews. Accepts both string and atom status values. Single color mapping function.
- `status_dot`: Small colored circle (alive indicator), with optional pulse animation.
- `transport_badge`: gRPC/WebSocket transport indicator.
- `mode_badge`: Coordination mode pill (DAG/Mesh/Gossip).

### `CortexWeb.Components.TopologyComponents`

```
<.topology_graph nodes={nodes} edges={edges} on_node_click={handler} selected={name} variant={:radial | :dag} />
<.topology_legend items={[%{label: "alive", color: "blue"}, ...]} />
```

- `topology_graph`: Unified SVG topology renderer. `:radial` variant (for Mesh/Gossip circular layout), `:dag` variant (for DAG tiered left-to-right layout). Node positions can be pre-computed or auto-calculated from topology data.
- `topology_legend`: Status color legend strip, configurable items.

### `CortexWeb.Components.FeedComponents`

```
<.activity_feed activities={activities} max={50} />
<.activity_entry entry={entry} />
```

- `activity_feed`: Scrollable timestamped event list with icon/color per type. Replaces inline feed rendering in MeshLive, GossipLive (implicit), and RunDetailLive.

### `CortexWeb.Components.LogComponents`

```
<.log_viewer lines={lines} sort={:asc | :desc} on_toggle_sort={handler} expanded={expanded_set} on_toggle_expand={handler} />
<.log_entry line={line} expanded={boolean} on_toggle={handler} />
```

- `log_viewer`: Full log panel with header (sort toggle, count), scrollable body, expandable entries. Replaces inline log rendering in RunDetailLive (logs tab) and JobsLive.

### `CortexWeb.Components.TokenComponents`

```
<.token_display input={int} output={int} />
<.token_detail id={string} input={int} output={int} cache_read={int} cache_creation={int} />
<.cost_display usd={float} />
<.duration_display ms={int} />
```

- Moved from `CoreComponents` into a dedicated module. Same API, but consolidated with the inline token rendering in MeshLive/GossipLive that currently uses private `format_number/1`.

### `CortexWeb.Components.ModeComponents`

```
<.mode_selector selected={mode} on_select={handler}>
  <:dag_config>...</:dag_config>
  <:mesh_config>...</:mesh_config>
  <:gossip_config>...</:gossip_config>
</.mode_selector>
```

- Slot-based: each mode has a named slot for its config panel content. The parent LiveView provides the config form content; the component handles the tab/selection UI.

### `CortexWeb.Components.AgentComponents` — Agent Picker (addition)

```
<.agent_picker available={agents} selected={selected} filter={query} on_add={handler} on_remove={handler} on_filter={handler} />
```

- Used by both Agents page (for agent selection) and Workflows page (for visual agent composition).
- Shows available agents as selectable cards with capability filtering. Selected agents shown as removable chips.
- Attrs: `available` (list of agents), `selected` (list of selected agent IDs), `filter` (current filter string), `on_add`/`on_remove`/`on_filter` (event names).

### `CortexWeb.Components.GossipComponents`

```
<.gossip_overview run={run} gossip_state={state} />
<.knowledge_entries entries={entries} />
<.round_progress current={n} total={total} />
```

- Extracted from GossipLive's render logic. Used by RunDetailLive's Knowledge tab and Overview tab for gossip-mode runs.
- `gossip_overview`: renders gossip topology, round progress, and convergence state.
- `knowledge_entries`: renders key-value knowledge entries with source attribution.
- `round_progress`: visual progress bar for gossip rounds.

### `CortexWeb.Components.MeshComponents`

```
<.mesh_overview run={run} mesh_state={state} />
<.membership_table members={members} on_select={handler} />
<.member_card member={member} selected={boolean} />
```

- Extracted from MeshLive's render logic. Used by RunDetailLive's Membership tab and Overview tab for mesh-mode runs.
- `mesh_overview`: renders mesh membership summary, failure detection state, message relay status.
- `membership_table`: SWIM membership table with status badges and incarnation numbers.
- `member_card`: individual member card showing state, heartbeat, and load.

### Error Semantics
- All components render safe empty states for nil/missing data (e.g., "--" for missing tokens, placeholder text for empty feeds).
- Invalid `status` values fall through to a gray/default rendering — never crash.

---

## Architecture / Component Boundaries

### Module Organization

```
lib/cortex_web/components/
  core_components.ex          # KEEP — flash, header, hide, slide_over (framework-level)
  status_components.ex        # NEW — status_badge, status_dot, transport_badge, mode_badge
  agent_components.ex         # NEW — agent_card, agent_grid, agent_list, agent_picker
  topology_components.ex      # NEW — topology_graph, topology_legend (absorbs dag_components.ex)
  feed_components.ex          # NEW — activity_feed, activity_entry
  log_components.ex           # NEW — log_viewer, log_entry
  token_components.ex         # NEW — token_display, token_detail, cost_display, duration_display
  mode_components.ex          # NEW — mode_selector
  gossip_components.ex        # NEW — gossip_overview, knowledge_entries, round_progress (extracted from GossipLive)
  mesh_components.ex          # NEW — mesh_overview, membership_table, member_card (extracted from MeshLive)

lib/cortex_web/components/
  dag_components.ex           # DEPRECATE — functionality moves to topology_components.ex
```

### What Stays in CoreComponents
- `flash/1`, `flash_group/1` — framework-level, used by layout
- `header/1` — page header with subtitle/actions slots
- `hide/1` — JS utility
- `slide_over/1` — **NEW** — slide-over panel component (used by Runs Consolidation for team detail panel). Attrs: `show` (boolean), `on_close` (event), `title` (string). Slot: inner content.

### What Moves Out of CoreComponents
- `status_badge/1` -> `StatusComponents.status_badge/1` (expanded to handle atoms + more statuses)
- `token_display/1`, `token_detail/1`, `duration_display/1` -> `TokenComponents`

### Import Strategy
Each component module will `use Phoenix.Component`. The `CortexWeb` module's `:live_view` helper will import the new component modules alongside `CoreComponents`, so all components are available in any LiveView template without explicit imports.

### Composition Patterns

**Prop-based by default.** Components receive data via `attr` declarations. This is simpler, more explicit, and matches Phoenix conventions.

**Slots for structural composition only.** Use slots (`slot`) when the parent needs to inject arbitrary HEEx content — specifically:
- `header` already uses `:subtitle` and `:actions` slots (keep this pattern)
- `mode_selector` uses named slots for per-mode config panels
- `log_viewer` could use a `:header_actions` slot for custom filter buttons

**No nested component state.** All components are stateless function components. State management (selected node, expanded entries, sort order) stays in the parent LiveView. Components receive current state as attrs and emit events via `phx-click` / `phx-value-*`.

### Config Propagation
N/A — components are stateless; the parent LiveView manages all state.

### Concurrency Model
N/A — components are synchronous render functions within the LiveView process.

### Backpressure
Topology SVG rendering for large node counts (>30) should use a cap: truncate edges to nearest-neighbor rather than full-mesh O(n^2) edges to keep SVG DOM manageable.

---

## Correctness Invariants (must be explicit)

1. **Status normalization is total:** Every possible status string or atom renders a valid badge — unknown values fall through to a gray default. No match errors.
2. **Nil safety:** Every component renders a meaningful placeholder when given nil or empty data. No `FunctionClauseError` on missing assigns.
3. **Event delegation:** Components emit `phx-click` events with `phx-value-*` attributes but never handle events themselves. The parent LiveView's `handle_event/3` is the only event handler.
4. **No raw HTML injection:** All user-provided text is rendered via `{}` interpolation (auto-escaped by HEEx). No `raw/1` usage in components.
5. **DAG components backward compatibility:** The new `topology_components.ex` must render functionally equivalent SVG output to the existing `dag_components.ex` for DAG mode, so existing RunDetailLive works without changes during migration.
6. **Token formatting consistency:** All token counts across all pages use the same formatting function (K/M suffixes, decimal precision). No divergent `format_number` vs `format_token_count` implementations.

---

## Tests

### Unit Tests (per module)
- `test/cortex_web/components/status_components_test.exs` — renders correct classes for every known status string and atom; unknown status renders default; nil status renders default.
- `test/cortex_web/components/agent_components_test.exs` — renders agent_card in grid/list/compact modes; handles nil capabilities; renders agent_grid with 0, 1, N agents.
- `test/cortex_web/components/topology_components_test.exs` — renders radial topology SVG with correct node positions; renders DAG topology matching existing dag_components output; handles empty node list; handles selected node highlighting.
- `test/cortex_web/components/feed_components_test.exs` — renders activity entries with correct icons/colors; respects max limit; handles empty list.
- `test/cortex_web/components/log_components_test.exs` — renders log lines; expand/collapse toggle; sort indicator; handles nil lines.
- `test/cortex_web/components/token_components_test.exs` — token_display formats correctly for 0, small, K, M values; token_detail popover renders cache breakdown; duration_display formats ms/s/m/h correctly.
- `test/cortex_web/components/mode_components_test.exs` — mode_selector renders all three modes; highlights selected; named slots render content.

### Integration Tests
- Existing LiveView tests should continue to pass after component extraction (backward compatibility).

### Property/Fuzz Tests
- Optional: property test that `StatusComponents.status_badge/1` never raises for arbitrary string inputs.

### Failure Injection
- N/A for stateless render components.

### Commands
```bash
mix test test/cortex_web/components/           # all component tests
mix test test/cortex_web/components/ --trace    # verbose
mix test                                        # full suite (verify no regressions)
```

---

## Benchmarks + "Success"

N/A — Component rendering performance is bounded by Phoenix LiveView's diffing engine. The critical metric is **developer experience**: each new page (Agents, Workflows, Overview, Runs) should be able to render agent cards, status badges, topology graphs, and activity feeds by importing a component module and passing data — not by copy-pasting 50+ lines of inline HEEx and private helper functions.

Qualitative success criteria:
- MeshLive's 1,099 LOC drops by ~300 LOC after extracting topology, feed, status, and token rendering into shared components.
- GossipLive's 908 LOC drops by ~200 LOC similarly.
- RunDetailLive's 4,400 LOC drops by ~500 LOC after extracting log viewer, activity feed, token detail, and status badges.
- New pages (Agents, Workflows) can be built using shared components without duplicating rendering logic.

---

## Engineering Decisions & Tradeoffs (REQUIRED)

### Decision 1: Separate component modules vs single mega-module
- **Decision:** Split components into 7 focused modules (`StatusComponents`, `AgentComponents`, `TopologyComponents`, `FeedComponents`, `LogComponents`, `TokenComponents`, `ModeComponents`) rather than expanding `CoreComponents`.
- **Alternatives considered:** (A) Add everything to `CoreComponents`. (B) One new `UIComponents` module alongside `CoreComponents`.
- **Why:** The current `CoreComponents` is 291 LOC and already handles framework-level concerns (flash, header). Adding 6 more component families would push it past 1,000 LOC with unrelated responsibilities. Separate modules make it clear which components belong together, enable targeted testing, and let page-level LiveViews import only what they need. Phoenix convention is to keep `CoreComponents` for generated/framework components.
- **Tradeoff acknowledged:** More files to manage; developers must know which module holds which component. Mitigated by auto-importing all modules in `CortexWeb`'s `:live_view` helper.

### Decision 2: Stateless function components vs LiveComponents
- **Decision:** All shared components are stateless function components (not `Phoenix.LiveComponent`).
- **Alternatives considered:** Use `Phoenix.LiveComponent` for topology graph and log viewer to encapsulate state (selected node, expanded entries, sort order).
- **Why:** LiveComponents add complexity (lifecycle callbacks, separate process-like semantics, ID management) that is not needed here. The parent LiveView already manages all relevant state. Function components compose more simply, are easier to test, and have zero overhead beyond the render. Phoenix team recommends function components as the default.
- **Tradeoff acknowledged:** Parent LiveViews must manage all component-related state (e.g., `selected_node`, `expanded_logs`). This is acceptable because the state is already managed this way in the existing code.

### Decision 3: Absorb DAGComponents into TopologyComponents
- **Decision:** Merge `dag_components.ex` functionality into the new `topology_components.ex` with a `variant` attribute (`:dag` vs `:radial`) rather than keeping DAG-specific and general topology as separate modules.
- **Alternatives considered:** Keep `dag_components.ex` as-is and build `topology_components.ex` only for radial/mesh layouts.
- **Why:** The DAG graph and radial graph share 80% of their SVG rendering logic (nodes, edges, colors, click handlers). Unifying them prevents divergent status color mappings and node styling. A single `variant` attr is simpler than two modules with duplicated helpers.
- **Tradeoff acknowledged:** The unified component is more complex internally (branching on variant). Mitigated by extracting layout calculation into separate helper functions per variant.

### Decision 4: Status normalization approach
- **Decision:** Accept both strings and atoms for status values, normalize to a canonical atom internally using a single `normalize_status/1` function.
- **Alternatives considered:** Require callers to always pass atoms, or always pass strings.
- **Why:** The codebase currently mixes both — run statuses are strings from the DB ("running", "completed"), while mesh member states are atoms (`:alive`, `:suspect`), and gateway statuses are atoms (`:idle`, `:working`). Forcing one convention would require changes in all callers. Accepting both and normalizing internally makes the component maximally reusable.
- **Tradeoff acknowledged:** Slight runtime cost of normalization; implicit contract. Mitigated by documenting accepted values in `@doc` and testing both forms.

---

## Risks & Mitigations (REQUIRED)

### Risk 1: Component extraction breaks existing pages during migration
- **Risk:** Replacing inline rendering with shared components in MeshLive, GossipLive, RunDetailLive could introduce visual regressions or broken event handling.
- **Impact:** Broken pages in development; wasted debugging time.
- **Mitigation:** Implement components first, then migrate one page at a time. Each page migration is a separate commit with before/after visual verification. Keep `dag_components.ex` available during transition.
- **Validation time:** ~10 minutes per page (visual diff + `mix test`).

### Risk 2: Topology SVG performance with large node counts
- **Risk:** Full-mesh edge rendering is O(n^2). With 30+ nodes, the SVG could have 435+ line elements, causing browser rendering lag.
- **Impact:** Jank/lag on Agents page with many registered agents.
- **Mitigation:** Cap visible edges at ~200. For full-mesh with >20 nodes, only render edges connected to the selected node (or nearest 5 neighbors if none selected). Add a `max_edges` attr with sensible default.
- **Validation time:** ~5 minutes — render a 30-node topology locally and check browser DevTools paint timing.

### Risk 3: Import conflicts from auto-importing all component modules
- **Risk:** If two component modules define a function with the same name, the auto-import in `CortexWeb`'s `:live_view` helper causes a compile error.
- **Impact:** Build failure blocking all development.
- **Mitigation:** Use namespaced function names (e.g., `agent_card` not `card`, `status_badge` not `badge`). Review all public function names across modules for uniqueness before implementation.
- **Validation time:** ~2 minutes — `mix compile --warnings-as-errors`.

### Risk 4: Status color mapping divergence
- **Risk:** The codebase has 5 independent color mapping implementations (CoreComponents.status_color, DAGComponents.node_fill/node_stroke, MeshLive.member_fill/member_stroke/state_badge_class, ClusterLive.agent_status_badge_class, GossipLive inline). Unifying them could change existing colors that users are accustomed to.
- **Impact:** Confusion about what colors mean; subtle visual regressions.
- **Mitigation:** Document the canonical color mapping in the plan. The unified mapping should be a superset — every existing color pairing is preserved for its original status. New statuses get new colors. Build a reference table and validate against existing screenshots.
- **Validation time:** ~5 minutes — compare component output against existing renders.

---

## Recommended API Surface

See the **APIs** section above for the full component API. Summary:

| Module | Public Functions | Primary Consumers |
|--------|-----------------|-------------------|
| `StatusComponents` | `status_badge/1`, `status_dot/1`, `transport_badge/1`, `mode_badge/1` | All pages |
| `AgentComponents` | `agent_card/1`, `agent_grid/1`, `agent_list/1` | Agents, Workflows, Runs |
| `TopologyComponents` | `topology_graph/1`, `topology_legend/1` | Agents, Runs |
| `FeedComponents` | `activity_feed/1`, `activity_entry/1` | Overview, Runs |
| `LogComponents` | `log_viewer/1`, `log_entry/1` | Runs, Jobs |
| `TokenComponents` | `token_display/1`, `token_detail/1`, `cost_display/1`, `duration_display/1` | All pages |
| `ModeComponents` | `mode_selector/1` | Workflows |

---

## Folder Structure

```
lib/cortex_web/
  components/
    core_components.ex            # EXISTING — keep flash, header, hide
    dag_components.ex             # EXISTING — deprecate after migration
    status_components.ex          # NEW
    agent_components.ex           # NEW
    topology_components.ex        # NEW (absorbs dag_components.ex)
    feed_components.ex            # NEW
    log_components.ex             # NEW
    token_components.ex           # NEW (absorbs from core_components.ex)
    mode_components.ex            # NEW
    gossip_components.ex          # NEW (extracted from gossip_live.ex)
    mesh_components.ex            # NEW (extracted from mesh_live.ex)
  live/
    helpers/
      dag_layout.ex               # EXISTING — keep, used by topology_components.ex
      topology_layout.ex          # NEW — radial layout calculator (extracted from MeshLive/GossipLive)

test/cortex_web/
  components/
    status_components_test.exs    # NEW
    agent_components_test.exs     # NEW
    topology_components_test.exs  # NEW
    feed_components_test.exs      # NEW
    log_components_test.exs       # NEW
    token_components_test.exs     # NEW
    mode_components_test.exs      # NEW
```

---

## Step-by-Step Task Plan

### Tighten the plan into 4-7 small tasks (STRICT)

#### Task 1: StatusComponents + TokenComponents (foundation layer)
- **Outcome:** Unified status badge system handling all status types (strings + atoms) and consolidated token/duration/cost display components. CoreComponents retains flash/header/hide only.
- **Files to create/modify:**
  - Create `lib/cortex_web/components/status_components.ex`
  - Create `lib/cortex_web/components/token_components.ex`
  - Create `test/cortex_web/components/status_components_test.exs`
  - Create `test/cortex_web/components/token_components_test.exs`
  - Modify `lib/cortex_web.ex` (add imports to `:live_view` helper)
- **Exact verification commands:**
  - `mix test test/cortex_web/components/status_components_test.exs`
  - `mix test test/cortex_web/components/token_components_test.exs`
  - `mix compile --warnings-as-errors`
- **Suggested commit message:** `feat(web): add StatusComponents and TokenComponents shared modules`

#### Task 2: TopologyComponents + layout helpers
- **Outcome:** Generalized topology SVG renderer supporting DAG (tiered) and radial (mesh/gossip) variants with interactive node selection. Radial layout calculator extracted from MeshLive/GossipLive.
- **Files to create/modify:**
  - Create `lib/cortex_web/components/topology_components.ex`
  - Create `lib/cortex_web/live/helpers/topology_layout.ex`
  - Create `test/cortex_web/components/topology_components_test.exs`
- **Exact verification commands:**
  - `mix test test/cortex_web/components/topology_components_test.exs`
  - `mix compile --warnings-as-errors`
- **Suggested commit message:** `feat(web): add TopologyComponents with DAG and radial SVG rendering`

#### Task 3: AgentComponents (including agent_picker)
- **Outcome:** Agent card component with grid/list/compact modes showing name, role, capabilities, status, and transport. Agent grid and list wrapper components. Agent picker component for selecting agents from the connected pool with capability filtering — shared between Agents page and Workflows page.
- **Files to create/modify:**
  - Create `lib/cortex_web/components/agent_components.ex`
  - Create `test/cortex_web/components/agent_components_test.exs`
- **Exact verification commands:**
  - `mix test test/cortex_web/components/agent_components_test.exs`
  - `mix compile --warnings-as-errors`
- **Suggested commit message:** `feat(web): add AgentComponents with card, grid, and list views`

#### Task 4: FeedComponents + LogComponents
- **Outcome:** Reusable activity feed (timestamped event stream with icons/colors) and log viewer (sortable, expandable, team-selectable) extracted from RunDetailLive/MeshLive patterns.
- **Files to create/modify:**
  - Create `lib/cortex_web/components/feed_components.ex`
  - Create `lib/cortex_web/components/log_components.ex`
  - Create `test/cortex_web/components/feed_components_test.exs`
  - Create `test/cortex_web/components/log_components_test.exs`
- **Exact verification commands:**
  - `mix test test/cortex_web/components/feed_components_test.exs`
  - `mix test test/cortex_web/components/log_components_test.exs`
  - `mix compile --warnings-as-errors`
- **Suggested commit message:** `feat(web): add FeedComponents and LogComponents for reusable feeds and log viewers`

#### Task 5: ModeComponents + GossipComponents + MeshComponents + slide_over + import wiring
- **Outcome:** Mode selector component with named slots for per-mode config panels. Gossip components extracted from GossipLive (gossip_overview, knowledge_entries, round_progress). Mesh components extracted from MeshLive (mesh_overview, membership_table, member_card). slide_over component added to CoreComponents for team detail panel. All new component modules auto-imported in `CortexWeb` `:live_view` helper. Full component test suite passes.
- **Files to create/modify:**
  - Create `lib/cortex_web/components/mode_components.ex`
  - Create `lib/cortex_web/components/gossip_components.ex`
  - Create `lib/cortex_web/components/mesh_components.ex`
  - Create `test/cortex_web/components/mode_components_test.exs`
  - Create `test/cortex_web/components/gossip_components_test.exs`
  - Create `test/cortex_web/components/mesh_components_test.exs`
  - Modify `lib/cortex_web/components/core_components.ex` (add `slide_over/1`)
  - Modify `lib/cortex_web.ex` (final import wiring for all 9 modules)
- **Exact verification commands:**
  - `mix test test/cortex_web/components/`
  - `mix compile --warnings-as-errors`
  - `mix format --check-formatted`
  - `mix credo --strict`
- **Suggested commit message:** `feat(web): add ModeComponents, GossipComponents, MeshComponents, slide_over, and wire all imports`

#### Task 6: Migrate existing pages to shared components
- **Outcome:** ClusterLive, MeshLive, GossipLive, and RunDetailLive updated to use shared components instead of inline rendering. Inline helper functions removed. Existing behavior preserved.
- **Files to create/modify:**
  - Modify `lib/cortex_web/live/cluster_live.ex`
  - Modify `lib/cortex_web/live/mesh_live.ex`
  - Modify `lib/cortex_web/live/gossip_live.ex`
  - Modify `lib/cortex_web/live/run_detail_live.ex`
  - Modify `lib/cortex_web/live/jobs_live.ex`
  - Modify `lib/cortex_web/live/dashboard_live.ex`
  - Deprecate/remove `lib/cortex_web/components/dag_components.ex`
  - Remove token/status functions from `lib/cortex_web/components/core_components.ex`
- **Exact verification commands:**
  - `mix test`
  - `mix compile --warnings-as-errors`
  - `mix credo --strict`
  - Visual verification: visit each page at localhost:4000
- **Suggested commit message:** `refactor(web): migrate existing LiveViews to shared component system`

#### Task 7: Accessibility pass
- **Outcome:** All components have appropriate ARIA attributes: `role`, `aria-label`, `aria-selected`, `aria-expanded`. Topology graph nodes are keyboard-navigable. Status badges have `aria-label` with status text. Focus management on mode selector tabs.
- **Files to create/modify:**
  - Modify all component modules in `lib/cortex_web/components/`
  - Update component tests to verify ARIA attributes
- **Exact verification commands:**
  - `mix test test/cortex_web/components/`
  - Manual keyboard navigation test on localhost:4000
- **Suggested commit message:** `fix(web): add accessibility attributes to shared components`

---

## Canonical Status Color Mapping (Reference)

This is the single source of truth for all status colors in the restructured UI:

| Status | Badge BG | Badge Text | Dot Color | SVG Fill | SVG Stroke |
|--------|----------|------------|-----------|----------|------------|
| pending | gray-700 | gray-300 | gray-500 | #374151 | #6b7280 |
| running | blue-900/60 | blue-300 | blue-400 | #1e3a5f | #3b82f6 |
| completed / done | emerald-900/60 | emerald-300 | emerald-400 | #064e3b | #10b981 |
| failed | rose-900/60 | rose-300 | red-400 | #7f1d1d | #ef4444 |
| stopped | orange-900/60 | orange-300 | orange-400 | — | — |
| stalled | yellow-900/60 | yellow-300 | yellow-400 | #78350f | #f59e0b |
| alive | blue-900/50 | blue-300 | blue-400 | #1e3a5f | #3b82f6 |
| suspect | yellow-900/50 | yellow-300 | yellow-400 | #713f12 | #eab308 |
| dead | red-900/50 | red-300 | red-400 | #7f1d1d | #ef4444 |
| left | gray-800 | gray-400 | gray-500 | #1f2937 | #4b5563 |
| idle | blue-900/50 | blue-300 | blue-400 | — | — |
| working | green-900/50 | green-300 | green-400 | — | — |
| draining | yellow-900/50 | yellow-300 | yellow-400 | — | — |
| disconnected | red-900/50 | red-300 | red-400 | — | — |
| online | blue-900/50 | blue-300 | blue-400 | — | — |
| converged | emerald-900/50 | emerald-300 | emerald-400 | — | — |
| (unknown) | gray-800 | gray-500 | gray-600 | #1f2937 | #4b5563 |

---

## CLAUDE.md contributions (do NOT write the file; propose content)

### From Component Architect

**Component conventions:**
- All shared UI components live in `lib/cortex_web/components/`. One module per component family.
- Every component function must have `@doc`, `attr`, and `slot` declarations.
- Components are stateless function components — no `Phoenix.LiveComponent` unless explicitly justified.
- Status values: use `StatusComponents.status_badge/1` for all status rendering. It accepts both strings and atoms.
- Token values: use `TokenComponents.token_display/1` or `token_detail/1`. Do not write inline token formatting.
- Do not add `raw/1` calls in components — rely on HEEx auto-escaping.

**Dev commands:**
```bash
mix test test/cortex_web/components/    # component unit tests
mix compile --warnings-as-errors        # catch unused imports
```

**Before you commit (component changes):**
1. All component tests pass
2. No duplicate public function names across component modules
3. Every `attr` has a default or is marked `required: true`
4. Visual spot-check on localhost:4000 for any page using modified components

---

## EXPLAIN.md contributions (do NOT write the file; propose outline bullets)

### Component System
- **Architecture:** 7 focused component modules replace scattered inline rendering across 10 LiveViews. Each module owns one domain (status, agents, topology, feeds, logs, tokens, modes).
- **Key decision — function components over LiveComponents:** All shared components are stateless HEEx function components. State stays in the parent LiveView. This keeps composition simple and avoids lifecycle complexity.
- **Key decision — unified status normalization:** A single `StatusComponents` module handles all status types (run strings, mesh atoms, gateway atoms) via internal normalization, eliminating 5 separate color mapping implementations.
- **Key decision — topology unification:** One `TopologyComponents` module renders both DAG (tiered) and radial (mesh/gossip) layouts via a `variant` attribute, sharing node/edge rendering logic.
- **Limits of MVP:** Components do not handle animation (e.g., smooth topology transitions when nodes join/leave). No server-side component caching. Accessibility is basic ARIA attributes only, not full WCAG 2.1 AA.
- **Next steps:** After component extraction, build the new Agents and Workflows pages using these components. Consider a Storybook-like component gallery page for development.
- **How to run:** `mix phx.server` — visit localhost:4000. Components are auto-imported; no additional setup needed.
- **How to validate:** `mix test test/cortex_web/components/` for unit tests; visual inspection of existing pages for regression.

---

## READY FOR APPROVAL
