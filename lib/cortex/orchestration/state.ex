defmodule Cortex.Orchestration.State do
  @moduledoc """
  Shared orchestration run state.

  Tracks the project name and per-team execution state. Serialized as
  JSON in the workspace's `state.json` file. The `teams` map is keyed
  by team name (string) and valued with `TeamState` structs.

  ## Fields

    - `project` — the project name from the orchestra config
    - `teams` — a map of `team_name => %TeamState{}`
  """

  alias Cortex.Orchestration.TeamState

  defstruct [:project, teams: %{}]

  @type t :: %__MODULE__{
          project: String.t() | nil,
          teams: %{optional(String.t()) => TeamState.t()}
        }

  @doc """
  Converts a `State` struct to a plain map suitable for JSON encoding.

  ## Examples

      iex> state = %State{project: "demo", teams: %{}}
      iex> State.to_map(state)
      %{"project" => "demo", "teams" => %{}}

  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = state) do
    teams_map =
      state.teams
      |> Enum.map(fn {name, team_state} -> {name, TeamState.to_map(team_state)} end)
      |> Map.new()

    %{"project" => state.project, "teams" => teams_map}
  end

  @doc """
  Constructs a `State` struct from a decoded JSON map.

  ## Examples

      iex> State.from_map(%{"project" => "demo", "teams" => %{}})
      %State{project: "demo", teams: %{}}

  """
  @spec from_map(map()) :: t()
  def from_map(%{"project" => project, "teams" => teams_map}) do
    teams =
      teams_map
      |> Enum.map(fn {name, ts_map} -> {name, TeamState.from_map(ts_map)} end)
      |> Map.new()

    %__MODULE__{project: project, teams: teams}
  end

  def from_map(%{"project" => project}) do
    %__MODULE__{project: project, teams: %{}}
  end
end

defmodule Cortex.Orchestration.TeamState do
  @moduledoc """
  Per-team execution state within an orchestration run.

  ## Fields

    - `status` — one of `"pending"`, `"running"`, `"done"`, `"failed"`
    - `result_summary` — short text summary of what the team accomplished
    - `artifacts` — list of file paths or artifact identifiers produced
    - `cost_usd` — total API cost in USD for this team's execution
    - `input_tokens` — input tokens consumed
    - `output_tokens` — output tokens produced
    - `cache_read_tokens` — cache read input tokens
    - `cache_creation_tokens` — cache creation input tokens
    - `duration_ms` — wall-clock execution time in milliseconds
  """

  @valid_statuses ["pending", "running", "done", "failed"]

  defstruct [
    :status,
    :result_summary,
    :artifacts,
    :cost_usd,
    :input_tokens,
    :output_tokens,
    :cache_read_tokens,
    :cache_creation_tokens,
    :duration_ms
  ]

  @type t :: %__MODULE__{
          status: String.t() | nil,
          result_summary: String.t() | nil,
          artifacts: [String.t()] | nil,
          cost_usd: float() | nil,
          input_tokens: non_neg_integer() | nil,
          output_tokens: non_neg_integer() | nil,
          cache_read_tokens: non_neg_integer() | nil,
          cache_creation_tokens: non_neg_integer() | nil,
          duration_ms: integer() | nil
        }

  @doc """
  Returns the list of valid status strings.
  """
  @spec valid_statuses() :: [String.t()]
  def valid_statuses, do: @valid_statuses

  @doc """
  Converts a `TeamState` struct to a plain map for JSON encoding.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = ts) do
    %{
      "status" => ts.status,
      "result_summary" => ts.result_summary,
      "artifacts" => ts.artifacts,
      "cost_usd" => ts.cost_usd,
      "input_tokens" => ts.input_tokens,
      "output_tokens" => ts.output_tokens,
      "cache_read_tokens" => ts.cache_read_tokens,
      "cache_creation_tokens" => ts.cache_creation_tokens,
      "duration_ms" => ts.duration_ms
    }
  end

  @doc """
  Constructs a `TeamState` struct from a decoded JSON map.
  """
  @spec from_map(map()) :: t()
  def from_map(map) when is_map(map) do
    %__MODULE__{
      status: Map.get(map, "status"),
      result_summary: Map.get(map, "result_summary"),
      artifacts: Map.get(map, "artifacts"),
      cost_usd: Map.get(map, "cost_usd"),
      input_tokens: Map.get(map, "input_tokens"),
      output_tokens: Map.get(map, "output_tokens"),
      cache_read_tokens: Map.get(map, "cache_read_tokens"),
      cache_creation_tokens: Map.get(map, "cache_creation_tokens"),
      duration_ms: Map.get(map, "duration_ms")
    }
  end

  @doc """
  Applies a keyword list of updates to an existing `TeamState`.

  Only keys present in the keyword list are updated; others are left as-is.

  ## Parameters

    - `team_state` — the current `%TeamState{}`
    - `updates` — keyword list of fields to update

  ## Examples

      iex> ts = %TeamState{status: "pending"}
      iex> TeamState.merge(ts, status: "running", cost_usd: 0.50)
      %TeamState{status: "running", cost_usd: 0.50}

  """
  @spec merge(t(), keyword()) :: t()
  def merge(%__MODULE__{} = team_state, updates) when is_list(updates) do
    struct(team_state, updates)
  end
end
