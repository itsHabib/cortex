package api

import (
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestGetMessages(t *testing.T) {
	tests := []struct {
		name      string
		messages  []Message
		wantCount int
	}{
		{
			name: "returns pending messages",
			messages: []Message{
				{ID: "m1", FromAgent: "a1", Content: "hello", Timestamp: time.Now()},
				{ID: "m2", FromAgent: "a2", Content: "world", Timestamp: time.Now()},
			},
			wantCount: 2,
		},
		{
			name:      "empty queue",
			messages:  nil,
			wantCount: 0,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			ms := &mockState{messages: tt.messages, connected: true}
			srv := newTestServer(ms, nil)

			req := httptest.NewRequest(http.MethodGet, "/messages", nil)
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
		})
	}
}

func TestSendMessage(t *testing.T) {
	tests := []struct {
		name       string
		agentID    string
		body       string
		connected  bool
		sendErr    error
		wantStatus int
		wantCode   string
	}{
		{
			name:       "sends successfully",
			agentID:    "agent-1",
			body:       `{"content": "hello"}`,
			connected:  true,
			wantStatus: http.StatusOK,
		},
		{
			name:       "disconnected returns 503",
			agentID:    "agent-1",
			body:       `{"content": "hello"}`,
			connected:  false,
			wantStatus: http.StatusServiceUnavailable,
			wantCode:   "DISCONNECTED",
		},
		{
			name:       "missing content",
			agentID:    "agent-1",
			body:       `{}`,
			connected:  true,
			wantStatus: http.StatusBadRequest,
			wantCode:   "INVALID_REQUEST",
		},
		{
			name:       "empty body",
			agentID:    "agent-1",
			body:       "",
			connected:  true,
			wantStatus: http.StatusBadRequest,
			wantCode:   "INVALID_REQUEST",
		},
		{
			name:       "gateway error",
			agentID:    "agent-1",
			body:       `{"content": "hello"}`,
			connected:  true,
			sendErr:    errors.New("stream broken"),
			wantStatus: http.StatusInternalServerError,
			wantCode:   "INTERNAL_ERROR",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			ms := &mockState{connected: tt.connected}
			mg := &mockGateway{sendMessageErr: tt.sendErr}
			srv := newTestServer(ms, mg)

			var body *strings.Reader
			if tt.body != "" {
				body = strings.NewReader(tt.body)
			} else {
				body = strings.NewReader("")
			}

			req := httptest.NewRequest(http.MethodPost, "/messages/"+tt.agentID, body)
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

			if tt.wantStatus == http.StatusOK && len(mg.sendMessageCalls) != 1 {
				t.Errorf("expected 1 send call, got %d", len(mg.sendMessageCalls))
			}
		})
	}
}

func TestBroadcast(t *testing.T) {
	tests := []struct {
		name       string
		body       string
		connected  bool
		err        error
		wantStatus int
		wantCode   string
	}{
		{
			name:       "broadcasts successfully",
			body:       `{"content": "standup update"}`,
			connected:  true,
			wantStatus: http.StatusOK,
		},
		{
			name:       "disconnected returns 503",
			body:       `{"content": "standup update"}`,
			connected:  false,
			wantStatus: http.StatusServiceUnavailable,
			wantCode:   "DISCONNECTED",
		},
		{
			name:       "missing content",
			body:       `{}`,
			connected:  true,
			wantStatus: http.StatusBadRequest,
			wantCode:   "INVALID_REQUEST",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			ms := &mockState{connected: tt.connected}
			mg := &mockGateway{broadcastErr: tt.err}
			srv := newTestServer(ms, mg)

			req := httptest.NewRequest(http.MethodPost, "/broadcast", strings.NewReader(tt.body))
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
