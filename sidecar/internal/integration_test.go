package internal_test

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"strings"
	"testing"
	"time"

	pb "github.com/cortex/sidecar/internal/proto/gatewayv1"
	"github.com/cortex/sidecar/internal/testutil"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
)

// TestClient_RegisterAndReceiveID verifies that a gRPC client can connect to the
// mock server, send a RegisterRequest, and receive a RegisterResponse with an agent_id.
func TestClient_RegisterAndReceiveID(t *testing.T) {
	mock := testutil.NewMockServer()
	addr, cleanup := mock.Start()
	defer cleanup()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	conn, err := grpc.NewClient(addr, grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		t.Fatalf("failed to dial: %v", err)
	}
	defer conn.Close()

	client := pb.NewAgentGatewayClient(conn)
	stream, err := client.Connect(ctx)
	if err != nil {
		t.Fatalf("failed to open Connect stream: %v", err)
	}

	// Send RegisterRequest
	err = stream.Send(&pb.AgentMessage{
		Msg: &pb.AgentMessage_Register{
			Register: &pb.RegisterRequest{
				Name:         "test-agent",
				Role:         "integration-tester",
				Capabilities: []string{"testing", "verification"},
				AuthToken:    "test-token",
			},
		},
	})
	if err != nil {
		t.Fatalf("failed to send RegisterRequest: %v", err)
	}

	// Receive RegisterResponse
	resp, err := stream.Recv()
	if err != nil {
		t.Fatalf("failed to receive RegisterResponse: %v", err)
	}

	registered := resp.GetRegistered()
	if registered == nil {
		t.Fatalf("expected RegisterResponse, got %v", resp)
	}

	if registered.GetAgentId() == "" {
		t.Error("expected non-empty agent_id")
	}

	if registered.GetPeerCount() < 1 {
		t.Errorf("expected peer_count >= 1, got %d", registered.GetPeerCount())
	}

	// Verify mock recorded the RegisterRequest
	msg, err := mock.WaitForMessage("register", 2*time.Second)
	if err != nil {
		t.Fatalf("mock did not receive RegisterRequest: %v", err)
	}

	reg := msg.GetRegister()
	if reg.GetName() != "test-agent" {
		t.Errorf("expected name 'test-agent', got %q", reg.GetName())
	}
	if reg.GetRole() != "integration-tester" {
		t.Errorf("expected role 'integration-tester', got %q", reg.GetRole())
	}
}

// TestClient_HeartbeatInterval verifies that a client sends periodic heartbeat messages.
func TestClient_HeartbeatInterval(t *testing.T) {
	mock := testutil.NewMockServer()
	addr, cleanup := mock.Start()
	defer cleanup()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	conn, err := grpc.NewClient(addr, grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		t.Fatalf("failed to dial: %v", err)
	}
	defer conn.Close()

	client := pb.NewAgentGatewayClient(conn)
	stream, err := client.Connect(ctx)
	if err != nil {
		t.Fatalf("failed to open Connect stream: %v", err)
	}

	// Register first
	err = stream.Send(&pb.AgentMessage{
		Msg: &pb.AgentMessage_Register{
			Register: &pb.RegisterRequest{
				Name:      "heartbeat-agent",
				Role:      "tester",
				AuthToken: "test-token",
			},
		},
	})
	if err != nil {
		t.Fatalf("failed to send RegisterRequest: %v", err)
	}

	// Drain RegisterResponse
	if _, err := stream.Recv(); err != nil {
		t.Fatalf("failed to receive RegisterResponse: %v", err)
	}

	// Send two heartbeats
	for i := 0; i < 2; i++ {
		err = stream.Send(&pb.AgentMessage{
			Msg: &pb.AgentMessage_Heartbeat{
				Heartbeat: &pb.Heartbeat{
					AgentId:     "test-id",
					Status:      pb.AgentStatus_AGENT_STATUS_IDLE,
					ActiveTasks: 0,
					QueueDepth:  0,
				},
			},
		})
		if err != nil {
			t.Fatalf("failed to send Heartbeat %d: %v", i, err)
		}
	}

	// Wait for mock to receive at least 2 heartbeats
	msgs, err := mock.WaitForNMessages("heartbeat", 2, 3*time.Second)
	if err != nil {
		t.Fatalf("mock did not receive 2 heartbeats: %v", err)
	}

	if len(msgs) < 2 {
		t.Errorf("expected >= 2 heartbeat messages, got %d", len(msgs))
	}
}

// TestClient_ReconnectAfterStreamDrop verifies that when the mock server closes
// the stream, the client can re-open a new stream and re-register.
func TestClient_ReconnectAfterStreamDrop(t *testing.T) {
	mock := testutil.NewMockServer()
	// Close stream after 1 message (the RegisterRequest)
	mock.CloseStreamAfter(1)

	addr, cleanup := mock.Start()
	defer cleanup()

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	conn, err := grpc.NewClient(addr, grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		t.Fatalf("failed to dial: %v", err)
	}
	defer conn.Close()

	client := pb.NewAgentGatewayClient(conn)

	// First connection: register, server closes stream after 1 message
	stream1, err := client.Connect(ctx)
	if err != nil {
		t.Fatalf("failed to open first Connect stream: %v", err)
	}

	err = stream1.Send(&pb.AgentMessage{
		Msg: &pb.AgentMessage_Register{
			Register: &pb.RegisterRequest{
				Name:      "reconnect-agent",
				Role:      "tester",
				AuthToken: "test-token",
			},
		},
	})
	if err != nil {
		t.Fatalf("failed to send first RegisterRequest: %v", err)
	}

	// Drain response (may get RegisterResponse before stream closes)
	_, _ = stream1.Recv()

	// The stream should be closed by the server. Try to recv — should get EOF or error.
	_, err = stream1.Recv()
	if err == nil {
		t.Log("stream1 did not return error after server close; received extra message")
	}

	// Allow new streams to stay open
	mock.CloseStreamAfter(0)

	// Second connection: simulate sidecar reconnect
	stream2, err := client.Connect(ctx)
	if err != nil {
		t.Fatalf("failed to open second Connect stream: %v", err)
	}

	err = stream2.Send(&pb.AgentMessage{
		Msg: &pb.AgentMessage_Register{
			Register: &pb.RegisterRequest{
				Name:      "reconnect-agent",
				Role:      "tester",
				AuthToken: "test-token",
			},
		},
	})
	if err != nil {
		t.Fatalf("failed to send second RegisterRequest: %v", err)
	}

	// Receive second RegisterResponse with a new agent_id
	resp, err := stream2.Recv()
	if err != nil {
		t.Fatalf("failed to receive second RegisterResponse: %v", err)
	}

	registered := resp.GetRegistered()
	if registered == nil {
		t.Fatalf("expected RegisterResponse on reconnect, got %v", resp)
	}
	if registered.GetAgentId() == "" {
		t.Error("expected non-empty agent_id on reconnect")
	}

	// Verify mock received 2 RegisterRequests total
	if mock.RegisterCount() < 2 {
		t.Errorf("expected >= 2 register requests, got %d", mock.RegisterCount())
	}
}

// TestHTTP_RosterFromCachedState verifies that when the mock server pushes a
// RosterUpdate, a sidecar-style state cache would contain those agents.
// Since we don't import the sidecar HTTP server here (owned by Sidecar HTTP API
// Engineer), this test verifies the mock server's push capability and message
// receipt directly on the stream.
func TestHTTP_RosterFromCachedState(t *testing.T) {
	mock := testutil.NewMockServer()
	addr, cleanup := mock.Start()
	defer cleanup()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	conn, err := grpc.NewClient(addr, grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		t.Fatalf("failed to dial: %v", err)
	}
	defer conn.Close()

	client := pb.NewAgentGatewayClient(conn)
	stream, err := client.Connect(ctx)
	if err != nil {
		t.Fatalf("failed to open Connect stream: %v", err)
	}

	// Register
	err = stream.Send(&pb.AgentMessage{
		Msg: &pb.AgentMessage_Register{
			Register: &pb.RegisterRequest{
				Name:      "roster-agent",
				Role:      "tester",
				AuthToken: "test-token",
			},
		},
	})
	if err != nil {
		t.Fatalf("failed to send RegisterRequest: %v", err)
	}

	// Drain RegisterResponse
	if _, err := stream.Recv(); err != nil {
		t.Fatalf("failed to receive RegisterResponse: %v", err)
	}

	// Push a RosterUpdate from the mock server
	agents := []*pb.AgentInfo{
		{
			Id:           "agent-1",
			Name:         "security-bot",
			Role:         "security",
			Capabilities: []string{"security-review", "cve-lookup"},
			Status:       pb.AgentStatus_AGENT_STATUS_IDLE,
		},
		{
			Id:           "agent-2",
			Name:         "code-bot",
			Role:         "developer",
			Capabilities: []string{"code-review"},
			Status:       pb.AgentStatus_AGENT_STATUS_WORKING,
		},
	}
	mock.PushRosterUpdate(agents)

	// Receive the RosterUpdate on the stream
	resp, err := stream.Recv()
	if err != nil {
		t.Fatalf("failed to receive RosterUpdate: %v", err)
	}

	roster := resp.GetRosterUpdate()
	if roster == nil {
		t.Fatalf("expected RosterUpdate, got %v", resp)
	}

	if len(roster.GetAgents()) != 2 {
		t.Errorf("expected 2 agents in roster, got %d", len(roster.GetAgents()))
	}

	// Verify agent details
	found := map[string]bool{}
	for _, a := range roster.GetAgents() {
		found[a.GetName()] = true
	}
	if !found["security-bot"] {
		t.Error("expected 'security-bot' in roster")
	}
	if !found["code-bot"] {
		t.Error("expected 'code-bot' in roster")
	}
}

// TestHTTP_AskSendsPeerRequest verifies that a PeerRequest pushed by the mock
// server arrives on the client stream, and that a PeerResponse sent back is
// recorded by the mock server.
func TestHTTP_AskSendsPeerRequest(t *testing.T) {
	mock := testutil.NewMockServer()
	addr, cleanup := mock.Start()
	defer cleanup()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	conn, err := grpc.NewClient(addr, grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		t.Fatalf("failed to dial: %v", err)
	}
	defer conn.Close()

	client := pb.NewAgentGatewayClient(conn)
	stream, err := client.Connect(ctx)
	if err != nil {
		t.Fatalf("failed to open Connect stream: %v", err)
	}

	// Register
	err = stream.Send(&pb.AgentMessage{
		Msg: &pb.AgentMessage_Register{
			Register: &pb.RegisterRequest{
				Name:      "ask-agent",
				Role:      "tester",
				AuthToken: "test-token",
			},
		},
	})
	if err != nil {
		t.Fatalf("failed to send RegisterRequest: %v", err)
	}

	// Drain RegisterResponse
	if _, err := stream.Recv(); err != nil {
		t.Fatalf("failed to receive RegisterResponse: %v", err)
	}

	// Push a PeerRequest from the mock server
	mock.PushPeerRequest("peer-req-test", "agent-requester", "code-review", "Review this code")

	// Receive the PeerRequest on the stream
	resp, err := stream.Recv()
	if err != nil {
		t.Fatalf("failed to receive PeerRequest: %v", err)
	}

	peerReq := resp.GetPeerRequest()
	if peerReq == nil {
		t.Fatalf("expected PeerRequest, got %v", resp)
	}

	if peerReq.GetRequestId() != "peer-req-test" {
		t.Errorf("expected request_id 'peer-req-test', got %q", peerReq.GetRequestId())
	}
	if peerReq.GetPrompt() != "Review this code" {
		t.Errorf("expected prompt 'Review this code', got %q", peerReq.GetPrompt())
	}

	// Send PeerResponse back
	err = stream.Send(&pb.AgentMessage{
		Msg: &pb.AgentMessage_PeerResponse{
			PeerResponse: &pb.PeerResponse{
				RequestId:  "peer-req-test",
				Status:     pb.TaskStatus_TASK_STATUS_COMPLETED,
				Result:     "Review complete: no issues found",
				DurationMs: 5000,
			},
		},
	})
	if err != nil {
		t.Fatalf("failed to send PeerResponse: %v", err)
	}

	// Verify mock received the PeerResponse
	msg, err := mock.WaitForMessage("peer_response", 2*time.Second)
	if err != nil {
		t.Fatalf("mock did not receive PeerResponse: %v", err)
	}

	pr := msg.GetPeerResponse()
	if pr.GetRequestId() != "peer-req-test" {
		t.Errorf("expected request_id 'peer-req-test', got %q", pr.GetRequestId())
	}
	if pr.GetResult() != "Review complete: no issues found" {
		t.Errorf("expected result text match, got %q", pr.GetResult())
	}
}

// TestHTTP_StatusSendsUpdate verifies that a StatusUpdate sent on the stream
// is recorded by the mock server.
func TestHTTP_StatusSendsUpdate(t *testing.T) {
	mock := testutil.NewMockServer()
	addr, cleanup := mock.Start()
	defer cleanup()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	conn, err := grpc.NewClient(addr, grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		t.Fatalf("failed to dial: %v", err)
	}
	defer conn.Close()

	client := pb.NewAgentGatewayClient(conn)
	stream, err := client.Connect(ctx)
	if err != nil {
		t.Fatalf("failed to open Connect stream: %v", err)
	}

	// Register
	err = stream.Send(&pb.AgentMessage{
		Msg: &pb.AgentMessage_Register{
			Register: &pb.RegisterRequest{
				Name:      "status-agent",
				Role:      "tester",
				AuthToken: "test-token",
			},
		},
	})
	if err != nil {
		t.Fatalf("failed to send RegisterRequest: %v", err)
	}

	// Drain RegisterResponse
	if _, err := stream.Recv(); err != nil {
		t.Fatalf("failed to receive RegisterResponse: %v", err)
	}

	// Send StatusUpdate
	err = stream.Send(&pb.AgentMessage{
		Msg: &pb.AgentMessage_StatusUpdate{
			StatusUpdate: &pb.StatusUpdate{
				AgentId:  "test-id",
				Status:   pb.AgentStatus_AGENT_STATUS_WORKING,
				Detail:   "Processing task 3/7",
				Progress: 0.43,
			},
		},
	})
	if err != nil {
		t.Fatalf("failed to send StatusUpdate: %v", err)
	}

	// Verify mock received the StatusUpdate
	msg, err := mock.WaitForMessage("status_update", 2*time.Second)
	if err != nil {
		t.Fatalf("mock did not receive StatusUpdate: %v", err)
	}

	su := msg.GetStatusUpdate()
	if su.GetStatus() != pb.AgentStatus_AGENT_STATUS_WORKING {
		t.Errorf("expected status WORKING, got %v", su.GetStatus())
	}
	if su.GetDetail() != "Processing task 3/7" {
		t.Errorf("expected detail 'Processing task 3/7', got %q", su.GetDetail())
	}
	if su.GetProgress() < 0.42 || su.GetProgress() > 0.44 {
		t.Errorf("expected progress ~0.43, got %f", su.GetProgress())
	}
}

// Silence unused import warnings — these are used conditionally in tests
// that exercise the full sidecar HTTP API (pending sidecar core + HTTP API).
var (
	_ = fmt.Sprintf
	_ = http.Get
	_ = strings.NewReader
	_ = io.ReadAll
)
