// Package testutil provides test infrastructure for sidecar integration tests.
//
// MockServer implements the AgentGateway gRPC service for testing the sidecar
// client without requiring the real Elixir gateway. It records all received
// messages for assertion and supports on-demand push of gateway messages.
package testutil

import (
	"fmt"
	"io"
	"log/slog"
	"net"
	"sync"
	"time"

	pb "github.com/cortex/sidecar/internal/proto/gatewayv1"
	"github.com/google/uuid"
	"google.golang.org/grpc"
)

// MockServer implements the AgentGateway gRPC service for testing.
type MockServer struct {
	pb.UnimplementedAgentGatewayServer

	mu            sync.Mutex
	received      []*pb.AgentMessage
	streams       []grpc.BidiStreamingServer[pb.AgentMessage, pb.GatewayMessage]
	closeAfter    int // close stream after N received messages (0 = never)
	waiters       []waiter
	logger        *slog.Logger
	registerCount int // number of RegisterRequests received
}

type waiter struct {
	msgType string
	ch      chan *pb.AgentMessage
}

// NewMockServer creates a new mock gRPC server instance.
func NewMockServer() *MockServer {
	return &MockServer{
		logger: slog.Default(),
	}
}

// Start starts the mock gRPC server on an OS-assigned port.
// Returns the address (host:port) and a cleanup function.
func (s *MockServer) Start() (addr string, cleanup func()) {
	lis, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		panic(fmt.Sprintf("testutil: failed to listen: %v", err))
	}

	grpcServer := grpc.NewServer()
	pb.RegisterAgentGatewayServer(grpcServer, s)

	go func() {
		if err := grpcServer.Serve(lis); err != nil {
			s.logger.Info("mock server stopped", "error", err)
		}
	}()

	return lis.Addr().String(), func() {
		grpcServer.GracefulStop()
	}
}

// Connect implements the AgentGateway.Connect bidirectional streaming RPC.
func (s *MockServer) Connect(stream grpc.BidiStreamingServer[pb.AgentMessage, pb.GatewayMessage]) error {
	s.mu.Lock()
	s.streams = append(s.streams, stream)
	s.mu.Unlock()

	msgCount := 0

	for {
		msg, err := stream.Recv()
		if err == io.EOF {
			return nil
		}
		if err != nil {
			return err
		}

		msgCount++

		s.mu.Lock()
		s.received = append(s.received, msg)

		// Handle RegisterRequest: respond with RegisterResponse
		if reg := msg.GetRegister(); reg != nil {
			s.registerCount++
			agentID := uuid.New().String()
			resp := &pb.GatewayMessage{
				Msg: &pb.GatewayMessage_Registered{
					Registered: &pb.RegisterResponse{
						AgentId:   agentID,
						PeerCount: int32(s.registerCount),
					},
				},
			}
			s.mu.Unlock()

			if err := stream.Send(resp); err != nil {
				return err
			}

			s.logger.Info("mock: registered agent",
				"name", reg.GetName(),
				"agent_id", agentID,
			)
		} else {
			s.mu.Unlock()

			s.logger.Info("mock: received message",
				"type", agentMessageType(msg),
			)
		}

		// Notify any waiters
		s.notifyWaiters(msg)

		// Check if we should close the stream after N messages
		s.mu.Lock()
		closeAfter := s.closeAfter
		s.mu.Unlock()

		if closeAfter > 0 && msgCount >= closeAfter {
			s.logger.Info("mock: closing stream after configured message count",
				"count", msgCount,
			)
			return nil
		}
	}
}

// PushTaskRequest pushes a TaskRequest to all connected streams.
func (s *MockServer) PushTaskRequest(taskID, prompt string) {
	msg := &pb.GatewayMessage{
		Msg: &pb.GatewayMessage_TaskRequest{
			TaskRequest: &pb.TaskRequest{
				TaskId:    taskID,
				Prompt:    prompt,
				TimeoutMs: 60000,
			},
		},
	}
	s.pushToAll(msg)
}

// PushPeerRequest pushes a PeerRequest to all connected streams.
func (s *MockServer) PushPeerRequest(requestID, from, capability, prompt string) {
	msg := &pb.GatewayMessage{
		Msg: &pb.GatewayMessage_PeerRequest{
			PeerRequest: &pb.PeerRequest{
				RequestId:  requestID,
				FromAgent:  from,
				Capability: capability,
				Prompt:     prompt,
				TimeoutMs:  30000,
			},
		},
	}
	s.pushToAll(msg)
}

// PushRosterUpdate pushes a RosterUpdate to all connected streams.
func (s *MockServer) PushRosterUpdate(agents []*pb.AgentInfo) {
	msg := &pb.GatewayMessage{
		Msg: &pb.GatewayMessage_RosterUpdate{
			RosterUpdate: &pb.RosterUpdate{
				Agents: agents,
			},
		},
	}
	s.pushToAll(msg)
}

// PushError pushes an Error message to all connected streams.
func (s *MockServer) PushError(code, message string) {
	msg := &pb.GatewayMessage{
		Msg: &pb.GatewayMessage_Error{
			Error: &pb.Error{
				Code:    code,
				Message: message,
			},
		},
	}
	s.pushToAll(msg)
}

// CloseStreamAfter configures the mock to close the stream after N received messages.
// Set to 0 to disable (default). This is useful for testing sidecar reconnect.
func (s *MockServer) CloseStreamAfter(n int) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.closeAfter = n
}

// ReceivedMessages returns all received AgentMessage values for assertion.
// Returns a copy to avoid data races.
func (s *MockServer) ReceivedMessages() []*pb.AgentMessage {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := make([]*pb.AgentMessage, len(s.received))
	copy(out, s.received)
	return out
}

// RegisterCount returns the number of RegisterRequests received.
func (s *MockServer) RegisterCount() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.registerCount
}

// WaitForMessage blocks until a message of the given type is received or timeout expires.
// Message types: "register", "heartbeat", "task_result", "status_update",
// "peer_response", "direct_message", "broadcast".
func (s *MockServer) WaitForMessage(msgType string, timeout time.Duration) (*pb.AgentMessage, error) {
	ch := make(chan *pb.AgentMessage, 1)

	s.mu.Lock()
	// Check if we already have a matching message
	for _, msg := range s.received {
		if agentMessageType(msg) == msgType {
			s.mu.Unlock()
			return msg, nil
		}
	}
	// Register a waiter
	s.waiters = append(s.waiters, waiter{msgType: msgType, ch: ch})
	s.mu.Unlock()

	select {
	case msg := <-ch:
		return msg, nil
	case <-time.After(timeout):
		return nil, fmt.Errorf("testutil: timed out waiting for message type %q after %v", msgType, timeout)
	}
}

// WaitForNMessages blocks until at least n messages of the given type are received.
func (s *MockServer) WaitForNMessages(msgType string, n int, timeout time.Duration) ([]*pb.AgentMessage, error) {
	deadline := time.Now().Add(timeout)

	for {
		s.mu.Lock()
		var matches []*pb.AgentMessage
		for _, msg := range s.received {
			if agentMessageType(msg) == msgType {
				matches = append(matches, msg)
			}
		}
		s.mu.Unlock()

		if len(matches) >= n {
			return matches[:n], nil
		}

		if time.Now().After(deadline) {
			return matches, fmt.Errorf(
				"testutil: timed out waiting for %d %q messages, got %d",
				n, msgType, len(matches),
			)
		}

		time.Sleep(50 * time.Millisecond)
	}
}

// Reset clears all recorded messages and resets the register count.
func (s *MockServer) Reset() {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.received = nil
	s.streams = nil
	s.registerCount = 0
	s.closeAfter = 0
}

// pushToAll sends a GatewayMessage to all connected streams.
func (s *MockServer) pushToAll(msg *pb.GatewayMessage) {
	s.mu.Lock()
	streams := make([]grpc.BidiStreamingServer[pb.AgentMessage, pb.GatewayMessage], len(s.streams))
	copy(streams, s.streams)
	s.mu.Unlock()

	for _, stream := range streams {
		if err := stream.Send(msg); err != nil {
			s.logger.Info("mock: failed to push message",
				"error", err,
			)
		}
	}
}

// notifyWaiters checks if any waiters match the received message and notifies them.
func (s *MockServer) notifyWaiters(msg *pb.AgentMessage) {
	msgType := agentMessageType(msg)

	s.mu.Lock()
	defer s.mu.Unlock()

	remaining := make([]waiter, 0, len(s.waiters))
	for _, w := range s.waiters {
		if w.msgType == msgType {
			select {
			case w.ch <- msg:
			default:
			}
		} else {
			remaining = append(remaining, w)
		}
	}
	s.waiters = remaining
}

// agentMessageType returns a string describing which oneof field is set in an AgentMessage.
func agentMessageType(msg *pb.AgentMessage) string {
	if msg == nil {
		return "unknown"
	}
	switch msg.GetMsg().(type) {
	case *pb.AgentMessage_Register:
		return "register"
	case *pb.AgentMessage_Heartbeat:
		return "heartbeat"
	case *pb.AgentMessage_TaskResult:
		return "task_result"
	case *pb.AgentMessage_StatusUpdate:
		return "status_update"
	case *pb.AgentMessage_PeerResponse:
		return "peer_response"
	case *pb.AgentMessage_DirectMessage:
		return "direct_message"
	case *pb.AgentMessage_Broadcast:
		return "broadcast"
	default:
		return "unknown"
	}
}
