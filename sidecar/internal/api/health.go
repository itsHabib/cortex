package api

import "net/http"

// handleHealth returns the sidecar's health status.
func (s *Server) handleHealth(w http.ResponseWriter, r *http.Request) {
	connected := s.state.IsConnected()
	status := "healthy"
	if !connected {
		status = "degraded"
	}

	writeJSON(w, http.StatusOK, map[string]any{
		"status":    status,
		"connected": connected,
		"agent_id":  s.state.GetAgentID(),
		"uptime_ms": s.state.GetUptime().Milliseconds(),
	})
}
