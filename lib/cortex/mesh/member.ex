defmodule Cortex.Mesh.Member do
  @moduledoc """
  Pure struct representing a member in a mesh cluster.

  Tracks an agent's lifecycle through SWIM-inspired states:
  alive → suspect → dead, alive → left, suspect → alive (refuted), suspect → left.

  ## Fields

    - `id` — unique identifier (typically the agent name)
    - `name` — human-readable agent name
    - `role` — the agent's role description
    - `prompt` — the agent's prompt text
    - `state` — lifecycle state: `:alive`, `:suspect`, `:dead`, or `:left`
    - `incarnation` — monotonically increasing counter for refutation
    - `metadata` — arbitrary key-value metadata
    - `port` — Erlang port reference (when spawned)
    - `os_pid` — OS process ID (when spawned)
    - `session_id` — Claude session ID (when captured)
    - `log_path` — path to the agent's NDJSON log file
    - `started_at` — when the agent was registered
    - `last_seen` — last successful heartbeat timestamp
    - `died_at` — when the agent was marked dead or left

  """

  @enforce_keys [:id, :name, :role, :prompt]
  defstruct [
    :id,
    :name,
    :role,
    :prompt,
    :port,
    :os_pid,
    :session_id,
    :log_path,
    :started_at,
    :last_seen,
    :died_at,
    state: :alive,
    incarnation: 0,
    metadata: %{}
  ]

  @type state :: :alive | :suspect | :dead | :left

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          role: String.t(),
          prompt: String.t(),
          state: state(),
          incarnation: non_neg_integer(),
          metadata: map(),
          port: port() | nil,
          os_pid: non_neg_integer() | nil,
          session_id: String.t() | nil,
          log_path: String.t() | nil,
          started_at: DateTime.t() | nil,
          last_seen: DateTime.t() | nil,
          died_at: DateTime.t() | nil
        }

  @doc "Returns true if the member is in the `:alive` state."
  @spec alive?(t()) :: boolean()
  def alive?(%__MODULE__{state: :alive}), do: true
  def alive?(%__MODULE__{}), do: false

  @doc "Returns true if the member is `:alive` or `:suspect` (still potentially reachable)."
  @spec active?(t()) :: boolean()
  def active?(%__MODULE__{state: :alive}), do: true
  def active?(%__MODULE__{state: :suspect}), do: true
  def active?(%__MODULE__{}), do: false

  @doc "Increments the incarnation counter (used to refute suspicion)."
  @spec bump_incarnation(t()) :: t()
  def bump_incarnation(%__MODULE__{} = member) do
    %{member | incarnation: member.incarnation + 1}
  end

  @doc """
  Transitions a member to a new state.

  Enforces the state machine:
  - `:alive` → `:suspect`, `:dead`, `:left`
  - `:suspect` → `:alive` (refuted), `:dead`, `:left`
  - `:dead` → no transitions allowed
  - `:left` → no transitions allowed

  Returns `{:ok, updated_member}` or `{:error, reason}`.
  """
  @spec transition(t(), state()) :: {:ok, t()} | {:error, String.t()}
  def transition(%__MODULE__{state: :dead}, _new_state) do
    {:error, "cannot transition from :dead"}
  end

  def transition(%__MODULE__{state: :left}, _new_state) do
    {:error, "cannot transition from :left"}
  end

  def transition(%__MODULE__{state: same}, same) do
    {:error, "already in state #{inspect(same)}"}
  end

  def transition(%__MODULE__{state: :alive} = member, :suspect) do
    {:ok, %{member | state: :suspect}}
  end

  def transition(%__MODULE__{state: :alive} = member, :dead) do
    {:ok, %{member | state: :dead, died_at: DateTime.utc_now()}}
  end

  def transition(%__MODULE__{state: :alive} = member, :left) do
    {:ok, %{member | state: :left, died_at: DateTime.utc_now()}}
  end

  def transition(%__MODULE__{state: :suspect} = member, :alive) do
    {:ok, bump_incarnation(%{member | state: :alive, last_seen: DateTime.utc_now()})}
  end

  def transition(%__MODULE__{state: :suspect} = member, :dead) do
    {:ok, %{member | state: :dead, died_at: DateTime.utc_now()}}
  end

  def transition(%__MODULE__{state: :suspect} = member, :left) do
    {:ok, %{member | state: :left, died_at: DateTime.utc_now()}}
  end

  def transition(%__MODULE__{state: from}, to) do
    {:error, "invalid transition from #{inspect(from)} to #{inspect(to)}"}
  end
end
