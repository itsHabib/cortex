package api

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

func TestHealth(t *testing.T) {
	tests := []struct {
		name        string
		connected   bool
		agentID     string
		uptime      time.Duration
		wantStatus  string
		wantConnect bool
	}{
		{
			name:        "healthy when connected",
			connected:   true,
			agentID:     "agent-123",
			uptime:      45 * time.Second,
			wantStatus:  "healthy",
			wantConnect: true,
		},
		{
			name:        "degraded when disconnected",
			connected:   false,
			agentID:     "agent-456",
			uptime:      10 * time.Second,
			wantStatus:  "degraded",
			wantConnect: false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			ms := &mockState{
				connected: tt.connected,
				agentID:   tt.agentID,
				uptime:    tt.uptime,
			}
			srv := newTestServer(ms, nil)

			req := httptest.NewRequest(http.MethodGet, "/health", nil)
			w := httptest.NewRecorder()
			srv.ServeHTTP(w, req)

			if w.Code != http.StatusOK {
				t.Fatalf("expected status 200, got %d", w.Code)
			}

			var resp map[string]any
			if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
				t.Fatalf("failed to decode response: %v", err)
			}

			if resp["status"] != tt.wantStatus {
				t.Errorf("expected status %q, got %q", tt.wantStatus, resp["status"])
			}
			if resp["connected"] != tt.wantConnect {
				t.Errorf("expected connected=%v, got %v", tt.wantConnect, resp["connected"])
			}
			if resp["agent_id"] != tt.agentID {
				t.Errorf("expected agent_id %q, got %q", tt.agentID, resp["agent_id"])
			}
			if resp["uptime_ms"] != float64(tt.uptime.Milliseconds()) {
				t.Errorf("expected uptime_ms %v, got %v", tt.uptime.Milliseconds(), resp["uptime_ms"])
			}
		})
	}
}
