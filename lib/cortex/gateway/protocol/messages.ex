defmodule Cortex.Gateway.Protocol.Messages do
  @moduledoc """
  Message struct definitions for the Cortex agent gateway protocol.

  Defines all inbound (agent -> Cortex) and outbound (Cortex -> agent) message
  types as Elixir structs with strict field validation.

  ## Inbound Messages

    - `RegisterMessage` — agent registration with capabilities and auth
    - `HeartbeatMessage` — periodic health check from agent
    - `TaskResultMessage` — completed task result from agent
    - `StatusUpdateMessage` — agent status change notification

  ## Outbound Messages

    - `RegisteredResponse` — registration confirmation with assigned agent ID
    - `TaskRequestMessage` — work assignment from Cortex to agent
    - `PeerRequestMessage` — agent-to-agent invocation routed through Cortex

  ## Wire Format

  All messages are JSON objects. Inbound messages carry a `"type"` field and
  `"protocol_version"` field. Outbound messages carry a `"type"` field.

  Sidecar implementers in Go, Python, or Rust can use the struct definitions
  and `to_map/1` output as the canonical wire format specification.
  """
end

defmodule Cortex.Gateway.Protocol.Messages.Validation do
  @moduledoc false

  @doc false
  def check_unknown_keys(map, known, errors, prefix \\ "") do
    map
    |> Map.keys()
    |> Enum.reduce(errors, fn key, acc ->
      if MapSet.member?(known, key), do: acc, else: ["unknown field: #{prefix}#{key}" | acc]
    end)
  end

  @doc false
  def require_non_empty_string(map, key, label, errors) do
    case Map.get(map, key) do
      v when is_binary(v) and byte_size(v) > 0 -> {v, errors}
      _ -> {nil, ["missing required field: #{label}" | errors]}
    end
  end

  @doc false
  def require_status(map, valid_statuses, errors) do
    case Map.get(map, "status") do
      s when is_binary(s) ->
        if s in valid_statuses do
          {s, errors}
        else
          {nil, ["invalid status: #{s}, must be one of: #{inspect(valid_statuses)}" | errors]}
        end

      _ ->
        {nil, ["missing required field: status" | errors]}
    end
  end

  @doc false
  def require_non_empty_string_flex(data, string_key, atom_key, label, errors) do
    case Map.get(data, string_key) || Map.get(data, atom_key) do
      v when is_binary(v) and byte_size(v) > 0 -> {v, errors}
      _ -> {nil, ["missing required field: #{label}" | errors]}
    end
  end

  @doc false
  def require_pos_integer_flex(data, string_key, atom_key, label, errors) do
    case Map.get(data, string_key) || Map.get(data, atom_key) do
      v when is_integer(v) and v > 0 -> {v, errors}
      _ -> {nil, ["missing required field: #{label}" | errors]}
    end
  end

  @doc false
  def finalize(errors, ok_fun) do
    if errors == [] do
      ok_fun.()
    else
      {:error, Enum.reverse(errors)}
    end
  end
end

defmodule Cortex.Gateway.Protocol.Messages.RegisterMessage do
  @moduledoc """
  Inbound message: agent registration.

  ## Wire Format (JSON)

      {
        "type": "register",
        "protocol_version": 1,
        "agent": {
          "name": "security-reviewer",
          "role": "Reviews code for security vulnerabilities",
          "capabilities": ["security-review", "cve-lookup"],
          "metadata": {}
        },
        "auth": {
          "token": "bearer-token-here"
        }
      }

  ## Required Fields

    - `protocol_version` — must be `1`
    - `agent.name` — non-empty string
    - `agent.role` — non-empty string
    - `agent.capabilities` — non-empty list of strings
    - `auth.token` — non-empty string

  ## Optional Fields

    - `agent.metadata` — map, defaults to `%{}`
  """

  alias Cortex.Gateway.Protocol.Messages.Validation

  @enforce_keys [:protocol_version, :name, :role, :capabilities, :token]
  defstruct [
    :protocol_version,
    :name,
    :role,
    :capabilities,
    :token,
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          protocol_version: pos_integer(),
          name: String.t(),
          role: String.t(),
          capabilities: [String.t()],
          token: String.t(),
          metadata: map()
        }

  @known_top_keys MapSet.new(["type", "protocol_version", "agent", "auth"])
  @known_agent_keys MapSet.new(["name", "role", "capabilities", "metadata"])
  @known_auth_keys MapSet.new(["token"])

  @doc """
  Builds and validates a `RegisterMessage` from a decoded JSON map.

  Returns `{:ok, %RegisterMessage{}}` or `{:error, [String.t()]}` with all
  validation errors accumulated.
  """
  @spec new(map()) :: {:ok, t()} | {:error, [String.t()]}
  def new(data) when is_map(data) do
    agent = Map.get(data, "agent", %{})
    auth = Map.get(data, "auth", %{})

    errors = Validation.check_unknown_keys(data, @known_top_keys, [])
    errors = check_nested_keys(errors, agent, auth)

    {name, errors} = Validation.require_non_empty_string(agent, "name", "agent.name", errors)
    {role, errors} = Validation.require_non_empty_string(agent, "role", "agent.role", errors)
    {capabilities, errors} = validate_capabilities(agent, errors)
    {token, errors} = Validation.require_non_empty_string(auth, "token", "auth.token", errors)
    metadata = extract_metadata(agent)

    Validation.finalize(errors, fn ->
      {:ok,
       %__MODULE__{
         protocol_version: data["protocol_version"],
         name: name,
         role: role,
         capabilities: capabilities,
         token: token,
         metadata: metadata
       }}
    end)
  end

  @doc """
  Converts a `RegisterMessage` struct to a JSON-encodable map.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = msg) do
    %{
      "type" => "register",
      "protocol_version" => msg.protocol_version,
      "agent" => %{
        "name" => msg.name,
        "role" => msg.role,
        "capabilities" => msg.capabilities,
        "metadata" => msg.metadata
      },
      "auth" => %{
        "token" => msg.token
      }
    }
  end

  defp check_nested_keys(errors, agent, auth) do
    errors =
      if is_map(agent),
        do: Validation.check_unknown_keys(agent, @known_agent_keys, errors, "agent."),
        else: errors

    if is_map(auth),
      do: Validation.check_unknown_keys(auth, @known_auth_keys, errors, "auth."),
      else: errors
  end

  defp validate_capabilities(agent, errors) do
    case Map.get(agent, "capabilities") do
      [_ | _] = caps ->
        if Enum.all?(caps, &is_binary/1),
          do: {caps, errors},
          else: {nil, ["capabilities must contain only strings" | errors]}

      [] ->
        {nil, ["capabilities must be a non-empty list" | errors]}

      nil ->
        {nil, ["missing required field: agent.capabilities" | errors]}

      _ ->
        {nil, ["capabilities must be a non-empty list" | errors]}
    end
  end

  defp extract_metadata(agent) do
    case Map.get(agent, "metadata") do
      m when is_map(m) -> m
      _ -> %{}
    end
  end
end

defmodule Cortex.Gateway.Protocol.Messages.HeartbeatMessage do
  @moduledoc """
  Inbound message: agent heartbeat.

  ## Wire Format (JSON)

      {
        "type": "heartbeat",
        "protocol_version": 1,
        "agent_id": "uuid-here",
        "status": "idle",
        "load": {
          "active_tasks": 2,
          "queue_depth": 5
        }
      }

  ## Required Fields

    - `protocol_version` — must be `1`
    - `agent_id` — non-empty string (UUID assigned at registration)
    - `status` — one of `"idle"`, `"working"`, `"draining"`

  ## Optional Fields

    - `load` — map with `active_tasks` and `queue_depth` integers
  """

  alias Cortex.Gateway.Protocol.Messages.Validation

  @enforce_keys [:protocol_version, :agent_id, :status]
  defstruct [
    :protocol_version,
    :agent_id,
    :status,
    load: nil
  ]

  @type t :: %__MODULE__{
          protocol_version: pos_integer(),
          agent_id: String.t(),
          status: String.t(),
          load: map() | nil
        }

  @valid_statuses ["idle", "working", "draining"]
  @known_keys MapSet.new(["type", "protocol_version", "agent_id", "status", "load"])

  @doc """
  Builds and validates a `HeartbeatMessage` from a decoded JSON map.

  Returns `{:ok, %HeartbeatMessage{}}` or `{:error, [String.t()]}`.
  """
  @spec new(map()) :: {:ok, t()} | {:error, [String.t()]}
  def new(data) when is_map(data) do
    errors = Validation.check_unknown_keys(data, @known_keys, [])
    {agent_id, errors} = Validation.require_non_empty_string(data, "agent_id", "agent_id", errors)
    {status, errors} = Validation.require_status(data, @valid_statuses, errors)
    load = extract_load(data)

    Validation.finalize(errors, fn ->
      {:ok,
       %__MODULE__{
         protocol_version: data["protocol_version"],
         agent_id: agent_id,
         status: status,
         load: load
       }}
    end)
  end

  @doc """
  Converts a `HeartbeatMessage` struct to a JSON-encodable map.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = msg) do
    base = %{
      "type" => "heartbeat",
      "protocol_version" => msg.protocol_version,
      "agent_id" => msg.agent_id,
      "status" => msg.status
    }

    if msg.load, do: Map.put(base, "load", msg.load), else: base
  end

  defp extract_load(data) do
    case Map.get(data, "load") do
      l when is_map(l) -> l
      _ -> nil
    end
  end
end

defmodule Cortex.Gateway.Protocol.Messages.TaskResultMessage do
  @moduledoc """
  Inbound message: completed task result from agent.

  ## Wire Format (JSON)

      {
        "type": "task_result",
        "protocol_version": 1,
        "task_id": "task-uuid-here",
        "status": "completed",
        "result": {
          "text": "The analysis found no vulnerabilities.",
          "tokens": {"input": 150, "output": 42},
          "duration_ms": 3200
        }
      }

  ## Required Fields

    - `protocol_version` — must be `1`
    - `task_id` — non-empty string
    - `status` — one of `"completed"`, `"failed"`, `"cancelled"`
    - `result` — map containing at least `"text"` (string)

  ## Optional Result Fields

    - `result.tokens` — map with token usage info
    - `result.duration_ms` — integer, time taken in milliseconds
  """

  alias Cortex.Gateway.Protocol.Messages.Validation

  @enforce_keys [:protocol_version, :task_id, :status, :result]
  defstruct [
    :protocol_version,
    :task_id,
    :status,
    :result
  ]

  @type t :: %__MODULE__{
          protocol_version: pos_integer(),
          task_id: String.t(),
          status: String.t(),
          result: map()
        }

  @valid_statuses ["completed", "failed", "cancelled"]
  @known_keys MapSet.new(["type", "protocol_version", "task_id", "status", "result"])

  @doc """
  Builds and validates a `TaskResultMessage` from a decoded JSON map.

  Returns `{:ok, %TaskResultMessage{}}` or `{:error, [String.t()]}`.
  """
  @spec new(map()) :: {:ok, t()} | {:error, [String.t()]}
  def new(data) when is_map(data) do
    errors = Validation.check_unknown_keys(data, @known_keys, [])
    {task_id, errors} = Validation.require_non_empty_string(data, "task_id", "task_id", errors)
    {status, errors} = Validation.require_status(data, @valid_statuses, errors)
    {result, errors} = validate_result(data, errors)

    Validation.finalize(errors, fn ->
      {:ok,
       %__MODULE__{
         protocol_version: data["protocol_version"],
         task_id: task_id,
         status: status,
         result: result
       }}
    end)
  end

  @doc """
  Converts a `TaskResultMessage` struct to a JSON-encodable map.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = msg) do
    %{
      "type" => "task_result",
      "protocol_version" => msg.protocol_version,
      "task_id" => msg.task_id,
      "status" => msg.status,
      "result" => msg.result
    }
  end

  defp validate_result(data, errors) do
    case Map.get(data, "result") do
      r when is_map(r) ->
        case Map.get(r, "text") do
          t when is_binary(t) -> {r, errors}
          _ -> {nil, ["missing required field: result.text" | errors]}
        end

      _ ->
        {nil, ["missing required field: result" | errors]}
    end
  end
end

defmodule Cortex.Gateway.Protocol.Messages.StatusUpdateMessage do
  @moduledoc """
  Inbound message: agent status change notification.

  ## Wire Format (JSON)

      {
        "type": "status_update",
        "protocol_version": 1,
        "agent_id": "uuid-here",
        "status": "working",
        "detail": "Processing security review for project-x"
      }

  ## Required Fields

    - `protocol_version` — must be `1`
    - `agent_id` — non-empty string
    - `status` — one of `"idle"`, `"working"`, `"draining"`

  ## Optional Fields

    - `detail` — string, human-readable description of current activity
  """

  alias Cortex.Gateway.Protocol.Messages.Validation

  @enforce_keys [:protocol_version, :agent_id, :status]
  defstruct [
    :protocol_version,
    :agent_id,
    :status,
    detail: nil
  ]

  @type t :: %__MODULE__{
          protocol_version: pos_integer(),
          agent_id: String.t(),
          status: String.t(),
          detail: String.t() | nil
        }

  @valid_statuses ["idle", "working", "draining"]
  @known_keys MapSet.new(["type", "protocol_version", "agent_id", "status", "detail"])

  @doc """
  Builds and validates a `StatusUpdateMessage` from a decoded JSON map.

  Returns `{:ok, %StatusUpdateMessage{}}` or `{:error, [String.t()]}`.
  """
  @spec new(map()) :: {:ok, t()} | {:error, [String.t()]}
  def new(data) when is_map(data) do
    errors = Validation.check_unknown_keys(data, @known_keys, [])
    {agent_id, errors} = Validation.require_non_empty_string(data, "agent_id", "agent_id", errors)
    {status, errors} = Validation.require_status(data, @valid_statuses, errors)
    detail = extract_detail(data)

    Validation.finalize(errors, fn ->
      {:ok,
       %__MODULE__{
         protocol_version: data["protocol_version"],
         agent_id: agent_id,
         status: status,
         detail: detail
       }}
    end)
  end

  @doc """
  Converts a `StatusUpdateMessage` struct to a JSON-encodable map.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = msg) do
    base = %{
      "type" => "status_update",
      "protocol_version" => msg.protocol_version,
      "agent_id" => msg.agent_id,
      "status" => msg.status
    }

    if msg.detail, do: Map.put(base, "detail", msg.detail), else: base
  end

  defp extract_detail(data) do
    case Map.get(data, "detail") do
      d when is_binary(d) -> d
      _ -> nil
    end
  end
end

defmodule Cortex.Gateway.Protocol.Messages.RegisteredResponse do
  @moduledoc """
  Outbound message: registration confirmation.

  Sent by Cortex to the agent after successful registration.

  ## Wire Format (JSON)

      {
        "type": "registered",
        "agent_id": "assigned-uuid",
        "mesh_info": {
          "peers": 5,
          "run_id": "run-123"
        }
      }

  ## Required Fields

    - `type` — always `"registered"`
    - `agent_id` — the UUID assigned by the registry

  ## Optional Fields

    - `mesh_info` — map with peer count and run info
  """

  @enforce_keys [:agent_id]
  defstruct [
    :agent_id,
    mesh_info: nil
  ]

  @type t :: %__MODULE__{
          agent_id: String.t(),
          mesh_info: map() | nil
        }

  @doc """
  Builds a `RegisteredResponse` from a map.

  Returns `{:ok, %RegisteredResponse{}}` or `{:error, [String.t()]}`.
  """
  @spec new(map()) :: {:ok, t()} | {:error, [String.t()]}
  def new(data) when is_map(data) do
    case Map.get(data, "agent_id") || Map.get(data, :agent_id) do
      id when is_binary(id) and byte_size(id) > 0 ->
        mesh_info = Map.get(data, "mesh_info") || Map.get(data, :mesh_info)
        {:ok, %__MODULE__{agent_id: id, mesh_info: mesh_info}}

      _ ->
        {:error, ["missing required field: agent_id"]}
    end
  end

  @doc """
  Converts a `RegisteredResponse` struct to a JSON-encodable map.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = msg) do
    base = %{"type" => "registered", "agent_id" => msg.agent_id}
    if msg.mesh_info, do: Map.put(base, "mesh_info", msg.mesh_info), else: base
  end
end

defmodule Cortex.Gateway.Protocol.Messages.TaskRequestMessage do
  @moduledoc """
  Outbound message: work assignment from Cortex to agent.

  ## Wire Format (JSON)

      {
        "type": "task_request",
        "task_id": "task-uuid",
        "prompt": "Review this code for SQL injection vulnerabilities...",
        "timeout_ms": 30000,
        "tools": ["read_file", "grep"],
        "context": {"project": "acme-web"}
      }

  ## Required Fields

    - `type` — always `"task_request"`
    - `task_id` — unique task identifier
    - `prompt` — the task prompt/instruction
    - `timeout_ms` — maximum execution time in milliseconds

  ## Optional Fields

    - `tools` — list of tool names the agent may use
    - `context` — arbitrary context map
  """

  alias Cortex.Gateway.Protocol.Messages.Validation

  @enforce_keys [:task_id, :prompt, :timeout_ms]
  defstruct [
    :task_id,
    :prompt,
    :timeout_ms,
    tools: [],
    context: %{}
  ]

  @type t :: %__MODULE__{
          task_id: String.t(),
          prompt: String.t(),
          timeout_ms: pos_integer(),
          tools: [String.t()],
          context: map()
        }

  @doc """
  Builds a `TaskRequestMessage` from a map.

  Returns `{:ok, %TaskRequestMessage{}}` or `{:error, [String.t()]}`.
  """
  @spec new(map()) :: {:ok, t()} | {:error, [String.t()]}
  def new(data) when is_map(data) do
    errors = []

    {task_id, errors} =
      Validation.require_non_empty_string_flex(data, "task_id", :task_id, "task_id", errors)

    {prompt, errors} =
      Validation.require_non_empty_string_flex(data, "prompt", :prompt, "prompt", errors)

    {timeout_ms, errors} =
      Validation.require_pos_integer_flex(data, "timeout_ms", :timeout_ms, "timeout_ms", errors)

    tools = Map.get(data, "tools") || Map.get(data, :tools) || []
    context = Map.get(data, "context") || Map.get(data, :context) || %{}

    Validation.finalize(errors, fn ->
      {:ok,
       %__MODULE__{
         task_id: task_id,
         prompt: prompt,
         timeout_ms: timeout_ms,
         tools: tools,
         context: context
       }}
    end)
  end

  @doc """
  Converts a `TaskRequestMessage` struct to a JSON-encodable map.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = msg) do
    %{
      "type" => "task_request",
      "task_id" => msg.task_id,
      "prompt" => msg.prompt,
      "timeout_ms" => msg.timeout_ms,
      "tools" => msg.tools,
      "context" => msg.context
    }
  end
end

defmodule Cortex.Gateway.Protocol.Messages.PeerRequestMessage do
  @moduledoc """
  Outbound message: agent-to-agent invocation routed through Cortex.

  ## Wire Format (JSON)

      {
        "type": "peer_request",
        "request_id": "req-uuid",
        "from_agent": "agent-name-or-id",
        "capability": "security-review",
        "input": "Please review this diff for vulnerabilities...",
        "timeout_ms": 60000
      }

  ## Required Fields

    - `type` — always `"peer_request"`
    - `request_id` — unique request identifier
    - `from_agent` — the requesting agent's name or ID
    - `capability` — the capability being invoked
    - `input` — the request input/prompt
    - `timeout_ms` — maximum execution time in milliseconds
  """

  alias Cortex.Gateway.Protocol.Messages.Validation

  @enforce_keys [:request_id, :from_agent, :capability, :input, :timeout_ms]
  defstruct [
    :request_id,
    :from_agent,
    :capability,
    :input,
    :timeout_ms
  ]

  @type t :: %__MODULE__{
          request_id: String.t(),
          from_agent: String.t(),
          capability: String.t(),
          input: String.t(),
          timeout_ms: pos_integer()
        }

  @doc """
  Builds a `PeerRequestMessage` from a map.

  Returns `{:ok, %PeerRequestMessage{}}` or `{:error, [String.t()]}`.
  """
  @spec new(map()) :: {:ok, t()} | {:error, [String.t()]}
  def new(data) when is_map(data) do
    errors = []

    {request_id, errors} =
      Validation.require_non_empty_string_flex(
        data,
        "request_id",
        :request_id,
        "request_id",
        errors
      )

    {from_agent, errors} =
      Validation.require_non_empty_string_flex(
        data,
        "from_agent",
        :from_agent,
        "from_agent",
        errors
      )

    {capability, errors} =
      Validation.require_non_empty_string_flex(
        data,
        "capability",
        :capability,
        "capability",
        errors
      )

    {input, errors} =
      Validation.require_non_empty_string_flex(data, "input", :input, "input", errors)

    {timeout_ms, errors} =
      Validation.require_pos_integer_flex(data, "timeout_ms", :timeout_ms, "timeout_ms", errors)

    Validation.finalize(errors, fn ->
      {:ok,
       %__MODULE__{
         request_id: request_id,
         from_agent: from_agent,
         capability: capability,
         input: input,
         timeout_ms: timeout_ms
       }}
    end)
  end

  @doc """
  Converts a `PeerRequestMessage` struct to a JSON-encodable map.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = msg) do
    %{
      "type" => "peer_request",
      "request_id" => msg.request_id,
      "from_agent" => msg.from_agent,
      "capability" => msg.capability,
      "input" => msg.input,
      "timeout_ms" => msg.timeout_ms
    }
  end
end
