---
name: cortex-config
description: Interactively create a Cortex YAML config for multi-agent orchestration. Supports all three modes — workflow (DAG), mesh, and gossip.
argument-hint: [optional output path]
disable-model-invocation: false
---

# Cortex Config Skill

Create a Cortex YAML config from a short interactive conversation. Asks the user a few questions, designs the agent/team structure, shows a plan, then writes the file.

## Step 1 — Choose mode

Ask the user which mode they want. Present all three with one-line descriptions:

1. **Workflow (DAG)** — structured execution with team dependencies. Teams run in parallel tiers, upstream results feed downstream prompts. Best for multi-step projects with clear ordering.
2. **Mesh** — autonomous agents with optional messaging. Each agent works independently, can see a roster of peers, and messages others only when needed. Best for parallel workstreams.
3. **Gossip** — decentralized knowledge sharing. Agents explore a topic from different angles, findings are exchanged periodically via gossip protocol. Best for research and brainstorming.

If `$ARGUMENTS` contains a mode or enough context to infer one, skip this question.

## Step 2 — Gather project details

Ask questions in a **single round** (use AskUserQuestion). Tailor questions to the chosen mode.

### All modes

1. **Project name** — what is this called?
2. **What are agents working on?** — describe the objective in 2-3 sentences. The user MUST provide a real description — without it you cannot design meaningful agents. If the answer is too vague, ask follow-ups.
3. **Cluster context** — any shared background all agents should know? (optional)

### Mode-specific questions

**Workflow (DAG):**
4. **How many teams?** — suggest a number with names based on the description (e.g., "3 teams: backend, frontend, integration"). Include "auto" and custom options.
5. **Model** — sonnet (recommended), opus, or haiku
6. **Permission mode** — acceptEdits (recommended) or bypassPermissions

**Mesh:**
4. **How many agents?** — suggest specific agents with names and roles based on the description (e.g., "3 agents: market-sizing, competitor-analysis, product-strategy")
5. **Model** — sonnet (recommended), opus, or haiku
6. **Permission mode** — acceptEdits (recommended) or bypassPermissions

**Gossip:**
4. **How many agents?** — suggest specific agents with names and topics based on the description
5. **Rounds** — how many gossip exchange rounds? (suggest a default based on scope, typically 3-5)
6. **Model** — sonnet (recommended), opus, or haiku

### Critical rule

Do NOT proceed to Step 3 until you have a concrete understanding of what the agents should accomplish. If the user gives a vague answer, ask follow-up questions. You need enough detail to write specific prompts — not generic boilerplate.

## Step 3 — Design the config

From the user's answers, design the full config.

### Workflow (DAG) design

- Name each team after its domain (e.g., `backend`, `frontend`, `data-pipeline`)
- Each team gets a `lead` with a descriptive `role`
- Add `members` with distinct roles and focus areas (2-5 per team)
- Write a rich `context` block per team
- Determine DAG dependencies — no circular deps allowed
- Design 4-7 tasks per team with `summary`, `details`, `deliverables`, and `verify`

### Mesh design

- Name each agent after its domain (e.g., `market-sizing`, `competitor-analysis`)
- Give each agent a specific `role` (one-line description of what they are)
- Write a detailed `prompt` for each agent — what they should research/build/analyze, what deliverables to produce, and how to structure their output
- Set mesh settings (heartbeat/suspect/dead timeouts — defaults are usually fine)

### Gossip design

- Name each agent after its exploration angle (e.g., `competitor-analyst`, `market-sizer`)
- Give each agent a `topic` and detailed `prompt`
- Set gossip settings (rounds, topology, exchange interval)
- Add seed knowledge if relevant

## Step 4 — Present the plan

Show a formatted summary for user review. Format depends on mode:

### Workflow plan

```
## Cortex Config: <name>
Mode: workflow (DAG)

### Defaults
model: <model> | max_turns: <N> | timeout: <N>min | permission: <mode>

### Execution Tiers

**Tier 0** (parallel):
  - <team>: <lead role> + <N members>

**Tier 1** (depends on: <tier 0 teams>):
  - <team>: <lead role> + <N members>

### Output
  <filename>.yaml
```

### Mesh plan

```
## Cortex Config: <name>
Mode: mesh

### Defaults
model: <model> | max_turns: <N> | timeout: <N>min | permission: <mode>

### Agents
  - <name>: <role>
  - <name>: <role>

### Mesh Settings
heartbeat: <N>s | suspect timeout: <N>s | dead timeout: <N>s

### Output
  <filename>.yaml
```

### Gossip plan

```
## Cortex Config: <name>
Mode: gossip

### Defaults
model: <model> | max_turns: <N> | timeout: <N>min

### Agents
  - <name>: <topic>
  - <name>: <topic>

### Gossip Settings
rounds: <N> | topology: <type> | interval: <N>s

### Output
  <filename>.yaml
```

Ask: "Does this look right? I'll write the config."

## Step 5 — Write the YAML

Write the file to the output path from `$ARGUMENTS`, or default to `examples/<project-name>.yaml` inside the cortex directory.

### Workflow schema

```yaml
name: "<project name>"

defaults:
  model: <model>
  max_turns: <number>
  permission_mode: <mode>
  timeout_minutes: <number>

teams:
  - name: <team-name>
    lead:
      role: "<role description>"
    members:
      - role: "<member role>"
        focus: "<what this member owns>"
    context: |
      <rich domain context>
    depends_on:
      - <team-name>
    tasks:
      - summary: "<short description>"
        details: "<specific requirements>"
        deliverables:
          - "<file path>"
        verify: "<shell command>"
```

### Mesh schema

```yaml
name: "<project name>"
mode: mesh

cluster_context: |
  <shared context for all agents>

defaults:
  model: <model>
  max_turns: <number>
  permission_mode: <mode>
  timeout_minutes: <number>

mesh:
  heartbeat_interval_seconds: 30
  suspect_timeout_seconds: 90
  dead_timeout_seconds: 180

agents:
  - name: <agent-name>
    role: "<one-line role description>"
    prompt: |
      <detailed assignment — what to do, what deliverables to produce,
       how to structure output. Be specific.>
```

### Gossip schema

```yaml
name: "<project name>"
mode: gossip

cluster_context: |
  <shared context for all agents>

defaults:
  model: <model>
  max_turns: <number>
  permission_mode: <mode>
  timeout_minutes: <number>

gossip:
  rounds: <number>
  topology: <full_mesh|ring|random>
  exchange_interval_seconds: <number>

agents:
  - name: <agent-name>
    topic: "<knowledge topic>"
    prompt: |
      <detailed exploration instructions>

seed_knowledge:
  - topic: "<topic>"
    content: "<starting knowledge>"
```

### Quality checklist before writing

- Project name is non-empty
- Every agent/team has a name
- No duplicate names
- Agent prompts are specific and actionable (not generic filler like "do research")
- Workflow: all `depends_on` references exist, no circular deps, every team has tasks
- Gossip: rounds >= 1, valid topology
- Mesh: positive timeout values

## Step 6 — Print next steps

After writing the file, print mode-appropriate next steps:

### Workflow

```
<filename> written!

Next steps:
  1. Review:  cat <filename>
  2. Dry run: mix cortex.run <filename> --dry-run
  3. Run:     mix cortex.run <filename>
```

### Mesh

```
<filename> written!

Next steps:
  1. Review:  cat <filename>
  2. Dry run: mix cortex.run <filename> --dry-run
  3. Run:     mix cortex.run <filename>
```

### Gossip

```
<filename> written!

Next steps:
  1. Review:  cat <filename>
  2. Dry run: mix cortex.run <filename> --dry-run
  3. Run:     mix cortex.run <filename>
```
