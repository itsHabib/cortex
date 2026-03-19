// Package api implements the sidecar's local HTTP/JSON API that agents call
// to interact with the mesh through the sidecar.
package api

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"time"
)

// AgentInfo represents an agent in the mesh roster.
type AgentInfo struct {
	ID           string            `json:"id"`
	Name         string            `json:"name"`
	Role         string            `json:"role"`
	Capabilities []string          `json:"capabilities"`
	Status       string            `json:"status"`
	Metadata     map[string]string `json:"metadata"`
}

// Message represents an inbound message from the mesh.
type Message struct {
	ID        string    `json:"id"`
	FromAgent string    `json:"from_agent"`
	Content   string    `json:"content"`
	Timestamp time.Time `json:"timestamp"`
}

// TaskInfo represents a task assignment from the gateway.
type TaskInfo struct {
	TaskID    string            `json:"task_id"`
	Prompt    string            `json:"prompt"`
	TimeoutMs int64             `json:"timeout_ms"`
	Tools     []string          `json:"tools"`
	Context   map[string]string `json:"context"`
}

// PeerResult represents the result of a synchronous agent-to-agent invocation.
type PeerResult struct {
	Status     string `json:"status"`
	Result     string `json:"result"`
	DurationMs int64  `json:"duration_ms"`
}

// StateReader defines the read interface for the sidecar's local state store.
// The Sidecar Core Engineer implements this as state.Store.
type StateReader interface {
	GetRoster() []AgentInfo
	GetAgent(id string) (AgentInfo, bool)
	GetCapable(capability string) []AgentInfo
	PopMessages() []Message
	GetTask() *TaskInfo
	IsConnected() bool
	GetAgentID() string
	GetUptime() time.Duration
	GetStatus() string
	GetConnectionInfo() ConnectionInfo
}

// ConnectionInfo is a snapshot of the sidecar's connection state.
type ConnectionInfo struct {
	AgentID   string `json:"agent_id"`
	Status    string `json:"status"`
	PeerCount int    `json:"peer_count"`
}

// GatewayClient defines the write interface for sending messages to the gateway.
// The Sidecar Core Engineer implements this as gateway.Client.
type GatewayClient interface {
	SendDirectMessage(ctx context.Context, toAgent, content string) error
	Broadcast(ctx context.Context, content string) error
	SendPeerRequest(ctx context.Context, agentID, capability, prompt string, timeoutMs int64) (*PeerResult, error)
	SendStatusUpdate(ctx context.Context, status, detail string, progress float64) error
	SendTaskResult(ctx context.Context, taskID, status, resultText string, durationMs int64, inputTokens, outputTokens int32) error
}

// ErrNotConnected is returned by GatewayClient methods when the gRPC stream is not active.
var ErrNotConnected = errors.New("gateway: stream not connected")

// Server holds dependencies for all HTTP handlers.
type Server struct {
	state   StateReader
	gateway GatewayClient
	logger  *slog.Logger
}

// NewServer creates a new Server with the given dependencies.
func NewServer(state StateReader, gateway GatewayClient, logger *slog.Logger) *Server {
	if logger == nil {
		logger = slog.Default()
	}
	return &Server{
		state:   state,
		gateway: gateway,
		logger:  logger,
	}
}

// errorResponse is the standard error response shape.
type errorResponse struct {
	Error string `json:"error"`
	Code  string `json:"code"`
}

// writeJSON marshals v as JSON and writes it to w with the given HTTP status code.
func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if err := json.NewEncoder(w).Encode(v); err != nil {
		// Best-effort logging; headers already sent.
		slog.Error("failed to write JSON response", "error", err)
	}
}

// writeError writes a standard error response.
func writeError(w http.ResponseWriter, status int, message, code string) {
	writeJSON(w, status, errorResponse{Error: message, Code: code})
}

// decodeBody decodes the JSON request body into v. It validates the
// Content-Type header and returns a user-friendly error on failure.
func decodeBody(r *http.Request, v any) error {
	ct := r.Header.Get("Content-Type")
	if ct != "" && ct != "application/json" {
		return &httpError{
			Status:  http.StatusUnsupportedMediaType,
			Message: "Content-Type must be application/json",
			Code:    "UNSUPPORTED_MEDIA_TYPE",
		}
	}

	body, err := io.ReadAll(io.LimitReader(r.Body, 1<<20)) // 1MB limit
	if err != nil {
		return &httpError{
			Status:  http.StatusBadRequest,
			Message: "failed to read request body",
			Code:    "INVALID_REQUEST",
		}
	}

	if len(body) == 0 {
		return &httpError{
			Status:  http.StatusBadRequest,
			Message: "request body is empty",
			Code:    "INVALID_REQUEST",
		}
	}

	if err := json.Unmarshal(body, v); err != nil {
		return &httpError{
			Status:  http.StatusBadRequest,
			Message: "invalid JSON body",
			Code:    "INVALID_REQUEST",
		}
	}

	return nil
}

// requireConnected checks if the sidecar is connected to the gateway.
// If not connected, it writes a 503 error and returns false.
func (s *Server) requireConnected(w http.ResponseWriter) bool {
	if !s.state.IsConnected() {
		writeError(w, http.StatusServiceUnavailable, "not connected to Cortex", "DISCONNECTED")
		return false
	}
	return true
}

// httpError is an error type that carries HTTP status information for
// use by decodeBody and handlers.
type httpError struct {
	Status  int
	Message string
	Code    string
}

func (e *httpError) Error() string {
	return fmt.Sprintf("%d: %s", e.Status, e.Message)
}
