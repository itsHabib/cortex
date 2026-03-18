defmodule Cortex.Gateway.Protocol do
  @moduledoc """
  Protocol parsing, validation, and encoding for the Cortex agent gateway.

  This is a pure functional layer that transforms JSON binaries into validated
  message structs and serializes outgoing message structs back to JSON. It has
  no side effects — no GenServer calls, no PubSub, no database access.

  ## Parsing Flow

      raw JSON binary
        |> Jason.decode/1
        |> check protocol_version
        |> dispatch by "type" field
        |> validate fields (accumulate all errors)
        |> return {:ok, struct} or {:error, reasons}

  ## Supported Message Types

  Inbound (agent -> Cortex):
    - `"register"` -> `RegisterMessage`
    - `"heartbeat"` -> `HeartbeatMessage`
    - `"task_result"` -> `TaskResultMessage`
    - `"status_update"` -> `StatusUpdateMessage`

  Outbound (Cortex -> agent):
    - `RegisteredResponse`
    - `TaskRequestMessage`
    - `PeerRequestMessage`

  ## Usage

      iex> Protocol.parse(~s({"type":"register","protocol_version":1,...}))
      {:ok, %RegisterMessage{...}}

      iex> Protocol.encode(%RegisteredResponse{agent_id: "abc"})
      {:ok, ~s({"type":"registered","agent_id":"abc"})}

  ## Protocol Versioning

  All inbound messages must carry a `protocol_version` field. Only versions
  in `supported_versions/0` are accepted. Unsupported versions are rejected
  before any field validation occurs.
  """

  alias Cortex.Gateway.Protocol.Messages.{
    HeartbeatMessage,
    PeerRequestMessage,
    RegisteredResponse,
    RegisterMessage,
    StatusUpdateMessage,
    TaskRequestMessage,
    TaskResultMessage
  }

  @supported_versions [1]

  @type parse_result ::
          {:ok,
           RegisterMessage.t()
           | HeartbeatMessage.t()
           | TaskResultMessage.t()
           | StatusUpdateMessage.t()}
          | {:error, String.t() | [String.t()]}

  @doc """
  Returns the list of protocol versions this module supports.
  """
  @spec supported_versions() :: [pos_integer()]
  def supported_versions, do: @supported_versions

  @doc """
  Parses a raw JSON binary into a validated message struct.

  Decodes the JSON, checks the protocol version, dispatches to the correct
  validator based on the `"type"` field, and returns a validated struct or
  a list of error strings.

  ## Examples

      iex> Protocol.parse(~s({"type":"heartbeat","protocol_version":1,"agent_id":"a","status":"idle"}))
      {:ok, %HeartbeatMessage{agent_id: "a", status: "idle", ...}}

      iex> Protocol.parse("not json")
      {:error, "invalid JSON: unexpected byte at position 0: 0x6E (\\"n\\")"}

      iex> Protocol.parse(~s({"type":"register","protocol_version":2}))
      {:error, "unsupported protocol version: 2, supported: [1]"}
  """
  @spec parse(binary()) :: parse_result()
  def parse(raw_json) when is_binary(raw_json) do
    case Jason.decode(raw_json) do
      {:ok, data} when is_map(data) ->
        with :ok <- check_version(data),
             :ok <- check_type(data) do
          dispatch(data)
        end

      {:ok, _} ->
        {:error, "invalid JSON: expected an object"}

      {:error, %Jason.DecodeError{} = err} ->
        {:error, "invalid JSON: #{Exception.message(err)}"}
    end
  end

  @doc """
  Encodes an outgoing message struct to a JSON binary.

  Accepts any outbound message struct (`RegisteredResponse`, `TaskRequestMessage`,
  `PeerRequestMessage`) and serializes it to JSON via `to_map/1` then `Jason.encode/1`.

  ## Examples

      iex> Protocol.encode(%RegisteredResponse{agent_id: "abc-123"})
      {:ok, ~s({"agent_id":"abc-123","type":"registered"})}
  """
  @spec encode(struct()) :: {:ok, binary()} | {:error, term()}
  def encode(%RegisteredResponse{} = msg), do: do_encode(RegisteredResponse.to_map(msg))
  def encode(%TaskRequestMessage{} = msg), do: do_encode(TaskRequestMessage.to_map(msg))
  def encode(%PeerRequestMessage{} = msg), do: do_encode(PeerRequestMessage.to_map(msg))

  def encode(other) do
    {:error, "unsupported message type for encoding: #{inspect(other.__struct__)}"}
  end

  @doc """
  Validates a decoded register message payload.

  Takes a decoded JSON map (with string keys) and returns a validated
  `RegisterMessage` struct or a list of error strings.
  """
  @spec validate_register(map()) :: {:ok, RegisterMessage.t()} | {:error, [String.t()]}
  def validate_register(payload) when is_map(payload) do
    RegisterMessage.new(payload)
  end

  @doc """
  Validates a decoded heartbeat message payload.

  Takes a decoded JSON map and returns a validated `HeartbeatMessage`
  struct or a list of error strings.
  """
  @spec validate_heartbeat(map()) :: {:ok, HeartbeatMessage.t()} | {:error, [String.t()]}
  def validate_heartbeat(payload) when is_map(payload) do
    HeartbeatMessage.new(payload)
  end

  @doc """
  Validates a decoded task result message payload.

  Takes a decoded JSON map and returns a validated `TaskResultMessage`
  struct or a list of error strings.
  """
  @spec validate_task_result(map()) :: {:ok, TaskResultMessage.t()} | {:error, [String.t()]}
  def validate_task_result(payload) when is_map(payload) do
    TaskResultMessage.new(payload)
  end

  @doc """
  Validates a decoded status update message payload.

  Takes a decoded JSON map and returns a validated `StatusUpdateMessage`
  struct or a list of error strings.
  """
  @spec validate_status_update(map()) :: {:ok, StatusUpdateMessage.t()} | {:error, [String.t()]}
  def validate_status_update(payload) when is_map(payload) do
    StatusUpdateMessage.new(payload)
  end

  # -- Private Helpers --

  defp check_version(data) do
    case Map.get(data, "protocol_version") do
      v when v in @supported_versions ->
        :ok

      v when is_integer(v) ->
        {:error, "unsupported protocol version: #{v}, supported: #{inspect(@supported_versions)}"}

      nil ->
        {:error, "missing required field: protocol_version"}

      other ->
        {:error, "invalid protocol_version: expected integer, got #{inspect(other)}"}
    end
  end

  defp check_type(data) do
    case Map.get(data, "type") do
      t when t in ["register", "heartbeat", "task_result", "status_update"] ->
        :ok

      nil ->
        {:error, "missing required field: type"}

      unknown ->
        {:error, "unknown message type: #{unknown}"}
    end
  end

  defp dispatch(%{"type" => "register"} = data), do: RegisterMessage.new(data)
  defp dispatch(%{"type" => "heartbeat"} = data), do: HeartbeatMessage.new(data)
  defp dispatch(%{"type" => "task_result"} = data), do: TaskResultMessage.new(data)
  defp dispatch(%{"type" => "status_update"} = data), do: StatusUpdateMessage.new(data)

  defp do_encode(map) do
    case Jason.encode(map) do
      {:ok, json} -> {:ok, json}
      {:error, reason} -> {:error, "JSON encoding failed: #{inspect(reason)}"}
    end
  end
end
