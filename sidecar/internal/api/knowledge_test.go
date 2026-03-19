package api

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestKnowledge(t *testing.T) {
	tests := []struct {
		name       string
		method     string
		path       string
		body       string
		wantStatus int
		wantCode   string
	}{
		{
			name:       "GET /knowledge returns 501",
			method:     http.MethodGet,
			path:       "/knowledge",
			wantStatus: http.StatusNotImplemented,
			wantCode:   "NOT_IMPLEMENTED",
		},
		{
			name:       "POST /knowledge returns 501",
			method:     http.MethodPost,
			path:       "/knowledge",
			body:       `{"topic": "test", "content": "data"}`,
			wantStatus: http.StatusNotImplemented,
			wantCode:   "NOT_IMPLEMENTED",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			ms := &mockState{connected: true}
			srv := newTestServer(ms, nil)

			var req *http.Request
			if tt.body != "" {
				req = httptest.NewRequest(tt.method, tt.path, strings.NewReader(tt.body))
				req.Header.Set("Content-Type", "application/json")
			} else {
				req = httptest.NewRequest(tt.method, tt.path, nil)
			}

			w := httptest.NewRecorder()
			srv.ServeHTTP(w, req)

			if w.Code != tt.wantStatus {
				t.Fatalf("expected %d, got %d: %s", tt.wantStatus, w.Code, w.Body.String())
			}

			var resp map[string]string
			if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
				t.Fatalf("decode error: %v", err)
			}

			if resp["code"] != tt.wantCode {
				t.Errorf("expected code %q, got %q", tt.wantCode, resp["code"])
			}

			wantMsg := "knowledge endpoints not yet implemented"
			if resp["error"] != wantMsg {
				t.Errorf("expected error %q, got %q", wantMsg, resp["error"])
			}
		})
	}
}
