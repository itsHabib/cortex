package api

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"time"
)

// mockState implements StateReader for testing.
type mockState struct {
	connected bool
	agentID   string
	uptime    time.Duration
	status    string
	roster    []AgentInfo
	messages  []Message
	task      *TaskInfo
}

func (m *mockState) GetRoster() []AgentInfo   { return m.roster }
func (m *mockState) PopMessages() []Message   { return m.messages }
func (m *mockState) GetTask() *TaskInfo       { return m.task }
func (m *mockState) IsConnected() bool        { return m.connected }
func (m *mockState) GetAgentID() string       { return m.agentID }
func (m *mockState) GetUptime() time.Duration { return m.uptime }
func (m *mockState) GetStatus() string        { return m.status }
func (m *mockState) GetConnectionInfo() ConnectionInfo {
	return ConnectionInfo{
		AgentID:   m.agentID,
		Status:    m.status,
		PeerCount: len(m.roster),
	}
}

func (m *mockState) GetAgent(id string) (AgentInfo, bool) {
	for _, a := range m.roster {
		if a.ID == id {
			return a, true
		}
	}
	return AgentInfo{}, false
}

func (m *mockState) GetCapable(capability string) []AgentInfo {
	var result []AgentInfo
	for _, a := range m.roster {
		for _, c := range a.Capabilities {
			if c == capability {
				result = append(result, a)
				break
			}
		}
	}
	return result
}

// mockGateway implements GatewayClient for testing.
type mockGateway struct {
	sendMessageCalls  []sendMessageCall
	broadcastCalls    []string
	peerRequestResult *PeerResult
	peerRequestErr    error
	statusUpdateErr   error
	taskResultErr     error
	sendMessageErr    error
	broadcastErr      error
}

type sendMessageCall struct {
	ToAgent string
	Content string
}

func (m *mockGateway) SendDirectMessage(ctx context.Context, toAgent, content string) error {
	m.sendMessageCalls = append(m.sendMessageCalls, sendMessageCall{toAgent, content})
	return m.sendMessageErr
}

func (m *mockGateway) Broadcast(ctx context.Context, content string) error {
	m.broadcastCalls = append(m.broadcastCalls, content)
	return m.broadcastErr
}

func (m *mockGateway) SendPeerRequest(ctx context.Context, agentID, capability, prompt string, timeoutMs int64) (*PeerResult, error) {
	if m.peerRequestErr != nil {
		// Check if the error should be context-driven
		if errors.Is(m.peerRequestErr, context.DeadlineExceeded) {
			// Wait for context to expire to simulate timeout
			<-ctx.Done()
			return nil, ctx.Err()
		}
		return nil, m.peerRequestErr
	}
	return m.peerRequestResult, nil
}

func (m *mockGateway) SendStatusUpdate(ctx context.Context, status, detail string, progress float64) error {
	return m.statusUpdateErr
}

func (m *mockGateway) SendTaskResult(ctx context.Context, taskID, status, resultText string, durationMs int64, inputTokens, outputTokens int32) error {
	return m.taskResultErr
}

// newTestServer creates a test HTTP handler with mock dependencies.
func newTestServer(state *mockState, gateway *mockGateway) http.Handler {
	if state == nil {
		state = &mockState{}
	}
	if gateway == nil {
		gateway = &mockGateway{}
	}
	logger := slog.Default()
	s := NewServer(state, gateway, logger)
	return NewRouter(s)
}
