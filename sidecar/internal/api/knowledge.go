package api

import "net/http"

// handleQueryKnowledge returns 501 Not Implemented. Knowledge endpoints
// are deferred to Phase 3.
func (s *Server) handleQueryKnowledge(w http.ResponseWriter, r *http.Request) {
	writeError(w, http.StatusNotImplemented, "knowledge endpoints not yet implemented", "NOT_IMPLEMENTED")
}

// handlePublishKnowledge returns 501 Not Implemented. Knowledge endpoints
// are deferred to Phase 3.
func (s *Server) handlePublishKnowledge(w http.ResponseWriter, r *http.Request) {
	writeError(w, http.StatusNotImplemented, "knowledge endpoints not yet implemented", "NOT_IMPLEMENTED")
}
