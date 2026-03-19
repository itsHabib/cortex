package api

import (
	"context"
	"errors"
	"net/http"
	"time"

	"github.com/go-chi/chi/v5"
)

const (
	defaultTimeoutMs = 60000
	minTimeoutMs     = 1000
	maxTimeoutMs     = 300000
)

// askRequest is the JSON body for POST /ask/{agentID} and POST /ask/capable/{capability}.
type askRequest struct {
	Prompt    string `json:"prompt"`
	TimeoutMs *int64 `json:"timeout_ms,omitempty"`
}

// clampTimeout returns the timeout clamped to [minTimeoutMs, maxTimeoutMs],
// defaulting to defaultTimeoutMs if nil.
func clampTimeout(timeoutMs *int64) int64 {
	if timeoutMs == nil {
		return defaultTimeoutMs
	}
	t := *timeoutMs
	if t < minTimeoutMs {
		return minTimeoutMs
	}
	if t > maxTimeoutMs {
		return maxTimeoutMs
	}
	return t
}

// handleAskAgent handles synchronous agent-to-agent invocation by agent ID.
func (s *Server) handleAskAgent(w http.ResponseWriter, r *http.Request) {
	if !s.requireConnected(w) {
		return
	}

	agentID := chi.URLParam(r, "agentID")
	if agentID == "" {
		writeError(w, http.StatusBadRequest, "agent_id is required", "INVALID_REQUEST")
		return
	}

	var req askRequest
	if err := decodeBody(r, &req); err != nil {
		if he, ok := err.(*httpError); ok {
			writeError(w, he.Status, he.Message, he.Code)
			return
		}
		writeError(w, http.StatusBadRequest, "invalid request body", "INVALID_REQUEST")
		return
	}

	if req.Prompt == "" {
		writeError(w, http.StatusBadRequest, "missing required field: prompt", "INVALID_REQUEST")
		return
	}

	timeoutMs := clampTimeout(req.TimeoutMs)
	s.doAsk(w, r, agentID, "", req.Prompt, timeoutMs)
}

// handleAskCapable handles synchronous invocation by capability.
func (s *Server) handleAskCapable(w http.ResponseWriter, r *http.Request) {
	if !s.requireConnected(w) {
		return
	}

	capability := chi.URLParam(r, "capability")
	if capability == "" {
		writeError(w, http.StatusBadRequest, "capability is required", "INVALID_REQUEST")
		return
	}

	var req askRequest
	if err := decodeBody(r, &req); err != nil {
		if he, ok := err.(*httpError); ok {
			writeError(w, he.Status, he.Message, he.Code)
			return
		}
		writeError(w, http.StatusBadRequest, "invalid request body", "INVALID_REQUEST")
		return
	}

	if req.Prompt == "" {
		writeError(w, http.StatusBadRequest, "missing required field: prompt", "INVALID_REQUEST")
		return
	}

	timeoutMs := clampTimeout(req.TimeoutMs)
	s.doAsk(w, r, "", capability, req.Prompt, timeoutMs)
}

// doAsk executes a blocking peer request and writes the response.
func (s *Server) doAsk(w http.ResponseWriter, r *http.Request, agentID, capability, prompt string, timeoutMs int64) {
	ctx, cancel := context.WithTimeout(r.Context(), time.Duration(timeoutMs)*time.Millisecond)
	defer cancel()

	start := time.Now()
	result, err := s.gateway.SendPeerRequest(ctx, agentID, capability, prompt, timeoutMs)
	duration := time.Since(start)

	if err != nil {
		if errors.Is(err, context.DeadlineExceeded) {
			writeError(w, http.StatusRequestTimeout, "invocation timed out", "TIMEOUT")
			return
		}
		if errors.Is(err, ErrNotConnected) {
			writeError(w, http.StatusServiceUnavailable, "not connected to Cortex", "DISCONNECTED")
			return
		}
		s.logger.Error("peer request failed", "agent_id", agentID, "capability", capability, "error", err)
		writeError(w, http.StatusInternalServerError, "invocation failed", "INTERNAL_ERROR")
		return
	}

	writeJSON(w, http.StatusOK, map[string]any{
		"status":      result.Status,
		"result":      result.Result,
		"duration_ms": duration.Milliseconds(),
	})
}
