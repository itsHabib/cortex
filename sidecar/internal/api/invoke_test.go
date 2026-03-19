package api

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestAskAgent(t *testing.T) {
	tests := []struct {
		name       string
		agentID    string
		body       string
		connected  bool
		result     *PeerResult
		err        error
		wantStatus int
		wantCode   string
	}{
		{
			name:      "successful invocation",
			agentID:   "agent-1",
			body:      `{"prompt": "review this code", "timeout_ms": 5000}`,
			connected: true,
			result: &PeerResult{
				Status: "completed",
				Result: "Found 2 issues",
			},
			wantStatus: http.StatusOK,
		},
		{
			name:       "disconnected returns 503",
			agentID:    "agent-1",
			body:       `{"prompt": "review this code"}`,
			connected:  false,
			wantStatus: http.StatusServiceUnavailable,
			wantCode:   "DISCONNECTED",
		},
		{
			name:       "missing prompt",
			agentID:    "agent-1",
			body:       `{"timeout_ms": 5000}`,
			connected:  true,
			wantStatus: http.StatusBadRequest,
			wantCode:   "INVALID_REQUEST",
		},
		{
			name:       "timeout returns 408",
			agentID:    "agent-1",
			body:       `{"prompt": "review this code", "timeout_ms": 1000}`,
			connected:  true,
			err:        context.DeadlineExceeded,
			wantStatus: http.StatusRequestTimeout,
			wantCode:   "TIMEOUT",
		},
		{
			name:       "not connected error returns 503",
			agentID:    "agent-1",
			body:       `{"prompt": "review this code"}`,
			connected:  true,
			err:        ErrNotConnected,
			wantStatus: http.StatusServiceUnavailable,
			wantCode:   "DISCONNECTED",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			ms := &mockState{connected: tt.connected}
			mg := &mockGateway{
				peerRequestResult: tt.result,
				peerRequestErr:    tt.err,
			}
			srv := newTestServer(ms, mg)

			req := httptest.NewRequest(http.MethodPost, "/ask/"+tt.agentID, strings.NewReader(tt.body))
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

			if tt.wantStatus == http.StatusOK {
				var resp map[string]any
				if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
					t.Fatalf("decode error: %v", err)
				}
				if resp["status"] != tt.result.Status {
					t.Errorf("expected status %q, got %q", tt.result.Status, resp["status"])
				}
				if resp["result"] != tt.result.Result {
					t.Errorf("expected result %q, got %q", tt.result.Result, resp["result"])
				}
			}
		})
	}
}

func TestAskCapable(t *testing.T) {
	tests := []struct {
		name       string
		capability string
		body       string
		connected  bool
		result     *PeerResult
		err        error
		wantStatus int
	}{
		{
			name:       "successful capability invocation",
			capability: "security-review",
			body:       `{"prompt": "check for SQL injection"}`,
			connected:  true,
			result: &PeerResult{
				Status: "completed",
				Result: "No SQL injection found",
			},
			wantStatus: http.StatusOK,
		},
		{
			name:       "disconnected",
			capability: "security-review",
			body:       `{"prompt": "check"}`,
			connected:  false,
			wantStatus: http.StatusServiceUnavailable,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			ms := &mockState{connected: tt.connected}
			mg := &mockGateway{
				peerRequestResult: tt.result,
				peerRequestErr:    tt.err,
			}
			srv := newTestServer(ms, mg)

			req := httptest.NewRequest(http.MethodPost, "/ask/capable/"+tt.capability, strings.NewReader(tt.body))
			req.Header.Set("Content-Type", "application/json")
			w := httptest.NewRecorder()
			srv.ServeHTTP(w, req)

			if w.Code != tt.wantStatus {
				t.Fatalf("expected %d, got %d: %s", tt.wantStatus, w.Code, w.Body.String())
			}
		})
	}
}

func TestTimeoutClamping(t *testing.T) {
	tests := []struct {
		name      string
		timeoutMs *int64
		want      int64
	}{
		{
			name:      "nil defaults to 60000",
			timeoutMs: nil,
			want:      60000,
		},
		{
			name:      "too small clamps to 1000",
			timeoutMs: intPtr(500),
			want:      1000,
		},
		{
			name:      "too large clamps to 300000",
			timeoutMs: intPtr(500000),
			want:      300000,
		},
		{
			name:      "valid passes through",
			timeoutMs: intPtr(30000),
			want:      30000,
		},
		{
			name:      "exact min",
			timeoutMs: intPtr(1000),
			want:      1000,
		},
		{
			name:      "exact max",
			timeoutMs: intPtr(300000),
			want:      300000,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := clampTimeout(tt.timeoutMs)
			if got != tt.want {
				t.Errorf("clampTimeout(%v) = %d, want %d", tt.timeoutMs, got, tt.want)
			}
		})
	}
}

func intPtr(v int64) *int64 {
	return &v
}
