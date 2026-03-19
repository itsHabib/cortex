package api

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestRosterList(t *testing.T) {
	agents := []AgentInfo{
		{ID: "a1", Name: "reviewer", Role: "security", Capabilities: []string{"review"}, Status: "idle", Metadata: map[string]string{}},
		{ID: "a2", Name: "coder", Role: "developer", Capabilities: []string{"code"}, Status: "working", Metadata: map[string]string{}},
	}

	tests := []struct {
		name      string
		roster    []AgentInfo
		connected bool
		wantCount int
	}{
		{
			name:      "returns all agents",
			roster:    agents,
			connected: true,
			wantCount: 2,
		},
		{
			name:      "empty roster",
			roster:    nil,
			connected: true,
			wantCount: 0,
		},
		{
			name:      "works when disconnected",
			roster:    agents,
			connected: false,
			wantCount: 2,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			ms := &mockState{roster: tt.roster, connected: tt.connected}
			srv := newTestServer(ms, nil)

			req := httptest.NewRequest(http.MethodGet, "/roster", nil)
			w := httptest.NewRecorder()
			srv.ServeHTTP(w, req)

			if w.Code != http.StatusOK {
				t.Fatalf("expected 200, got %d", w.Code)
			}

			var resp map[string]any
			if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
				t.Fatalf("decode error: %v", err)
			}

			count := int(resp["count"].(float64))
			if count != tt.wantCount {
				t.Errorf("expected count %d, got %d", tt.wantCount, count)
			}
			if resp["connected"] != tt.connected {
				t.Errorf("expected connected=%v, got %v", tt.connected, resp["connected"])
			}
		})
	}
}

func TestRosterGetByID(t *testing.T) {
	agents := []AgentInfo{
		{ID: "a1", Name: "reviewer", Role: "security", Capabilities: []string{"review"}, Status: "idle", Metadata: map[string]string{}},
	}

	tests := []struct {
		name       string
		agentID    string
		wantStatus int
		wantName   string
	}{
		{
			name:       "found",
			agentID:    "a1",
			wantStatus: http.StatusOK,
			wantName:   "reviewer",
		},
		{
			name:       "not found",
			agentID:    "unknown",
			wantStatus: http.StatusNotFound,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			ms := &mockState{roster: agents, connected: true}
			srv := newTestServer(ms, nil)

			req := httptest.NewRequest(http.MethodGet, "/roster/"+tt.agentID, nil)
			w := httptest.NewRecorder()
			srv.ServeHTTP(w, req)

			if w.Code != tt.wantStatus {
				t.Fatalf("expected %d, got %d", tt.wantStatus, w.Code)
			}

			if tt.wantStatus == http.StatusOK {
				var resp map[string]any
				if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
					t.Fatalf("decode error: %v", err)
				}
				if resp["name"] != tt.wantName {
					t.Errorf("expected name %q, got %q", tt.wantName, resp["name"])
				}
			}
		})
	}
}

func TestRosterCapable(t *testing.T) {
	agents := []AgentInfo{
		{ID: "a1", Name: "reviewer", Role: "security", Capabilities: []string{"review", "audit"}, Status: "idle", Metadata: map[string]string{}},
		{ID: "a2", Name: "coder", Role: "developer", Capabilities: []string{"code"}, Status: "idle", Metadata: map[string]string{}},
		{ID: "a3", Name: "auditor", Role: "compliance", Capabilities: []string{"audit"}, Status: "idle", Metadata: map[string]string{}},
	}

	tests := []struct {
		name       string
		capability string
		wantCount  int
	}{
		{
			name:       "matches multiple",
			capability: "audit",
			wantCount:  2,
		},
		{
			name:       "matches one",
			capability: "code",
			wantCount:  1,
		},
		{
			name:       "no match",
			capability: "nonexistent",
			wantCount:  0,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			ms := &mockState{roster: agents, connected: true}
			srv := newTestServer(ms, nil)

			req := httptest.NewRequest(http.MethodGet, "/roster/capable/"+tt.capability, nil)
			w := httptest.NewRecorder()
			srv.ServeHTTP(w, req)

			if w.Code != http.StatusOK {
				t.Fatalf("expected 200, got %d", w.Code)
			}

			var resp map[string]any
			if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
				t.Fatalf("decode error: %v", err)
			}

			count := int(resp["count"].(float64))
			if count != tt.wantCount {
				t.Errorf("expected count %d, got %d", tt.wantCount, count)
			}
			if resp["capability"] != tt.capability {
				t.Errorf("expected capability %q, got %q", tt.capability, resp["capability"])
			}
		})
	}
}
