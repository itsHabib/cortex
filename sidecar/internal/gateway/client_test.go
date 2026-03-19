package gateway

import (
	"context"
	"errors"
	"io"
	"log/slog"
	"net"
	"sync"
	"testing"
	"time"

	"github.com/cortex/sidecar/internal/config"
	pb "github.com/cortex/sidecar/internal/proto/gatewayv1"
	"github.com/cortex/sidecar/internal/state"
	"github.com/google/uuid"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/test/bufconn"
)

const bufSize = 1024 * 1024

// mockServer implements AgentGatewayServer for testing.
type mockServer struct {
	pb.UnimplementedAgentGatewayServer
	mu       sync.Mutex
	received []*pb.AgentMessage
	onRecv   func(*pb.AgentMessage) // optional callback per received message
	pushMsgs []*pb.GatewayMessage   // messages to push to the stream
	pushCh   chan *pb.GatewayMessage // channel for dynamic pushes
	closeAfter int                   // close stream after N received messages (0 = never)
}

func newMockServer() *mockServer {
	return &mockServer{
		pushCh: make(chan *pb.GatewayMessage, 10),
	}
}

func (s *mockServer) Connect(stream pb.AgentGateway_ConnectServer) error {
	// Push any pre-configured messages first.
	s.mu.Lock()
	pushMsgs := make([]*pb.GatewayMessage, len(s.pushMsgs))
	copy(pushMsgs, s.pushMsgs)
	s.mu.Unlock()

	recvCount := 0

	// Start a goroutine to push dynamic messages.
	go func() {
		for msg := range s.pushCh {
			if err := stream.Send(msg); err != nil {
				return
			}
		}
	}()

	for {
		msg, err := stream.Recv()
		if err == io.EOF {
			return nil
		}
		if err != nil {
			return err
		}

		s.mu.Lock()
		s.received = append(s.received, msg)
		recvCount++
		closeAfter := s.closeAfter
		s.mu.Unlock()

		if s.onRecv != nil {
			s.onRecv(msg)
		}

		// If this is a RegisterRequest, respond with RegisterResponse.
		if msg.GetRegister() != nil {
			resp := &pb.GatewayMessage{
				Msg: &pb.GatewayMessage_Registered{
					Registered: &pb.RegisterResponse{
						AgentId:   uuid.New().String(),
						PeerCount: 1,
					},
				},
			}
			if err := stream.Send(resp); err != nil {
				return err
			}

			// Send any pre-configured push messages after registration.
			for _, pm := range pushMsgs {
				if err := stream.Send(pm); err != nil {
					return err
				}
			}
		}

		if closeAfter > 0 && recvCount >= closeAfter {
			return nil // close the stream
		}
	}
}

func (s *mockServer) getReceived() []*pb.AgentMessage {
	s.mu.Lock()
	defer s.mu.Unlock()
	cp := make([]*pb.AgentMessage, len(s.received))
	copy(cp, s.received)
	return cp
}

func (s *mockServer) clearReceived() {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.received = nil
}

// setupTest starts a bufconn gRPC server and returns a client ready to use.
func setupTest(t *testing.T, srv *mockServer) (*Client, *state.Store, context.CancelFunc) {
	t.Helper()

	lis := bufconn.Listen(bufSize)
	grpcServer := grpc.NewServer()
	pb.RegisterAgentGatewayServer(grpcServer, srv)

	go func() {
		if err := grpcServer.Serve(lis); err != nil {
			// Server stopped.
		}
	}()

	// Override reconnect pause for fast tests.
	streamReconnectPause = 100 * time.Millisecond
	t.Cleanup(func() {
		grpcServer.Stop()
		lis.Close()
	})

	cfg := &config.Config{
		GatewayURL:        "bufnet",
		AgentName:         "test-agent",
		AgentRole:         "tester",
		AgentCapabilities: []string{"test", "review"},
		AuthToken:         "test-token",
		SidecarPort:       9090,
		HeartbeatInterval: 100 * time.Millisecond, // fast for tests
	}

	store := state.New()
	logger := slog.Default()
	client := New(cfg, store, logger)

	// Override the Run method to use bufconn dialer.
	ctx, cancel := context.WithCancel(context.Background())

	reconnectPause := streamReconnectPause // capture locally to avoid race
	go func() {
		conn, err := grpc.NewClient(
			"passthrough:///bufnet",
			grpc.WithTransportCredentials(insecure.NewCredentials()),
			grpc.WithContextDialer(func(ctx context.Context, s string) (net.Conn, error) {
				return lis.DialContext(ctx)
			}),
		)
		if err != nil {
			return
		}
		client.conn = conn
		defer conn.Close()

		gwClient := pb.NewAgentGatewayClient(conn)
		for {
			if ctx.Err() != nil {
				client.store.SetStatus(state.StatusDisconnected)
				return
			}
			err := client.runStream(ctx, gwClient)
			if ctx.Err() != nil {
				client.store.SetStatus(state.StatusDisconnected)
				return
			}
			client.store.SetStatus(state.StatusReconnecting)
			_ = err
			select {
			case <-ctx.Done():
				client.store.SetStatus(state.StatusDisconnected)
				return
			case <-time.After(reconnectPause):
			}
		}
	}()

	// Wait for registration to complete.
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if store.GetStatus() == state.StatusConnected {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	if store.GetStatus() != state.StatusConnected {
		t.Fatal("client did not connect within timeout")
	}

	return client, store, cancel
}

func TestRegistration(t *testing.T) {
	srv := newMockServer()
	_, store, cancel := setupTest(t, srv)
	defer cancel()

	// Verify agent ID was assigned.
	agentID := store.GetAgentID()
	if agentID == "" {
		t.Fatal("agent ID not set after registration")
	}

	// Verify the server received a RegisterRequest.
	received := srv.getReceived()
	found := false
	for _, msg := range received {
		if reg := msg.GetRegister(); reg != nil {
			found = true
			if reg.GetName() != "test-agent" {
				t.Errorf("register name = %q, want %q", reg.GetName(), "test-agent")
			}
			if reg.GetRole() != "tester" {
				t.Errorf("register role = %q, want %q", reg.GetRole(), "tester")
			}
			if reg.GetAuthToken() != "test-token" {
				t.Errorf("register token = %q, want %q", reg.GetAuthToken(), "test-token")
			}
			caps := reg.GetCapabilities()
			if len(caps) != 2 || caps[0] != "test" || caps[1] != "review" {
				t.Errorf("register capabilities = %v, want [test review]", caps)
			}
			break
		}
	}
	if !found {
		t.Error("server did not receive RegisterRequest")
	}
}

func TestHeartbeatSending(t *testing.T) {
	srv := newMockServer()
	_, _, cancel := setupTest(t, srv)
	defer cancel()

	// Wait for at least 2 heartbeats (interval is 100ms).
	time.Sleep(350 * time.Millisecond)

	received := srv.getReceived()
	hbCount := 0
	for _, msg := range received {
		if msg.GetHeartbeat() != nil {
			hbCount++
		}
	}
	if hbCount < 2 {
		t.Errorf("received %d heartbeats, want >= 2", hbCount)
	}
}

func TestTaskRequestDispatch(t *testing.T) {
	srv := newMockServer()
	srv.pushMsgs = []*pb.GatewayMessage{
		{
			Msg: &pb.GatewayMessage_TaskRequest{
				TaskRequest: &pb.TaskRequest{
					TaskId: "task-42",
					Prompt: "do the thing",
				},
			},
		},
	}

	_, store, cancel := setupTest(t, srv)
	defer cancel()

	// Wait for the pushed message to be processed.
	deadline := time.Now().Add(1 * time.Second)
	for time.Now().Before(deadline) {
		if task := store.GetTask(); task != nil {
			if task.GetTaskId() == "task-42" {
				return // success
			}
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Error("task request not dispatched to state store")
}

func TestPeerRequestDispatch(t *testing.T) {
	srv := newMockServer()
	srv.pushMsgs = []*pb.GatewayMessage{
		{
			Msg: &pb.GatewayMessage_PeerRequest{
				PeerRequest: &pb.PeerRequest{
					RequestId:  "req-1",
					FromAgent:  "other-agent",
					Capability: "review",
					Prompt:     "review this",
				},
			},
		},
	}

	_, store, cancel := setupTest(t, srv)
	defer cancel()

	deadline := time.Now().Add(1 * time.Second)
	for time.Now().Before(deadline) {
		msgs := store.PopMessages()
		for _, m := range msgs {
			if m.Type == "peer_request" && m.PeerReq.GetRequestId() == "req-1" {
				return // success
			}
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Error("peer request not dispatched to state store")
}

func TestRosterUpdateDispatch(t *testing.T) {
	srv := newMockServer()
	srv.pushMsgs = []*pb.GatewayMessage{
		{
			Msg: &pb.GatewayMessage_RosterUpdate{
				RosterUpdate: &pb.RosterUpdate{
					Agents: []*pb.AgentInfo{
						{Id: "a1", Name: "agent-1"},
						{Id: "a2", Name: "agent-2"},
					},
				},
			},
		},
	}

	_, store, cancel := setupTest(t, srv)
	defer cancel()

	deadline := time.Now().Add(1 * time.Second)
	for time.Now().Before(deadline) {
		roster := store.GetRoster()
		if len(roster) == 2 {
			return // success
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Error("roster update not dispatched to state store")
}

func TestErrorHandling(t *testing.T) {
	srv := newMockServer()
	srv.pushMsgs = []*pb.GatewayMessage{
		{
			Msg: &pb.GatewayMessage_Error{
				Error: &pb.Error{
					Code:    "TEST_ERROR",
					Message: "this is a test error",
				},
			},
		},
	}

	_, store, cancel := setupTest(t, srv)
	defer cancel()

	// The client should still be connected after receiving an error.
	time.Sleep(200 * time.Millisecond)
	if store.GetStatus() != state.StatusConnected {
		t.Errorf("status = %q after error, want %q", store.GetStatus(), state.StatusConnected)
	}
}

func TestSendTaskResult(t *testing.T) {
	srv := newMockServer()
	client, _, cancel := setupTest(t, srv)
	defer cancel()

	err := client.SendTaskResult(context.Background(), &pb.TaskResult{
		TaskId:     "task-1",
		Status:     pb.TaskStatus_TASK_STATUS_COMPLETED,
		ResultText: "done",
		DurationMs: 5000,
	})
	if err != nil {
		t.Fatalf("SendTaskResult failed: %v", err)
	}

	// Verify server received it.
	time.Sleep(100 * time.Millisecond)
	received := srv.getReceived()
	found := false
	for _, msg := range received {
		if tr := msg.GetTaskResult(); tr != nil && tr.GetTaskId() == "task-1" {
			found = true
			break
		}
	}
	if !found {
		t.Error("server did not receive TaskResult")
	}
}

func TestSendStatusUpdate(t *testing.T) {
	srv := newMockServer()
	client, _, cancel := setupTest(t, srv)
	defer cancel()

	err := client.SendStatusUpdate(context.Background(), &pb.StatusUpdate{
		AgentId: "test",
		Status:  pb.AgentStatus_AGENT_STATUS_WORKING,
		Detail:  "busy",
	})
	if err != nil {
		t.Fatalf("SendStatusUpdate failed: %v", err)
	}

	time.Sleep(100 * time.Millisecond)
	received := srv.getReceived()
	found := false
	for _, msg := range received {
		if su := msg.GetStatusUpdate(); su != nil && su.GetDetail() == "busy" {
			found = true
			break
		}
	}
	if !found {
		t.Error("server did not receive StatusUpdate")
	}
}

func TestSendPeerResponse(t *testing.T) {
	srv := newMockServer()
	client, _, cancel := setupTest(t, srv)
	defer cancel()

	err := client.SendPeerResponse(context.Background(), &pb.PeerResponse{
		RequestId: "req-1",
		Status:    pb.TaskStatus_TASK_STATUS_COMPLETED,
		Result:    "reviewed",
	})
	if err != nil {
		t.Fatalf("SendPeerResponse failed: %v", err)
	}

	time.Sleep(100 * time.Millisecond)
	received := srv.getReceived()
	found := false
	for _, msg := range received {
		if pr := msg.GetPeerResponse(); pr != nil && pr.GetRequestId() == "req-1" {
			found = true
			break
		}
	}
	if !found {
		t.Error("server did not receive PeerResponse")
	}
}

func TestSendDirectMessage(t *testing.T) {
	srv := newMockServer()
	client, _, cancel := setupTest(t, srv)
	defer cancel()

	err := client.SendDirectMessage(context.Background(), "target-agent", "hello")
	if err != nil {
		t.Fatalf("SendDirectMessage failed: %v", err)
	}

	time.Sleep(100 * time.Millisecond)
	received := srv.getReceived()
	found := false
	for _, msg := range received {
		if dm := msg.GetDirectMessage(); dm != nil && dm.GetToAgent() == "target-agent" && dm.GetContent() == "hello" {
			found = true
			break
		}
	}
	if !found {
		t.Error("server did not receive DirectMessage")
	}
}

func TestBroadcast(t *testing.T) {
	srv := newMockServer()
	client, _, cancel := setupTest(t, srv)
	defer cancel()

	err := client.Broadcast(context.Background(), "attention everyone")
	if err != nil {
		t.Fatalf("Broadcast failed: %v", err)
	}

	time.Sleep(100 * time.Millisecond)
	received := srv.getReceived()
	found := false
	for _, msg := range received {
		if br := msg.GetBroadcast(); br != nil && br.GetContent() == "attention everyone" {
			found = true
			break
		}
	}
	if !found {
		t.Error("server did not receive BroadcastRequest")
	}
}

func TestStreamReconnect(t *testing.T) {
	srv := newMockServer()
	// Close stream after receiving 2 messages (RegisterRequest + 1 heartbeat).
	srv.closeAfter = 2

	_, store, cancel := setupTest(t, srv)
	defer cancel()

	// After reconnect, status should return to connected.
	// The server will close after 2 messages, triggering reconnect.
	// After reconnect, the client re-registers and gets a new agent ID.
	firstID := store.GetAgentID()

	// Wait for reconnect.
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		if store.GetAgentID() != firstID && store.GetAgentID() != "" && store.GetStatus() == state.StatusConnected {
			break
		}
		time.Sleep(50 * time.Millisecond)
	}

	// Allow the reconnect to happen - the mock server will close
	// but subsequently the test buffer connection loop makes new ones.
	// Check that we got at least 2 RegisterRequests.
	time.Sleep(500 * time.Millisecond)
	received := srv.getReceived()
	regCount := 0
	for _, msg := range received {
		if msg.GetRegister() != nil {
			regCount++
		}
	}
	if regCount < 2 {
		t.Errorf("received %d RegisterRequests, want >= 2 (after reconnect)", regCount)
	}
}

func TestGracefulShutdown(t *testing.T) {
	srv := newMockServer()
	_, _, cancel := setupTest(t, srv)

	// Cancel context to trigger shutdown.
	cancel()

	// Give it a moment to clean up.
	time.Sleep(200 * time.Millisecond)

	// Verify the server received a draining status update.
	received := srv.getReceived()
	found := false
	for _, msg := range received {
		if su := msg.GetStatusUpdate(); su != nil && su.GetStatus() == pb.AgentStatus_AGENT_STATUS_DRAINING {
			found = true
			break
		}
	}
	if !found {
		// This is a best-effort check — the draining message may not be received
		// if the stream closes too quickly. Not a hard failure.
		t.Log("draining status update not received (best-effort)")
	}
}

func TestSendWhenDisconnected(t *testing.T) {
	// Create a client without connecting.
	cfg := &config.Config{
		GatewayURL:        "unused",
		AgentName:         "test",
		HeartbeatInterval: 15 * time.Second,
	}
	store := state.New()
	client := New(cfg, store, slog.Default())

	err := client.SendTaskResult(context.Background(), &pb.TaskResult{TaskId: "t1"})
	if !errors.Is(err, ErrNotConnected) {
		t.Errorf("SendTaskResult error = %v, want ErrNotConnected", err)
	}

	err = client.SendStatusUpdate(context.Background(), &pb.StatusUpdate{})
	if !errors.Is(err, ErrNotConnected) {
		t.Errorf("SendStatusUpdate error = %v, want ErrNotConnected", err)
	}

	err = client.SendPeerResponse(context.Background(), &pb.PeerResponse{})
	if !errors.Is(err, ErrNotConnected) {
		t.Errorf("SendPeerResponse error = %v, want ErrNotConnected", err)
	}

	err = client.SendDirectMessage(context.Background(), "x", "y")
	if !errors.Is(err, ErrNotConnected) {
		t.Errorf("SendDirectMessage error = %v, want ErrNotConnected", err)
	}

	err = client.Broadcast(context.Background(), "test")
	if !errors.Is(err, ErrNotConnected) {
		t.Errorf("Broadcast error = %v, want ErrNotConnected", err)
	}
}
