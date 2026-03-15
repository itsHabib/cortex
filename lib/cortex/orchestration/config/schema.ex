defmodule Cortex.Orchestration.Config.Defaults do
  @moduledoc """
  Default settings applied to all teams unless overridden.

  ## Fields

    - `model` — the LLM model identifier (default: `"sonnet"`)
    - `max_turns` — maximum conversation turns per agent (default: `200`)
    - `permission_mode` — how the agent handles edit permissions (default: `"acceptEdits"`)
    - `timeout_minutes` — per-team execution timeout in minutes (default: `30`)

  """

  defstruct model: "sonnet",
            max_turns: 200,
            permission_mode: "acceptEdits",
            timeout_minutes: 30

  @type t :: %__MODULE__{
          model: String.t(),
          max_turns: pos_integer(),
          permission_mode: String.t(),
          timeout_minutes: pos_integer()
        }
end

defmodule Cortex.Orchestration.Config.Lead do
  @moduledoc """
  The lead role for a team.

  ## Fields

    - `role` — a description of the lead's role (required)
    - `model` — optional model override for this lead (default: `nil`, uses project default)

  """

  @enforce_keys [:role]
  defstruct [
    :role,
    :model
  ]

  @type t :: %__MODULE__{
          role: String.t(),
          model: String.t() | nil
        }
end

defmodule Cortex.Orchestration.Config.Member do
  @moduledoc """
  A team member with a specific focus area.

  ## Fields

    - `role` — the member's role description (required)
    - `focus` — what the member should focus on (default: `nil`)

  """

  @enforce_keys [:role]
  defstruct [
    :role,
    :focus
  ]

  @type t :: %__MODULE__{
          role: String.t(),
          focus: String.t() | nil
        }
end

defmodule Cortex.Orchestration.Config.Task do
  @moduledoc """
  A task to be accomplished by a team.

  ## Fields

    - `summary` — a short description of the task (required)
    - `details` — expanded instructions for the task (default: `nil`)
    - `deliverables` — list of expected output paths or artifacts (default: `[]`)
    - `verify` — a shell command to verify the task was completed (default: `nil`)

  """

  @enforce_keys [:summary]
  defstruct [
    :summary,
    :details,
    :verify,
    deliverables: []
  ]

  @type t :: %__MODULE__{
          summary: String.t(),
          details: String.t() | nil,
          deliverables: [String.t()],
          verify: String.t() | nil
        }
end

defmodule Cortex.Orchestration.Config.Team do
  @moduledoc """
  A team within the orchestra project.

  Each team represents one node in the execution DAG. A team has a lead,
  optional members, one or more tasks, optional dependencies on other teams,
  and optional context injected into the prompt.

  ## Fields

    - `name` — unique team identifier (required)
    - `lead` — a `%Lead{}` struct (required)
    - `members` — list of `%Member{}` structs (default: `[]`)
    - `tasks` — list of `%Task{}` structs (required, at least one)
    - `depends_on` — list of team name strings this team depends on (default: `[]`)
    - `context` — free-form string injected into the team's prompt (default: `nil`)

  """

  alias Cortex.Orchestration.Config.{Lead, Member, Task}

  @enforce_keys [:name, :lead, :tasks]
  defstruct [
    :name,
    :lead,
    :context,
    members: [],
    tasks: [],
    depends_on: []
  ]

  @type t :: %__MODULE__{
          name: String.t(),
          lead: Lead.t(),
          members: [Member.t()],
          tasks: [Task.t()],
          depends_on: [String.t()],
          context: String.t() | nil
        }
end

defmodule Cortex.Orchestration.Config do
  @moduledoc """
  Top-level configuration struct for an orchestra project definition.

  Parsed from an `orchestra.yaml` file, a `Config` holds the project name,
  default settings, and the list of teams that make up the project DAG.

  ## Fields

    - `name` — the project name (required, non-empty string)
    - `defaults` — a `%Defaults{}` struct with model, turn, timeout defaults
    - `teams` — a list of `%Team{}` structs defining the project's work units

  """

  alias Cortex.Orchestration.Config.{Defaults, Team}

  @enforce_keys [:name, :teams]
  defstruct [
    :name,
    :workspace_path,
    defaults: %Defaults{},
    teams: []
  ]

  @type t :: %__MODULE__{
          name: String.t(),
          workspace_path: String.t() | nil,
          defaults: Defaults.t(),
          teams: [Team.t()]
        }
end
