defmodule Cortex.Gateway.ProtocolTest do
  use ExUnit.Case, async: true

  alias Cortex.Gateway.Protocol

  alias Cortex.Gateway.Protocol.Messages.{
    HeartbeatMessage,
    PeerRequestMessage,
    RegisterMessage,
    RegisteredResponse,
    StatusUpdateMessage,
    TaskRequestMessage,
    TaskResultMessage
  }

  # -- Helpers --

  defp valid_register_json do
    Jason.encode!(%{
      "type" => "register",
      "protocol_version" => 1,
      "agent" => %{
        "name" => "test-agent",
        "role" => "tester",
        "capabilities" => ["testing", "review"]
      },
      "auth" => %{
        "token" => "secret-token"
      }
    })
  end

  defp valid_heartbeat_json do
    Jason.encode!(%{
      "type" => "heartbeat",
      "protocol_version" => 1,
      "agent_id" => "agent-uuid-123",
      "status" => "idle"
    })
  end

  defp valid_task_result_json do
    Jason.encode!(%{
      "type" => "task_result",
      "protocol_version" => 1,
      "task_id" => "task-uuid-456",
      "status" => "completed",
      "result" => %{
        "text" => "No issues found."
      }
    })
  end

  defp valid_status_update_json do
    Jason.encode!(%{
      "type" => "status_update",
      "protocol_version" => 1,
      "agent_id" => "agent-uuid-123",
      "status" => "working"
    })
  end

  # =========================================================
  # Parse Dispatch Tests
  # =========================================================

  describe "parse/1 dispatch" do
    test "parses valid register JSON into RegisterMessage" do
      assert {:ok, %RegisterMessage{name: "test-agent", role: "tester"}} =
               Protocol.parse(valid_register_json())
    end

    test "parses valid heartbeat JSON into HeartbeatMessage" do
      assert {:ok, %HeartbeatMessage{agent_id: "agent-uuid-123", status: "idle"}} =
               Protocol.parse(valid_heartbeat_json())
    end

    test "parses valid task_result JSON into TaskResultMessage" do
      assert {:ok, %TaskResultMessage{task_id: "task-uuid-456", status: "completed"}} =
               Protocol.parse(valid_task_result_json())
    end

    test "parses valid status_update JSON into StatusUpdateMessage" do
      assert {:ok, %StatusUpdateMessage{agent_id: "agent-uuid-123", status: "working"}} =
               Protocol.parse(valid_status_update_json())
    end

    test "returns error for invalid JSON" do
      assert {:error, "invalid JSON: " <> _} = Protocol.parse("not json at all")
    end

    test "returns error for JSON that is not an object" do
      assert {:error, "invalid JSON: expected an object"} = Protocol.parse("[1,2,3]")
    end

    test "returns error for missing type field" do
      json = Jason.encode!(%{"protocol_version" => 1})
      assert {:error, "missing required field: type"} = Protocol.parse(json)
    end

    test "returns error for unknown type" do
      json = Jason.encode!(%{"type" => "unknown_msg", "protocol_version" => 1})
      assert {:error, "unknown message type: unknown_msg"} = Protocol.parse(json)
    end
  end

  # =========================================================
  # Protocol Version Tests
  # =========================================================

  describe "protocol version checking" do
    test "accepts protocol_version 1" do
      assert {:ok, %HeartbeatMessage{}} = Protocol.parse(valid_heartbeat_json())
    end

    test "rejects unsupported protocol version 2" do
      json =
        Jason.encode!(%{
          "type" => "heartbeat",
          "protocol_version" => 2,
          "agent_id" => "a",
          "status" => "idle"
        })

      assert {:error, "unsupported protocol version: 2, supported: [1]"} = Protocol.parse(json)
    end

    test "rejects missing protocol_version" do
      json = Jason.encode!(%{"type" => "heartbeat", "agent_id" => "a", "status" => "idle"})
      assert {:error, "missing required field: protocol_version"} = Protocol.parse(json)
    end

    test "rejects non-integer protocol_version" do
      json =
        Jason.encode!(%{
          "type" => "heartbeat",
          "protocol_version" => "one",
          "agent_id" => "a",
          "status" => "idle"
        })

      assert {:error, "invalid protocol_version: expected integer, got \"one\""} =
               Protocol.parse(json)
    end

    test "supported_versions returns [1]" do
      assert Protocol.supported_versions() == [1]
    end
  end

  # =========================================================
  # Register Validation Tests
  # =========================================================

  describe "validate_register/1" do
    test "valid register with all required fields" do
      payload = %{
        "type" => "register",
        "protocol_version" => 1,
        "agent" => %{
          "name" => "my-agent",
          "role" => "reviewer",
          "capabilities" => ["code-review"]
        },
        "auth" => %{"token" => "tok"}
      }

      assert {:ok, %RegisterMessage{name: "my-agent", role: "reviewer"}} =
               Protocol.validate_register(payload)
    end

    test "valid register with optional metadata" do
      payload = %{
        "type" => "register",
        "protocol_version" => 1,
        "agent" => %{
          "name" => "my-agent",
          "role" => "reviewer",
          "capabilities" => ["code-review"],
          "metadata" => %{"model" => "gpt-4"}
        },
        "auth" => %{"token" => "tok"}
      }

      assert {:ok, %RegisterMessage{metadata: %{"model" => "gpt-4"}}} =
               Protocol.validate_register(payload)
    end

    test "missing agent.name returns error" do
      payload = %{
        "type" => "register",
        "protocol_version" => 1,
        "agent" => %{"role" => "r", "capabilities" => ["a"]},
        "auth" => %{"token" => "t"}
      }

      assert {:error, errors} = Protocol.validate_register(payload)
      assert "missing required field: agent.name" in errors
    end

    test "missing agent.role returns error" do
      payload = %{
        "type" => "register",
        "protocol_version" => 1,
        "agent" => %{"name" => "n", "capabilities" => ["a"]},
        "auth" => %{"token" => "t"}
      }

      assert {:error, errors} = Protocol.validate_register(payload)
      assert "missing required field: agent.role" in errors
    end

    test "missing agent.capabilities returns error" do
      payload = %{
        "type" => "register",
        "protocol_version" => 1,
        "agent" => %{"name" => "n", "role" => "r"},
        "auth" => %{"token" => "t"}
      }

      assert {:error, errors} = Protocol.validate_register(payload)
      assert "missing required field: agent.capabilities" in errors
    end

    test "empty capabilities list returns error" do
      payload = %{
        "type" => "register",
        "protocol_version" => 1,
        "agent" => %{"name" => "n", "role" => "r", "capabilities" => []},
        "auth" => %{"token" => "t"}
      }

      assert {:error, errors} = Protocol.validate_register(payload)
      assert "capabilities must be a non-empty list" in errors
    end

    test "capabilities with non-string values returns error" do
      payload = %{
        "type" => "register",
        "protocol_version" => 1,
        "agent" => %{"name" => "n", "role" => "r", "capabilities" => [1, 2]},
        "auth" => %{"token" => "t"}
      }

      assert {:error, errors} = Protocol.validate_register(payload)
      assert "capabilities must contain only strings" in errors
    end

    test "missing auth.token returns error" do
      payload = %{
        "type" => "register",
        "protocol_version" => 1,
        "agent" => %{"name" => "n", "role" => "r", "capabilities" => ["a"]},
        "auth" => %{}
      }

      assert {:error, errors} = Protocol.validate_register(payload)
      assert "missing required field: auth.token" in errors
    end

    test "unknown fields at top level are rejected" do
      payload = %{
        "type" => "register",
        "protocol_version" => 1,
        "agent" => %{"name" => "n", "role" => "r", "capabilities" => ["a"]},
        "auth" => %{"token" => "t"},
        "extra_field" => "bad"
      }

      assert {:error, errors} = Protocol.validate_register(payload)
      assert "unknown field: extra_field" in errors
    end

    test "unknown fields in agent are rejected" do
      payload = %{
        "type" => "register",
        "protocol_version" => 1,
        "agent" => %{
          "name" => "n",
          "role" => "r",
          "capabilities" => ["a"],
          "unknown_nested" => true
        },
        "auth" => %{"token" => "t"}
      }

      assert {:error, errors} = Protocol.validate_register(payload)
      assert "unknown field: agent.unknown_nested" in errors
    end

    test "accumulates multiple errors" do
      payload = %{
        "type" => "register",
        "protocol_version" => 1,
        "agent" => %{},
        "auth" => %{}
      }

      assert {:error, errors} = Protocol.validate_register(payload)
      assert length(errors) >= 3
      assert "missing required field: agent.name" in errors
      assert "missing required field: agent.role" in errors
      assert "missing required field: auth.token" in errors
    end
  end

  # =========================================================
  # Heartbeat Validation Tests
  # =========================================================

  describe "validate_heartbeat/1" do
    test "valid heartbeat" do
      payload = %{
        "type" => "heartbeat",
        "protocol_version" => 1,
        "agent_id" => "uuid-123",
        "status" => "idle"
      }

      assert {:ok, %HeartbeatMessage{agent_id: "uuid-123", status: "idle"}} =
               Protocol.validate_heartbeat(payload)
    end

    test "valid heartbeat with optional load" do
      payload = %{
        "type" => "heartbeat",
        "protocol_version" => 1,
        "agent_id" => "uuid-123",
        "status" => "working",
        "load" => %{"active_tasks" => 3, "queue_depth" => 1}
      }

      assert {:ok, %HeartbeatMessage{load: %{"active_tasks" => 3}}} =
               Protocol.validate_heartbeat(payload)
    end

    test "missing agent_id returns error" do
      payload = %{"type" => "heartbeat", "protocol_version" => 1, "status" => "idle"}

      assert {:error, errors} = Protocol.validate_heartbeat(payload)
      assert "missing required field: agent_id" in errors
    end

    test "invalid status value returns error" do
      payload = %{
        "type" => "heartbeat",
        "protocol_version" => 1,
        "agent_id" => "a",
        "status" => "sleeping"
      }

      assert {:error, errors} = Protocol.validate_heartbeat(payload)
      assert Enum.any?(errors, &String.contains?(&1, "invalid status: sleeping"))
    end

    test "missing status returns error" do
      payload = %{"type" => "heartbeat", "protocol_version" => 1, "agent_id" => "a"}

      assert {:error, errors} = Protocol.validate_heartbeat(payload)
      assert "missing required field: status" in errors
    end

    test "unknown fields are rejected" do
      payload = %{
        "type" => "heartbeat",
        "protocol_version" => 1,
        "agent_id" => "a",
        "status" => "idle",
        "extra" => true
      }

      assert {:error, errors} = Protocol.validate_heartbeat(payload)
      assert "unknown field: extra" in errors
    end
  end

  # =========================================================
  # Task Result Validation Tests
  # =========================================================

  describe "validate_task_result/1" do
    test "valid task result" do
      payload = %{
        "type" => "task_result",
        "protocol_version" => 1,
        "task_id" => "task-1",
        "status" => "completed",
        "result" => %{"text" => "Done."}
      }

      assert {:ok, %TaskResultMessage{task_id: "task-1", status: "completed"}} =
               Protocol.validate_task_result(payload)
    end

    test "valid task result with optional tokens and duration_ms" do
      payload = %{
        "type" => "task_result",
        "protocol_version" => 1,
        "task_id" => "task-1",
        "status" => "completed",
        "result" => %{
          "text" => "Done.",
          "tokens" => %{"input" => 100, "output" => 50},
          "duration_ms" => 1500
        }
      }

      assert {:ok, %TaskResultMessage{result: result}} = Protocol.validate_task_result(payload)
      assert result["tokens"] == %{"input" => 100, "output" => 50}
      assert result["duration_ms"] == 1500
    end

    test "missing task_id returns error" do
      payload = %{
        "type" => "task_result",
        "protocol_version" => 1,
        "status" => "completed",
        "result" => %{"text" => "x"}
      }

      assert {:error, errors} = Protocol.validate_task_result(payload)
      assert "missing required field: task_id" in errors
    end

    test "invalid status value returns error" do
      payload = %{
        "type" => "task_result",
        "protocol_version" => 1,
        "task_id" => "t",
        "status" => "pending",
        "result" => %{"text" => "x"}
      }

      assert {:error, errors} = Protocol.validate_task_result(payload)
      assert Enum.any?(errors, &String.contains?(&1, "invalid status: pending"))
    end

    test "missing result returns error" do
      payload = %{
        "type" => "task_result",
        "protocol_version" => 1,
        "task_id" => "t",
        "status" => "completed"
      }

      assert {:error, errors} = Protocol.validate_task_result(payload)
      assert "missing required field: result" in errors
    end

    test "missing result.text returns error" do
      payload = %{
        "type" => "task_result",
        "protocol_version" => 1,
        "task_id" => "t",
        "status" => "completed",
        "result" => %{"tokens" => %{}}
      }

      assert {:error, errors} = Protocol.validate_task_result(payload)
      assert "missing required field: result.text" in errors
    end

    test "unknown fields are rejected" do
      payload = %{
        "type" => "task_result",
        "protocol_version" => 1,
        "task_id" => "t",
        "status" => "completed",
        "result" => %{"text" => "x"},
        "bonus" => true
      }

      assert {:error, errors} = Protocol.validate_task_result(payload)
      assert "unknown field: bonus" in errors
    end
  end

  # =========================================================
  # Status Update Validation Tests
  # =========================================================

  describe "validate_status_update/1" do
    test "valid status update" do
      payload = %{
        "type" => "status_update",
        "protocol_version" => 1,
        "agent_id" => "a-1",
        "status" => "draining"
      }

      assert {:ok, %StatusUpdateMessage{agent_id: "a-1", status: "draining"}} =
               Protocol.validate_status_update(payload)
    end

    test "valid status update with optional detail" do
      payload = %{
        "type" => "status_update",
        "protocol_version" => 1,
        "agent_id" => "a-1",
        "status" => "working",
        "detail" => "Processing task-42"
      }

      assert {:ok, %StatusUpdateMessage{detail: "Processing task-42"}} =
               Protocol.validate_status_update(payload)
    end

    test "missing agent_id returns error" do
      payload = %{
        "type" => "status_update",
        "protocol_version" => 1,
        "status" => "idle"
      }

      assert {:error, errors} = Protocol.validate_status_update(payload)
      assert "missing required field: agent_id" in errors
    end

    test "invalid status returns error" do
      payload = %{
        "type" => "status_update",
        "protocol_version" => 1,
        "agent_id" => "a",
        "status" => "crashed"
      }

      assert {:error, errors} = Protocol.validate_status_update(payload)
      assert Enum.any?(errors, &String.contains?(&1, "invalid status: crashed"))
    end
  end

  # =========================================================
  # Encode Tests
  # =========================================================

  describe "encode/1" do
    test "encodes RegisteredResponse to JSON" do
      msg = %RegisteredResponse{agent_id: "uuid-abc"}
      assert {:ok, json} = Protocol.encode(msg)
      decoded = Jason.decode!(json)
      assert decoded["type"] == "registered"
      assert decoded["agent_id"] == "uuid-abc"
    end

    test "encodes RegisteredResponse with mesh_info" do
      msg = %RegisteredResponse{
        agent_id: "uuid-abc",
        mesh_info: %{"peers" => 3, "run_id" => "run-1"}
      }

      assert {:ok, json} = Protocol.encode(msg)
      decoded = Jason.decode!(json)
      assert decoded["mesh_info"]["peers"] == 3
    end

    test "encodes TaskRequestMessage to JSON" do
      msg = %TaskRequestMessage{
        task_id: "task-1",
        prompt: "Review this code",
        timeout_ms: 30_000,
        tools: ["read_file"],
        context: %{"project" => "acme"}
      }

      assert {:ok, json} = Protocol.encode(msg)
      decoded = Jason.decode!(json)
      assert decoded["type"] == "task_request"
      assert decoded["task_id"] == "task-1"
      assert decoded["prompt"] == "Review this code"
      assert decoded["timeout_ms"] == 30_000
      assert decoded["tools"] == ["read_file"]
    end

    test "encodes PeerRequestMessage to JSON" do
      msg = %PeerRequestMessage{
        request_id: "req-1",
        from_agent: "agent-a",
        capability: "security-review",
        input: "Check this diff",
        timeout_ms: 60_000
      }

      assert {:ok, json} = Protocol.encode(msg)
      decoded = Jason.decode!(json)
      assert decoded["type"] == "peer_request"
      assert decoded["request_id"] == "req-1"
      assert decoded["from_agent"] == "agent-a"
      assert decoded["capability"] == "security-review"
      assert decoded["input"] == "Check this diff"
      assert decoded["timeout_ms"] == 60_000
    end
  end

  # =========================================================
  # Round-Trip Tests
  # =========================================================

  describe "round-trip parse -> to_map -> encode -> parse" do
    test "register message round-trips" do
      assert {:ok, %RegisterMessage{} = msg} = Protocol.parse(valid_register_json())
      map = RegisterMessage.to_map(msg)
      json = Jason.encode!(map)
      assert {:ok, %RegisterMessage{} = msg2} = Protocol.parse(json)
      assert msg.name == msg2.name
      assert msg.role == msg2.role
      assert msg.capabilities == msg2.capabilities
      assert msg.token == msg2.token
    end

    test "heartbeat message round-trips" do
      assert {:ok, %HeartbeatMessage{} = msg} = Protocol.parse(valid_heartbeat_json())
      map = HeartbeatMessage.to_map(msg)
      json = Jason.encode!(map)
      assert {:ok, %HeartbeatMessage{} = msg2} = Protocol.parse(json)
      assert msg.agent_id == msg2.agent_id
      assert msg.status == msg2.status
    end

    test "task_result message round-trips" do
      assert {:ok, %TaskResultMessage{} = msg} = Protocol.parse(valid_task_result_json())
      map = TaskResultMessage.to_map(msg)
      json = Jason.encode!(map)
      assert {:ok, %TaskResultMessage{} = msg2} = Protocol.parse(json)
      assert msg.task_id == msg2.task_id
      assert msg.status == msg2.status
      assert msg.result == msg2.result
    end

    test "status_update message round-trips" do
      assert {:ok, %StatusUpdateMessage{} = msg} = Protocol.parse(valid_status_update_json())
      map = StatusUpdateMessage.to_map(msg)
      json = Jason.encode!(map)
      assert {:ok, %StatusUpdateMessage{} = msg2} = Protocol.parse(json)
      assert msg.agent_id == msg2.agent_id
      assert msg.status == msg2.status
    end
  end

  # =========================================================
  # Message Struct new/1 and to_map/1 Tests
  # =========================================================

  describe "RegisteredResponse.new/1" do
    test "builds from string-keyed map" do
      assert {:ok, %RegisteredResponse{agent_id: "x"}} =
               RegisteredResponse.new(%{"agent_id" => "x"})
    end

    test "builds from atom-keyed map" do
      assert {:ok, %RegisteredResponse{agent_id: "x"}} =
               RegisteredResponse.new(%{agent_id: "x"})
    end

    test "returns error for missing agent_id" do
      assert {:error, ["missing required field: agent_id"]} = RegisteredResponse.new(%{})
    end
  end

  describe "TaskRequestMessage.new/1" do
    test "builds with all required fields" do
      data = %{
        "task_id" => "t1",
        "prompt" => "Do something",
        "timeout_ms" => 5000
      }

      assert {:ok, %TaskRequestMessage{task_id: "t1", prompt: "Do something"}} =
               TaskRequestMessage.new(data)
    end

    test "returns error for missing fields" do
      assert {:error, errors} = TaskRequestMessage.new(%{})
      assert length(errors) == 3
    end
  end

  describe "PeerRequestMessage.new/1" do
    test "builds with all required fields" do
      data = %{
        "request_id" => "r1",
        "from_agent" => "a1",
        "capability" => "review",
        "input" => "Check this",
        "timeout_ms" => 10_000
      }

      assert {:ok, %PeerRequestMessage{request_id: "r1"}} = PeerRequestMessage.new(data)
    end

    test "returns error for missing fields" do
      assert {:error, errors} = PeerRequestMessage.new(%{})
      assert length(errors) == 5
    end
  end
end
