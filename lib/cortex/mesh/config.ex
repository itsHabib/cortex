defmodule Cortex.Mesh.Config.MeshSettings do
  @moduledoc """
  Settings specific to mesh mode membership protocol.

  ## Fields

    - `heartbeat_interval_seconds` — seconds between heartbeat checks (default: 30)
    - `suspect_timeout_seconds` — seconds before a suspect member is declared dead (default: 90)
    - `dead_timeout_seconds` — seconds before cleaning up dead members (default: 180)
    - `coordinator` — whether to spawn a lightweight coordinator agent (default: false)

  """

  defstruct heartbeat_interval_seconds: 30,
            suspect_timeout_seconds: 90,
            dead_timeout_seconds: 180,
            coordinator: false

  @type t :: %__MODULE__{
          heartbeat_interval_seconds: pos_integer(),
          suspect_timeout_seconds: pos_integer(),
          dead_timeout_seconds: pos_integer(),
          coordinator: boolean()
        }
end

defmodule Cortex.Mesh.Config.Agent do
  @moduledoc """
  A mesh agent definition.

  Each agent operates independently in the mesh, optionally reaching out
  to other agents for collaboration.

  ## Fields

    - `name` — unique agent identifier (required)
    - `role` — the agent's role description (required)
    - `prompt` — the assignment prompt for this agent (required)
    - `model` — optional model override (default: `nil`, uses project default)
    - `metadata` — arbitrary key-value metadata (default: `%{}`)

  """

  @enforce_keys [:name, :role, :prompt]
  defstruct [
    :name,
    :role,
    :prompt,
    :model,
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          name: String.t(),
          role: String.t(),
          prompt: String.t(),
          model: String.t() | nil,
          metadata: map()
        }
end

defmodule Cortex.Mesh.Config do
  @moduledoc """
  Top-level configuration for a mesh mode project.

  Parsed from a YAML file with `mode: mesh`. Unlike gossip mode, mesh agents
  are fully autonomous — they can see a roster of peers and optionally message
  them, but there is no forced coordination.

  ## Fields

    - `name` — the project name (required)
    - `cluster_context` — shared context injected into all agent prompts
    - `defaults` — default model/turn/timeout settings
    - `mesh` — mesh-specific settings (heartbeat, suspect/dead timeouts)
    - `agents` — list of agent definitions

  """

  alias Cortex.Mesh.Config.{Agent, MeshSettings}
  alias Cortex.Orchestration.Config.Defaults

  @enforce_keys [:name, :agents]
  defstruct [
    :name,
    :cluster_context,
    defaults: %Defaults{},
    mesh: %MeshSettings{},
    agents: []
  ]

  @type t :: %__MODULE__{
          name: String.t(),
          cluster_context: String.t() | nil,
          defaults: Defaults.t(),
          mesh: MeshSettings.t(),
          agents: [Agent.t()]
        }
end
