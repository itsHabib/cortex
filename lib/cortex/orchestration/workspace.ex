defmodule Cortex.Orchestration.Workspace do
  @moduledoc """
  Workspace manager for orchestration runs.

  A workspace is a `.cortex/` directory under a project path that holds
  all run state: shared state (`state.json`), team registry
  (`registry.json`), per-team results (`results/<team>.json`), and
  per-team logs (`logs/<team>.log`).

  All JSON writes use `FileUtils.atomic_write/2` to prevent partial writes.

  ## Directory Layout

      .cortex/
      +-- state.json        # shared state -- per-team status and result summaries
      +-- registry.json     # all teams: name, status, pid, timestamps
      +-- results/
      |   +-- <team>.json   # full result per team
      +-- logs/
          +-- <team>.log    # raw claude -p stdout

  ## Usage

      {:ok, ws} = Workspace.init("/path/to/project", config)
      {:ok, state} = Workspace.read_state(ws)
      :ok = Workspace.update_team_state(ws, "backend", status: "running")

  """

  alias Cortex.Messaging.InboxBridge
  alias Cortex.Orchestration.FileUtils
  alias Cortex.Orchestration.State
  alias Cortex.Orchestration.TeamState
  alias Cortex.Orchestration.RunRegistry
  alias Cortex.Orchestration.RegistryEntry
  alias Cortex.Orchestration.WorkspaceLock

  defstruct [:path]

  @type t :: %__MODULE__{
          path: Path.t()
        }

  @cortex_dir ".cortex"
  @state_file "state.json"
  @registry_file "registry.json"
  @results_dir "results"
  @logs_dir "logs"
  @messages_dir "messages"

  # --- Init / Open ---

  @doc """
  Initializes a new workspace under `path`.

  Creates the `.cortex/` directory structure with seeded `state.json`
  and `registry.json` files. The `config` map must contain at least
  a `:project` key (string) and optionally a `:teams` key (list of
  team name strings) to seed initial pending entries.

  Returns `{:ok, workspace}` or `{:error, reason}`.

  ## Parameters

    - `path` — the project root directory (must exist)
    - `config` — a map with `:project` (required) and `:teams` (optional list of team name strings)

  ## Examples

      iex> Workspace.init("/tmp/my-project", %{project: "demo", teams: ["backend", "frontend"]})
      {:ok, %Workspace{path: "/tmp/my-project/.cortex"}}

  """
  @spec init(Path.t(), map()) :: {:ok, t()} | {:error, term()}
  def init(path, config) when is_binary(path) and is_map(config) do
    cortex_path = Path.join(path, @cortex_dir)
    team_names = Map.get(config, :teams, [])

    with :ok <- File.mkdir_p(Path.join(cortex_path, @results_dir)),
         :ok <- File.mkdir_p(Path.join(cortex_path, @logs_dir)),
         :ok <- File.mkdir_p(Path.join(cortex_path, @messages_dir)),
         :ok <- seed_state(cortex_path, config),
         :ok <- seed_registry(cortex_path, config),
         :ok <- InboxBridge.setup(path, team_names) do
      {:ok, %__MODULE__{path: cortex_path}}
    end
  end

  @doc """
  Opens an existing workspace at `path`.

  Validates that the `.cortex/` directory exists under `path`. Does not
  validate internal structure — missing files will be caught on read.

  Returns `{:ok, workspace}` or `{:error, :workspace_not_found}`.

  ## Parameters

    - `path` — the project root directory

  ## Examples

      iex> Workspace.open("/tmp/my-project")
      {:ok, %Workspace{path: "/tmp/my-project/.cortex"}}

  """
  @spec open(Path.t()) :: {:ok, t()} | {:error, :workspace_not_found}
  def open(path) when is_binary(path) do
    cortex_path = Path.join(path, @cortex_dir)

    if File.dir?(cortex_path) do
      {:ok, %__MODULE__{path: cortex_path}}
    else
      {:error, :workspace_not_found}
    end
  end

  # --- State Operations ---

  @doc """
  Reads the current orchestration state from `state.json`.

  Returns `{:ok, %State{}}` or `{:error, reason}`.
  """
  @spec read_state(t()) :: {:ok, State.t()} | {:error, term()}
  def read_state(%__MODULE__{path: path}) do
    file = Path.join(path, @state_file)

    with {:ok, content} <- File.read(file),
         {:ok, decoded} <- Jason.decode(content) do
      {:ok, State.from_map(decoded)}
    end
  end

  @doc """
  Writes the full orchestration state to `state.json`.

  Uses atomic write to prevent partial writes.

  Returns `:ok` or `{:error, reason}`.
  """
  @spec write_state(t(), State.t()) :: :ok | {:error, term()}
  def write_state(%__MODULE__{path: path}, %State{} = state) do
    file = Path.join(path, @state_file)
    json = Jason.encode!(State.to_map(state), pretty: true)
    FileUtils.atomic_write(file, json)
  end

  @doc """
  Updates a single team's state within the shared state file.

  Reads the current state, applies the `updates` keyword list to the
  team's `TeamState`, and writes the result back atomically.

  If the team doesn't exist in the state map, a new `TeamState` is
  created with the given updates.

  Returns `:ok` or `{:error, reason}`.

  ## Parameters

    - `workspace` — the workspace struct
    - `team_name` — the team to update (string)
    - `updates` — keyword list of `TeamState` fields to update

  ## Examples

      iex> Workspace.update_team_state(ws, "backend", status: "running")
      :ok

  """
  @spec update_team_state(t(), String.t(), keyword()) :: :ok | {:error, term()}
  def update_team_state(%__MODULE__{} = workspace, team_name, updates)
      when is_binary(team_name) and is_list(updates) do
    WorkspaceLock.serialize({:state, workspace.path}, fn ->
      with {:ok, state} <- read_state(workspace) do
        current_ts = Map.get(state.teams, team_name, %TeamState{})
        updated_ts = TeamState.merge(current_ts, updates)
        updated_state = %{state | teams: Map.put(state.teams, team_name, updated_ts)}
        write_state(workspace, updated_state)
      end
    end)
  end

  # --- Registry Operations ---

  @doc """
  Reads the run registry from `registry.json`.

  Returns `{:ok, %RunRegistry{}}` or `{:error, reason}`.
  """
  @spec read_registry(t()) :: {:ok, RunRegistry.t()} | {:error, term()}
  def read_registry(%__MODULE__{path: path}) do
    file = Path.join(path, @registry_file)

    with {:ok, content} <- File.read(file),
         {:ok, decoded} <- Jason.decode(content) do
      {:ok, RunRegistry.from_map(decoded)}
    end
  end

  @doc """
  Writes the full run registry to `registry.json`.

  Uses atomic write to prevent partial writes.

  Returns `:ok` or `{:error, reason}`.
  """
  @spec write_registry(t(), RunRegistry.t()) :: :ok | {:error, term()}
  def write_registry(%__MODULE__{path: path}, %RunRegistry{} = registry) do
    file = Path.join(path, @registry_file)
    json = Jason.encode!(RunRegistry.to_map(registry), pretty: true)
    FileUtils.atomic_write(file, json)
  end

  @doc """
  Updates a single team's entry in the run registry.

  Reads the current registry, applies the `updates` keyword list to
  the team's `RegistryEntry` (or creates a new one), and writes back
  atomically.

  Returns `:ok` or `{:error, reason}`.

  ## Parameters

    - `workspace` — the workspace struct
    - `team_name` — the team to update (string)
    - `updates` — keyword list of `RegistryEntry` fields to update

  ## Examples

      iex> Workspace.update_registry_entry(ws, "backend", status: "running", pid: 12345)
      :ok

  """
  @spec update_registry_entry(t(), String.t(), keyword()) :: :ok | {:error, term()}
  def update_registry_entry(%__MODULE__{} = workspace, team_name, updates)
      when is_binary(team_name) and is_list(updates) do
    WorkspaceLock.serialize({:registry, workspace.path}, fn ->
      with {:ok, registry} <- read_registry(workspace) do
        updated_registry = RunRegistry.update_entry(registry, team_name, updates)
        write_registry(workspace, updated_registry)
      end
    end)
  end

  # --- Result Operations ---

  @doc """
  Writes a team's full result to `results/<team_name>.json`.

  The `result` can be any term that is JSON-encodable (typically a map
  or struct that implements `Jason.Encoder`).

  Returns `:ok` or `{:error, reason}`.
  """
  @spec write_result(t(), String.t(), term()) :: :ok | {:error, term()}
  def write_result(%__MODULE__{path: path}, team_name, result)
      when is_binary(team_name) do
    file = Path.join([path, @results_dir, "#{team_name}.json"])
    json = Jason.encode!(result, pretty: true)
    FileUtils.atomic_write(file, json)
  end

  @doc """
  Reads a team's full result from `results/<team_name>.json`.

  Returns `{:ok, decoded_map}` or `{:error, reason}`.
  """
  @spec read_result(t(), String.t()) :: {:ok, term()} | {:error, term()}
  def read_result(%__MODULE__{path: path}, team_name) when is_binary(team_name) do
    file = Path.join([path, @results_dir, "#{team_name}.json"])

    with {:ok, content} <- File.read(file) do
      Jason.decode(content)
    end
  end

  # --- Log Operations ---

  @doc """
  Returns the log file path for a team.

  The path is `<workspace>/.cortex/logs/<team_name>.log`.

  ## Examples

      iex> Workspace.log_path(ws, "backend")
      "/tmp/project/.cortex/logs/backend.log"

  """
  @spec log_path(t(), String.t()) :: Path.t()
  def log_path(%__MODULE__{path: path}, team_name) when is_binary(team_name) do
    Path.join([path, @logs_dir, "#{team_name}.log"])
  end

  @doc """
  Opens a log file for writing.

  Returns `{:ok, io_device}` or `{:error, reason}`. The caller is
  responsible for closing the IO device when done.

  ## Examples

      iex> {:ok, io} = Workspace.open_log(ws, "backend")
      iex> IO.write(io, "log line\\n")
      iex> File.close(io)

  """
  @spec open_log(t(), String.t()) :: {:ok, File.io_device()} | {:error, term()}
  def open_log(%__MODULE__{} = workspace, team_name) when is_binary(team_name) do
    path = log_path(workspace, team_name)
    File.open(path, [:write, :utf8])
  end

  # --- Private Helpers ---

  @spec seed_state(Path.t(), map()) :: :ok | {:error, term()}
  defp seed_state(cortex_path, config) do
    project = Map.fetch!(config, :project)
    team_names = Map.get(config, :teams, [])

    teams =
      team_names
      |> Enum.map(fn name -> {name, %TeamState{status: "pending"}} end)
      |> Map.new()

    state = %State{project: project, teams: teams}
    json = Jason.encode!(State.to_map(state), pretty: true)
    FileUtils.atomic_write(Path.join(cortex_path, @state_file), json)
  end

  @spec seed_registry(Path.t(), map()) :: :ok | {:error, term()}
  defp seed_registry(cortex_path, config) do
    project = Map.fetch!(config, :project)
    team_names = Map.get(config, :teams, [])

    teams =
      Enum.map(team_names, fn name ->
        %RegistryEntry{name: name, status: "pending"}
      end)

    registry = %RunRegistry{project: project, teams: teams}
    json = Jason.encode!(RunRegistry.to_map(registry), pretty: true)
    FileUtils.atomic_write(Path.join(cortex_path, @registry_file), json)
  end
end
