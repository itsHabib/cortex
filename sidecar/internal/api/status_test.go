package api

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestReportStatus(t *testing.T) {
	tests := []struct {
		name       string
		body       string
		connected  bool
		err        error
		wantStatus int
		wantCode   string
	}{
		{
			name:       "reports status successfully",
			body:       `{"status": "working", "detail": "Analyzing file 3/7", "progress": 0.43}`,
			connected:  true,
			wantStatus: http.StatusOK,
		},
		{
			name:       "disconnected returns 503",
			body:       `{"status": "working"}`,
			connected:  false,
			wantStatus: http.StatusServiceUnavailable,
			wantCode:   "DISCONNECTED",
		},
		{
			name:       "missing status field",
			body:       `{"detail": "working on it"}`,
			connected:  true,
			wantStatus: http.StatusBadRequest,
			wantCode:   "INVALID_REQUEST",
		},
		{
			name:       "empty body",
			body:       "",
			connected:  true,
			wantStatus: http.StatusBadRequest,
			wantCode:   "INVALID_REQUEST",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			ms := &mockState{connected: tt.connected}
			mg := &mockGateway{statusUpdateErr: tt.err}
			srv := newTestServer(ms, mg)

			var body *strings.Reader
			if tt.body != "" {
				body = strings.NewReader(tt.body)
			} else {
				body = strings.NewReader("")
			}

			req := httptest.NewRequest(http.MethodPost, "/status", body)
			req.Header.Set("Content-Type", "application/json")
			w := httptest.NewRecorder()
			srv.ServeHTTP(w, req)

			if w.Code != tt.wantStatus {
				t.Fatalf("expected %d, got %d: %s", tt.wantStatus, w.Code, w.Body.String())
			}

			if tt.wantCode != "" {
				var resp map[string]string
				if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
					t.Fatalf("decode error: %v", err)
				}
				if resp["code"] != tt.wantCode {
					t.Errorf("expected code %q, got %q", tt.wantCode, resp["code"])
				}
			}
		})
	}
}

func TestGetTask(t *testing.T) {
	tests := []struct {
		name     string
		task     *TaskInfo
		wantNull bool
	}{
		{
			name: "returns current task",
			task: &TaskInfo{
				TaskID:    "task-123",
				Prompt:    "Review code",
				TimeoutMs: 300000,
				Tools:     []string{"read_file"},
				Context:   map[string]string{"repo": "cortex"},
			},
			wantNull: false,
		},
		{
			name:     "returns null when no task",
			task:     nil,
			wantNull: true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			ms := &mockState{task: tt.task, connected: true}
			srv := newTestServer(ms, nil)

			req := httptest.NewRequest(http.MethodGet, "/task", nil)
			w := httptest.NewRecorder()
			srv.ServeHTTP(w, req)

			if w.Code != http.StatusOK {
				t.Fatalf("expected 200, got %d", w.Code)
			}

			var resp map[string]any
			if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
				t.Fatalf("decode error: %v", err)
			}

			if tt.wantNull {
				if resp["task"] != nil {
					t.Errorf("expected task to be null, got %v", resp["task"])
				}
			} else {
				task, ok := resp["task"].(map[string]any)
				if !ok {
					t.Fatalf("expected task to be object, got %T", resp["task"])
				}
				if task["task_id"] != tt.task.TaskID {
					t.Errorf("expected task_id %q, got %q", tt.task.TaskID, task["task_id"])
				}
			}
		})
	}
}

func TestSubmitTaskResult(t *testing.T) {
	tests := []struct {
		name       string
		body       string
		connected  bool
		task       *TaskInfo
		err        error
		wantStatus int
		wantCode   string
	}{
		{
			name:       "submits result successfully",
			body:       `{"task_id": "task-123", "status": "completed", "result_text": "Done", "duration_ms": 5000}`,
			connected:  true,
			task:       &TaskInfo{TaskID: "task-123"},
			wantStatus: http.StatusOK,
		},
		{
			name:       "disconnected returns 503",
			body:       `{"task_id": "task-123", "status": "completed"}`,
			connected:  false,
			wantStatus: http.StatusServiceUnavailable,
			wantCode:   "DISCONNECTED",
		},
		{
			name:       "missing task_id",
			body:       `{"status": "completed", "result_text": "Done"}`,
			connected:  true,
			task:       &TaskInfo{TaskID: "task-123"},
			wantStatus: http.StatusBadRequest,
			wantCode:   "INVALID_REQUEST",
		},
		{
			name:       "no active task",
			body:       `{"task_id": "task-123", "status": "completed"}`,
			connected:  true,
			task:       nil,
			wantStatus: http.StatusBadRequest,
			wantCode:   "NO_TASK",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			ms := &mockState{connected: tt.connected, task: tt.task}
			mg := &mockGateway{taskResultErr: tt.err}
			srv := newTestServer(ms, mg)

			req := httptest.NewRequest(http.MethodPost, "/task/result", strings.NewReader(tt.body))
			req.Header.Set("Content-Type", "application/json")
			w := httptest.NewRecorder()
			srv.ServeHTTP(w, req)

			if w.Code != tt.wantStatus {
				t.Fatalf("expected %d, got %d: %s", tt.wantStatus, w.Code, w.Body.String())
			}

			if tt.wantCode != "" {
				var resp map[string]string
				if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
					t.Fatalf("decode error: %v", err)
				}
				if resp["code"] != tt.wantCode {
					t.Errorf("expected code %q, got %q", tt.wantCode, resp["code"])
				}
			}
		})
	}
}
