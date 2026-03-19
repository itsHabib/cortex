package api

import (
	"net/http"

	"github.com/go-chi/chi/v5"
)

// handleRosterList returns all agents in the mesh roster.
func (s *Server) handleRosterList(w http.ResponseWriter, r *http.Request) {
	agents := s.state.GetRoster()
	if agents == nil {
		agents = []AgentInfo{}
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"agents":    agents,
		"count":     len(agents),
		"connected": s.state.IsConnected(),
	})
}

// handleRosterGet returns details for a specific agent.
func (s *Server) handleRosterGet(w http.ResponseWriter, r *http.Request) {
	agentID := chi.URLParam(r, "agentID")
	if agentID == "" {
		writeError(w, http.StatusBadRequest, "agent_id is required", "INVALID_REQUEST")
		return
	}

	agent, ok := s.state.GetAgent(agentID)
	if !ok {
		writeError(w, http.StatusNotFound, "agent not found", "NOT_FOUND")
		return
	}

	writeJSON(w, http.StatusOK, agent)
}

// handleRosterCapable returns agents advertising a given capability.
func (s *Server) handleRosterCapable(w http.ResponseWriter, r *http.Request) {
	capability := chi.URLParam(r, "capability")
	if capability == "" {
		writeError(w, http.StatusBadRequest, "capability is required", "INVALID_REQUEST")
		return
	}

	agents := s.state.GetCapable(capability)
	if agents == nil {
		agents = []AgentInfo{}
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"agents":     agents,
		"count":      len(agents),
		"capability": capability,
	})
}
