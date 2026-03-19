# Generated from proto/cortex/gateway/v1/gateway.proto — do NOT edit by hand.
# Regenerate with: make proto

defmodule Cortex.Gateway.Proto.AgentStatus do
  @moduledoc "Agent operational status enum."
  use Protobuf, enum: true, protoc_gen_elixir_version: "0.13.0", syntax: :proto3

  field(:AGENT_STATUS_UNSPECIFIED, 0)
  field(:AGENT_STATUS_IDLE, 1)
  field(:AGENT_STATUS_WORKING, 2)
  field(:AGENT_STATUS_DRAINING, 3)
  field(:AGENT_STATUS_DISCONNECTED, 4)
end

defmodule Cortex.Gateway.Proto.TaskStatus do
  @moduledoc "Task outcome status enum."
  use Protobuf, enum: true, protoc_gen_elixir_version: "0.13.0", syntax: :proto3

  field(:TASK_STATUS_UNSPECIFIED, 0)
  field(:TASK_STATUS_COMPLETED, 1)
  field(:TASK_STATUS_FAILED, 2)
  field(:TASK_STATUS_CANCELLED, 3)
end

# Map entry types for map<string, string> fields.

defmodule Cortex.Gateway.Proto.RegisterRequest.MetadataEntry do
  @moduledoc false
  use Protobuf, map: true, protoc_gen_elixir_version: "0.13.0", syntax: :proto3

  field(:key, 1, type: :string)
  field(:value, 2, type: :string)
end

defmodule Cortex.Gateway.Proto.TaskRequest.ContextEntry do
  @moduledoc false
  use Protobuf, map: true, protoc_gen_elixir_version: "0.13.0", syntax: :proto3

  field(:key, 1, type: :string)
  field(:value, 2, type: :string)
end

defmodule Cortex.Gateway.Proto.AgentInfo.MetadataEntry do
  @moduledoc false
  use Protobuf, map: true, protoc_gen_elixir_version: "0.13.0", syntax: :proto3

  field(:key, 1, type: :string)
  field(:value, 2, type: :string)
end

# Message types.

defmodule Cortex.Gateway.Proto.RegisterRequest do
  @moduledoc "Sent by the agent as the first message on the stream."
  use Protobuf, protoc_gen_elixir_version: "0.13.0", syntax: :proto3

  field(:name, 1, type: :string)
  field(:role, 2, type: :string)
  field(:capabilities, 3, repeated: true, type: :string)
  field(:auth_token, 4, type: :string, json_name: "authToken")

  field(:metadata, 5,
    repeated: true,
    type: Cortex.Gateway.Proto.RegisterRequest.MetadataEntry,
    map: true
  )
end

defmodule Cortex.Gateway.Proto.RegisterResponse do
  @moduledoc "Sent by the gateway after successful registration."
  use Protobuf, protoc_gen_elixir_version: "0.13.0", syntax: :proto3

  field(:agent_id, 1, type: :string, json_name: "agentId")
  field(:peer_count, 2, type: :int32, json_name: "peerCount")
  field(:run_id, 3, type: :string, json_name: "runId")
end

defmodule Cortex.Gateway.Proto.Heartbeat do
  @moduledoc "Periodic heartbeat from the agent."
  use Protobuf, protoc_gen_elixir_version: "0.13.0", syntax: :proto3

  field(:agent_id, 1, type: :string, json_name: "agentId")
  field(:status, 2, type: Cortex.Gateway.Proto.AgentStatus, enum: true)
  field(:active_tasks, 3, type: :int32, json_name: "activeTasks")
  field(:queue_depth, 4, type: :int32, json_name: "queueDepth")
end

defmodule Cortex.Gateway.Proto.TaskRequest do
  @moduledoc "Task assignment from Cortex to an agent."
  use Protobuf, protoc_gen_elixir_version: "0.13.0", syntax: :proto3

  field(:task_id, 1, type: :string, json_name: "taskId")
  field(:prompt, 2, type: :string)
  field(:tools, 3, repeated: true, type: :string)
  field(:timeout_ms, 4, type: :int64, json_name: "timeoutMs")

  field(:context, 5,
    repeated: true,
    type: Cortex.Gateway.Proto.TaskRequest.ContextEntry,
    map: true
  )
end

defmodule Cortex.Gateway.Proto.TaskResult do
  @moduledoc "Task result sent by the agent."
  use Protobuf, protoc_gen_elixir_version: "0.13.0", syntax: :proto3

  field(:task_id, 1, type: :string, json_name: "taskId")
  field(:status, 2, type: Cortex.Gateway.Proto.TaskStatus, enum: true)
  field(:result_text, 3, type: :string, json_name: "resultText")
  field(:duration_ms, 4, type: :int64, json_name: "durationMs")
  field(:input_tokens, 5, type: :int32, json_name: "inputTokens")
  field(:output_tokens, 6, type: :int32, json_name: "outputTokens")
end

defmodule Cortex.Gateway.Proto.StatusUpdate do
  @moduledoc "Progress update from the agent."
  use Protobuf, protoc_gen_elixir_version: "0.13.0", syntax: :proto3

  field(:agent_id, 1, type: :string, json_name: "agentId")
  field(:status, 2, type: Cortex.Gateway.Proto.AgentStatus, enum: true)
  field(:detail, 3, type: :string)
  field(:progress, 4, type: :float)
end

defmodule Cortex.Gateway.Proto.PeerRequest do
  @moduledoc "Peer invocation routed by the gateway."
  use Protobuf, protoc_gen_elixir_version: "0.13.0", syntax: :proto3

  field(:request_id, 1, type: :string, json_name: "requestId")
  field(:from_agent, 2, type: :string, json_name: "fromAgent")
  field(:capability, 3, type: :string)
  field(:prompt, 4, type: :string)
  field(:timeout_ms, 5, type: :int64, json_name: "timeoutMs")
end

defmodule Cortex.Gateway.Proto.PeerResponse do
  @moduledoc "Response to a peer invocation."
  use Protobuf, protoc_gen_elixir_version: "0.13.0", syntax: :proto3

  field(:request_id, 1, type: :string, json_name: "requestId")
  field(:status, 2, type: Cortex.Gateway.Proto.TaskStatus, enum: true)
  field(:result, 3, type: :string)
  field(:duration_ms, 4, type: :int64, json_name: "durationMs")
end

defmodule Cortex.Gateway.Proto.RosterUpdate do
  @moduledoc "Mesh membership change notification."
  use Protobuf, protoc_gen_elixir_version: "0.13.0", syntax: :proto3

  field(:agents, 1, repeated: true, type: Cortex.Gateway.Proto.AgentInfo)
end

defmodule Cortex.Gateway.Proto.AgentInfo do
  @moduledoc "Description of a single agent in the mesh roster."
  use Protobuf, protoc_gen_elixir_version: "0.13.0", syntax: :proto3

  field(:id, 1, type: :string)
  field(:name, 2, type: :string)
  field(:role, 3, type: :string)
  field(:capabilities, 4, repeated: true, type: :string)
  field(:status, 5, type: Cortex.Gateway.Proto.AgentStatus, enum: true)

  field(:metadata, 6,
    repeated: true,
    type: Cortex.Gateway.Proto.AgentInfo.MetadataEntry,
    map: true
  )
end

defmodule Cortex.Gateway.Proto.DirectMessage do
  @moduledoc "Agent-to-agent direct message."
  use Protobuf, protoc_gen_elixir_version: "0.13.0", syntax: :proto3

  field(:message_id, 1, type: :string, json_name: "messageId")
  field(:to_agent, 2, type: :string, json_name: "toAgent")
  field(:from_agent, 3, type: :string, json_name: "fromAgent")
  field(:content, 4, type: :string)
  field(:timestamp, 5, type: :int64)
end

defmodule Cortex.Gateway.Proto.BroadcastRequest do
  @moduledoc "Broadcast message to all connected agents."
  use Protobuf, protoc_gen_elixir_version: "0.13.0", syntax: :proto3

  field(:content, 1, type: :string)
end

defmodule Cortex.Gateway.Proto.Error do
  @moduledoc "Protocol-level error from the gateway."
  use Protobuf, protoc_gen_elixir_version: "0.13.0", syntax: :proto3

  field(:code, 1, type: :string)
  field(:message, 2, type: :string)
end

# Oneof wrapper messages.

defmodule Cortex.Gateway.Proto.AgentMessage do
  @moduledoc "Envelope for all agent-to-gateway messages."
  use Protobuf, protoc_gen_elixir_version: "0.13.0", syntax: :proto3

  oneof(:msg, 0)

  field(:register, 1, type: Cortex.Gateway.Proto.RegisterRequest, oneof: 0)
  field(:heartbeat, 2, type: Cortex.Gateway.Proto.Heartbeat, oneof: 0)
  field(:task_result, 3, type: Cortex.Gateway.Proto.TaskResult, json_name: "taskResult", oneof: 0)

  field(:status_update, 4,
    type: Cortex.Gateway.Proto.StatusUpdate,
    json_name: "statusUpdate",
    oneof: 0
  )

  field(:peer_response, 5,
    type: Cortex.Gateway.Proto.PeerResponse,
    json_name: "peerResponse",
    oneof: 0
  )

  field(:direct_message, 6,
    type: Cortex.Gateway.Proto.DirectMessage,
    json_name: "directMessage",
    oneof: 0
  )

  field(:broadcast, 7, type: Cortex.Gateway.Proto.BroadcastRequest, oneof: 0)
end

defmodule Cortex.Gateway.Proto.GatewayMessage do
  @moduledoc "Envelope for all gateway-to-agent messages."
  use Protobuf, protoc_gen_elixir_version: "0.13.0", syntax: :proto3

  oneof(:msg, 0)

  field(:registered, 1,
    type: Cortex.Gateway.Proto.RegisterResponse,
    oneof: 0
  )

  field(:task_request, 2,
    type: Cortex.Gateway.Proto.TaskRequest,
    json_name: "taskRequest",
    oneof: 0
  )

  field(:peer_request, 3,
    type: Cortex.Gateway.Proto.PeerRequest,
    json_name: "peerRequest",
    oneof: 0
  )

  field(:roster_update, 4,
    type: Cortex.Gateway.Proto.RosterUpdate,
    json_name: "rosterUpdate",
    oneof: 0
  )

  field(:error, 5, type: Cortex.Gateway.Proto.Error, oneof: 0)

  field(:direct_message, 6,
    type: Cortex.Gateway.Proto.DirectMessage,
    json_name: "directMessage",
    oneof: 0
  )
end

# gRPC service definition.

defmodule Cortex.Gateway.Proto.AgentGateway.Service do
  @moduledoc "AgentGateway gRPC service — bidirectional streaming for agent mesh."
  use GRPC.Service, name: "cortex.gateway.v1.AgentGateway", protoc_gen_elixir_version: "0.13.0"

  rpc(
    :Connect,
    stream(Cortex.Gateway.Proto.AgentMessage),
    stream(Cortex.Gateway.Proto.GatewayMessage)
  )
end

defmodule Cortex.Gateway.Proto.AgentGateway.Stub do
  @moduledoc false
  use GRPC.Stub, service: Cortex.Gateway.Proto.AgentGateway.Service
end
