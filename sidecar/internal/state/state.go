// Package state provides a thread-safe in-memory store for sidecar state.
package state

import (
	"sync"
	"time"

	pb "github.com/cortex/sidecar/internal/proto/gatewayv1"
)

// ConnectionStatus represents the sidecar's connection state.
type ConnectionStatus string

const (
	StatusConnecting   ConnectionStatus = "connecting"
	StatusConnected    ConnectionStatus = "connected"
	StatusDisconnected ConnectionStatus = "disconnected"
	StatusReconnecting ConnectionStatus = "reconnecting"
)

// Message wraps an inbound message from the gateway stream.
type Message struct {
	Type      string // "task_request" | "peer_request" | "direct_message"
	TaskReq   *pb.TaskRequest
	PeerReq   *pb.PeerRequest
	DirectMsg *pb.DirectMessage
	Received  time.Time
}

// ConnectionInfo is a snapshot of the current connection state.
type ConnectionInfo struct {
	AgentID   string           `json:"agent_id"`
	Status    ConnectionStatus `json:"status"`
	PeerCount int              `json:"peer_count"`
}

// Store holds the sidecar's in-memory state with mutex-protected access.
type Store struct {
	mu              sync.RWMutex
	agentID         string
	status          ConnectionStatus
	roster          []*pb.AgentInfo
	pendingMessages []Message
	currentTask     *pb.TaskRequest
	startedAt       time.Time
}

// New creates a new Store with initial state.
func New() *Store {
	return &Store{
		status:    StatusConnecting,
		startedAt: time.Now(),
	}
}

// GetAgentID returns the assigned agent ID.
func (s *Store) GetAgentID() string {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.agentID
}

// SetAgentID stores the agent ID assigned by the gateway.
func (s *Store) SetAgentID(id string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.agentID = id
}

// GetStatus returns the current connection status.
func (s *Store) GetStatus() ConnectionStatus {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.status
}

// SetStatus updates the connection status.
func (s *Store) SetStatus(status ConnectionStatus) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.status = status
}

// IsConnected returns true if the status is connected.
func (s *Store) IsConnected() bool {
	return s.GetStatus() == StatusConnected
}

// GetRoster returns a copy of the cached agent roster.
func (s *Store) GetRoster() []*pb.AgentInfo {
	s.mu.RLock()
	defer s.mu.RUnlock()
	if s.roster == nil {
		return nil
	}
	// Return a copy of the slice header to prevent data races on the slice itself.
	cp := make([]*pb.AgentInfo, len(s.roster))
	copy(cp, s.roster)
	return cp
}

// SetRoster replaces the cached roster.
func (s *Store) SetRoster(agents []*pb.AgentInfo) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.roster = agents
}

// GetAgent looks up a specific agent by ID from the cached roster.
func (s *Store) GetAgent(id string) (*pb.AgentInfo, bool) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	for _, a := range s.roster {
		if a.GetId() == id {
			return a, true
		}
	}
	return nil, false
}

// GetCapable returns agents from the cached roster that advertise the given capability.
func (s *Store) GetCapable(capability string) []*pb.AgentInfo {
	s.mu.RLock()
	defer s.mu.RUnlock()
	var result []*pb.AgentInfo
	for _, a := range s.roster {
		for _, c := range a.GetCapabilities() {
			if c == capability {
				result = append(result, a)
				break
			}
		}
	}
	return result
}

// PushMessage enqueues an inbound message.
func (s *Store) PushMessage(msg Message) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.pendingMessages = append(s.pendingMessages, msg)
}

// PopMessages atomically drains and returns all pending messages.
func (s *Store) PopMessages() []Message {
	s.mu.Lock()
	defer s.mu.Unlock()
	msgs := s.pendingMessages
	s.pendingMessages = nil
	return msgs
}

// GetTask returns the current task assignment, or nil if none.
func (s *Store) GetTask() *pb.TaskRequest {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.currentTask
}

// SetTask sets or clears the current task assignment.
func (s *Store) SetTask(task *pb.TaskRequest) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.currentTask = task
}

// GetConnectionInfo returns a snapshot of the connection state.
func (s *Store) GetConnectionInfo() ConnectionInfo {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return ConnectionInfo{
		AgentID:   s.agentID,
		Status:    s.status,
		PeerCount: len(s.roster),
	}
}

// GetUptime returns the duration since the store was created.
func (s *Store) GetUptime() time.Duration {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return time.Since(s.startedAt)
}
