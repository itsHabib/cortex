package api

import (
	"net/http"

	"github.com/go-chi/chi/v5"
)

// sendMessageRequest is the JSON body for POST /messages/{agentID}.
type sendMessageRequest struct {
	Content string `json:"content"`
}

// broadcastRequest is the JSON body for POST /broadcast.
type broadcastRequest struct {
	Content string `json:"content"`
}

// handleGetMessages returns pending inbound messages and clears the queue.
func (s *Server) handleGetMessages(w http.ResponseWriter, r *http.Request) {
	messages := s.state.PopMessages()
	if messages == nil {
		messages = []Message{}
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"messages": messages,
		"count":    len(messages),
	})
}

// handleSendMessage sends a direct message to another agent.
func (s *Server) handleSendMessage(w http.ResponseWriter, r *http.Request) {
	if !s.requireConnected(w) {
		return
	}

	agentID := chi.URLParam(r, "agentID")
	if agentID == "" {
		writeError(w, http.StatusBadRequest, "agent_id is required", "INVALID_REQUEST")
		return
	}

	var req sendMessageRequest
	if err := decodeBody(r, &req); err != nil {
		if he, ok := err.(*httpError); ok {
			writeError(w, he.Status, he.Message, he.Code)
			return
		}
		writeError(w, http.StatusBadRequest, "invalid request body", "INVALID_REQUEST")
		return
	}

	if req.Content == "" {
		writeError(w, http.StatusBadRequest, "missing required field: content", "INVALID_REQUEST")
		return
	}

	if err := s.gateway.SendDirectMessage(r.Context(), agentID, req.Content); err != nil {
		s.logger.Error("failed to send message", "to_agent", agentID, "error", err)
		writeError(w, http.StatusInternalServerError, "failed to send message", "INTERNAL_ERROR")
		return
	}

	writeJSON(w, http.StatusOK, map[string]string{"status": "sent"})
}

// handleBroadcast sends a message to all agents in the mesh.
func (s *Server) handleBroadcast(w http.ResponseWriter, r *http.Request) {
	if !s.requireConnected(w) {
		return
	}

	var req broadcastRequest
	if err := decodeBody(r, &req); err != nil {
		if he, ok := err.(*httpError); ok {
			writeError(w, he.Status, he.Message, he.Code)
			return
		}
		writeError(w, http.StatusBadRequest, "invalid request body", "INVALID_REQUEST")
		return
	}

	if req.Content == "" {
		writeError(w, http.StatusBadRequest, "missing required field: content", "INVALID_REQUEST")
		return
	}

	if err := s.gateway.Broadcast(r.Context(), req.Content); err != nil {
		s.logger.Error("failed to broadcast", "error", err)
		writeError(w, http.StatusInternalServerError, "failed to broadcast", "INTERNAL_ERROR")
		return
	}

	writeJSON(w, http.StatusOK, map[string]string{"status": "broadcast"})
}
