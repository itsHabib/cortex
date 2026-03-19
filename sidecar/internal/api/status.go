package api

import "net/http"

// statusRequest is the JSON body for POST /status.
type statusRequest struct {
	Status   string   `json:"status"`
	Detail   string   `json:"detail"`
	Progress *float64 `json:"progress,omitempty"`
}

// taskResultRequest is the JSON body for POST /task/result.
type taskResultRequest struct {
	TaskID       string `json:"task_id"`
	Status       string `json:"status"`
	ResultText   string `json:"result_text"`
	DurationMs   int64  `json:"duration_ms"`
	InputTokens  int32  `json:"input_tokens"`
	OutputTokens int32  `json:"output_tokens"`
}

// handleReportStatus reports agent progress to Cortex.
func (s *Server) handleReportStatus(w http.ResponseWriter, r *http.Request) {
	if !s.requireConnected(w) {
		return
	}

	var req statusRequest
	if err := decodeBody(r, &req); err != nil {
		if he, ok := err.(*httpError); ok {
			writeError(w, he.Status, he.Message, he.Code)
			return
		}
		writeError(w, http.StatusBadRequest, "invalid request body", "INVALID_REQUEST")
		return
	}

	if req.Status == "" {
		writeError(w, http.StatusBadRequest, "missing required field: status", "INVALID_REQUEST")
		return
	}

	progress := 0.0
	if req.Progress != nil {
		progress = *req.Progress
	}

	if err := s.gateway.SendStatusUpdate(r.Context(), req.Status, req.Detail, progress); err != nil {
		s.logger.Error("failed to send status update", "error", err)
		writeError(w, http.StatusInternalServerError, "failed to send status update", "INTERNAL_ERROR")
		return
	}

	writeJSON(w, http.StatusOK, map[string]string{"status": "accepted"})
}

// handleGetTask returns the current task assignment.
func (s *Server) handleGetTask(w http.ResponseWriter, r *http.Request) {
	task := s.state.GetTask()
	writeJSON(w, http.StatusOK, map[string]any{
		"task": task,
	})
}

// handleSubmitTaskResult submits a task result to Cortex.
func (s *Server) handleSubmitTaskResult(w http.ResponseWriter, r *http.Request) {
	if !s.requireConnected(w) {
		return
	}

	var req taskResultRequest
	if err := decodeBody(r, &req); err != nil {
		if he, ok := err.(*httpError); ok {
			writeError(w, he.Status, he.Message, he.Code)
			return
		}
		writeError(w, http.StatusBadRequest, "invalid request body", "INVALID_REQUEST")
		return
	}

	if req.TaskID == "" {
		writeError(w, http.StatusBadRequest, "missing required field: task_id", "INVALID_REQUEST")
		return
	}

	// Verify there's an active task
	currentTask := s.state.GetTask()
	if currentTask == nil {
		writeError(w, http.StatusBadRequest, "no active task", "NO_TASK")
		return
	}

	if err := s.gateway.SendTaskResult(r.Context(), req.TaskID, req.Status, req.ResultText, req.DurationMs, req.InputTokens, req.OutputTokens); err != nil {
		s.logger.Error("failed to send task result", "error", err)
		writeError(w, http.StatusInternalServerError, "failed to send task result", "INTERNAL_ERROR")
		return
	}

	writeJSON(w, http.StatusOK, map[string]string{"status": "accepted"})
}
