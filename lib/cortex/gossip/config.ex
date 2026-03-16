defmodule Cortex.Gossip.Config.GossipSettings do
  @moduledoc """
  Settings specific to gossip mode coordination.

  ## Fields

    - `rounds` — number of gossip exchange rounds (default: 5)
    - `topology` — topology strategy: `:full_mesh`, `:ring`, or `:random` (default: `:random`)
    - `exchange_interval_seconds` — seconds between exchange rounds (default: 60)
    - `coordinator` — whether to spawn a coordinator agent that synthesizes, steers, and can terminate early (default: false)

  """

  defstruct rounds: 5,
            topology: :random,
            exchange_interval_seconds: 60,
            coordinator: false

  @type t :: %__MODULE__{
          rounds: pos_integer(),
          topology: :full_mesh | :ring | :random,
          exchange_interval_seconds: pos_integer(),
          coordinator: boolean()
        }
end

defmodule Cortex.Gossip.Config.Agent do
  @moduledoc """
  A gossip agent definition.

  Each agent explores a specific topic independently, sharing findings
  with peers via the gossip protocol.

  ## Fields

    - `name` — unique agent identifier (required)
    - `topic` — the knowledge topic/angle to explore (required)
    - `prompt` — the exploration prompt for this agent (required)
    - `model` — optional model override (default: `nil`, uses project default)

  """

  @enforce_keys [:name, :topic, :prompt]
  defstruct [
    :name,
    :topic,
    :prompt,
    :model
  ]

  @type t :: %__MODULE__{
          name: String.t(),
          topic: String.t(),
          prompt: String.t(),
          model: String.t() | nil
        }
end

defmodule Cortex.Gossip.Config.SeedKnowledge do
  @moduledoc """
  A seed knowledge entry distributed to all agents at startup.

  ## Fields

    - `topic` — the knowledge topic (required)
    - `content` — the knowledge content (required)

  """

  @enforce_keys [:topic, :content]
  defstruct [:topic, :content]

  @type t :: %__MODULE__{
          topic: String.t(),
          content: String.t()
        }
end

defmodule Cortex.Gossip.Config do
  @moduledoc """
  Top-level configuration for a gossip mode project.

  Parsed from a `gossip.yaml` file with `mode: gossip`. Unlike the DAG
  config, gossip config has flat agents (no hierarchy, no dependencies)
  and gossip-specific settings for rounds, topology, and exchange timing.

  ## Fields

    - `name` — the project name (required)
    - `defaults` — default model/turn/timeout settings
    - `gossip` — gossip-specific settings (rounds, topology, interval)
    - `agents` — list of agent definitions
    - `seed_knowledge` — optional starting knowledge for all agents

  """

  alias Cortex.Gossip.Config.{Agent, GossipSettings, SeedKnowledge}
  alias Cortex.Orchestration.Config.Defaults

  @enforce_keys [:name, :agents]
  defstruct [
    :name,
    :cluster_context,
    defaults: %Defaults{},
    gossip: %GossipSettings{},
    agents: [],
    seed_knowledge: []
  ]

  @type t :: %__MODULE__{
          name: String.t(),
          cluster_context: String.t() | nil,
          defaults: Defaults.t(),
          gossip: GossipSettings.t(),
          agents: [Agent.t()],
          seed_knowledge: [SeedKnowledge.t()]
        }
end
