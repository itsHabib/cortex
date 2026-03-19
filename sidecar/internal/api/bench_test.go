package api

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func BenchmarkHealth(b *testing.B) {
	ms := &mockState{connected: true, agentID: "agent-1", uptime: 45 * time.Second}
	srv := newTestServer(ms, nil)

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		req := httptest.NewRequest(http.MethodGet, "/health", nil)
		w := httptest.NewRecorder()
		srv.ServeHTTP(w, req)
	}
}

func BenchmarkRosterList(b *testing.B) {
	agents := make([]AgentInfo, 50)
	for i := range agents {
		agents[i] = AgentInfo{
			ID:           "agent-" + strings.Repeat("x", 10),
			Name:         "agent",
			Role:         "worker",
			Capabilities: []string{"cap1", "cap2"},
			Status:       "idle",
			Metadata:     map[string]string{"model": "opus"},
		}
	}
	ms := &mockState{roster: agents, connected: true}
	srv := newTestServer(ms, nil)

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		req := httptest.NewRequest(http.MethodGet, "/roster", nil)
		w := httptest.NewRecorder()
		srv.ServeHTTP(w, req)
	}
}

func BenchmarkRosterByID(b *testing.B) {
	agents := []AgentInfo{
		{ID: "target-agent", Name: "reviewer", Role: "security", Capabilities: []string{"review"}, Status: "idle", Metadata: map[string]string{}},
	}
	ms := &mockState{roster: agents, connected: true}
	srv := newTestServer(ms, nil)

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		req := httptest.NewRequest(http.MethodGet, "/roster/target-agent", nil)
		w := httptest.NewRecorder()
		srv.ServeHTTP(w, req)
	}
}

func BenchmarkSendMessage(b *testing.B) {
	ms := &mockState{connected: true}
	mg := &mockGateway{}
	srv := newTestServer(ms, mg)

	body := `{"content": "benchmark message"}`

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		req := httptest.NewRequest(http.MethodPost, "/messages/agent-1", strings.NewReader(body))
		req.Header.Set("Content-Type", "application/json")
		w := httptest.NewRecorder()
		srv.ServeHTTP(w, req)
	}
}

func BenchmarkAskAgent(b *testing.B) {
	ms := &mockState{connected: true}
	mg := &mockGateway{
		peerRequestResult: &PeerResult{Status: "completed", Result: "ok"},
	}
	srv := newTestServer(ms, mg)

	body := `{"prompt": "benchmark prompt", "timeout_ms": 5000}`

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		req := httptest.NewRequest(http.MethodPost, "/ask/agent-1", strings.NewReader(body))
		req.Header.Set("Content-Type", "application/json")
		w := httptest.NewRecorder()
		srv.ServeHTTP(w, req)
	}
}
