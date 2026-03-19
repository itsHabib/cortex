package state

import (
	"sync"
	"testing"
	"time"

	pb "github.com/cortex/sidecar/internal/proto/gatewayv1"
)

func TestNew(t *testing.T) {
	s := New()
	if s.GetAgentID() != "" {
		t.Errorf("initial agent ID = %q, want empty", s.GetAgentID())
	}
	if s.GetStatus() != StatusConnecting {
		t.Errorf("initial status = %q, want %q", s.GetStatus(), StatusConnecting)
	}
	if roster := s.GetRoster(); roster != nil {
		t.Errorf("initial roster = %v, want nil", roster)
	}
	if msgs := s.PopMessages(); len(msgs) != 0 {
		t.Errorf("initial messages = %d, want 0", len(msgs))
	}
	if task := s.GetTask(); task != nil {
		t.Errorf("initial task = %v, want nil", task)
	}
	if !s.IsConnected() == true {
		// IsConnected should be false for "connecting" status
	}
	if s.IsConnected() {
		t.Error("IsConnected() = true for connecting status, want false")
	}
}

func TestAgentID(t *testing.T) {
	s := New()
	s.SetAgentID("agent-123")
	if got := s.GetAgentID(); got != "agent-123" {
		t.Errorf("GetAgentID() = %q, want %q", got, "agent-123")
	}
}

func TestConnectionStatus(t *testing.T) {
	tests := []struct {
		status ConnectionStatus
		isConn bool
	}{
		{StatusConnecting, false},
		{StatusConnected, true},
		{StatusDisconnected, false},
		{StatusReconnecting, false},
	}
	for _, tt := range tests {
		t.Run(string(tt.status), func(t *testing.T) {
			s := New()
			s.SetStatus(tt.status)
			if got := s.GetStatus(); got != tt.status {
				t.Errorf("GetStatus() = %q, want %q", got, tt.status)
			}
			if got := s.IsConnected(); got != tt.isConn {
				t.Errorf("IsConnected() = %v, want %v", got, tt.isConn)
			}
		})
	}
}

func TestRoster(t *testing.T) {
	s := New()
	agents := []*pb.AgentInfo{
		{Id: "a1", Name: "agent-1", Capabilities: []string{"review"}},
		{Id: "a2", Name: "agent-2", Capabilities: []string{"analyze", "review"}},
		{Id: "a3", Name: "agent-3", Capabilities: []string{"test"}},
	}
	s.SetRoster(agents)

	got := s.GetRoster()
	if len(got) != 3 {
		t.Fatalf("GetRoster() length = %d, want 3", len(got))
	}

	// Verify it's a copy — modifying the returned slice shouldn't affect the store.
	got[0] = nil
	original := s.GetRoster()
	if original[0] == nil {
		t.Error("GetRoster() did not return a copy")
	}
}

func TestGetAgent(t *testing.T) {
	s := New()
	agents := []*pb.AgentInfo{
		{Id: "a1", Name: "agent-1"},
		{Id: "a2", Name: "agent-2"},
	}
	s.SetRoster(agents)

	t.Run("found", func(t *testing.T) {
		a, ok := s.GetAgent("a1")
		if !ok {
			t.Fatal("GetAgent(a1) returned not found")
		}
		if a.GetName() != "agent-1" {
			t.Errorf("GetAgent(a1).Name = %q, want %q", a.GetName(), "agent-1")
		}
	})

	t.Run("not found", func(t *testing.T) {
		_, ok := s.GetAgent("missing")
		if ok {
			t.Error("GetAgent(missing) returned found, want not found")
		}
	})
}

func TestGetCapable(t *testing.T) {
	s := New()
	agents := []*pb.AgentInfo{
		{Id: "a1", Capabilities: []string{"review", "test"}},
		{Id: "a2", Capabilities: []string{"analyze"}},
		{Id: "a3", Capabilities: []string{"review"}},
	}
	s.SetRoster(agents)

	t.Run("multiple matches", func(t *testing.T) {
		got := s.GetCapable("review")
		if len(got) != 2 {
			t.Fatalf("GetCapable(review) = %d agents, want 2", len(got))
		}
	})

	t.Run("single match", func(t *testing.T) {
		got := s.GetCapable("analyze")
		if len(got) != 1 {
			t.Fatalf("GetCapable(analyze) = %d agents, want 1", len(got))
		}
	})

	t.Run("no matches", func(t *testing.T) {
		got := s.GetCapable("nonexistent")
		if len(got) != 0 {
			t.Fatalf("GetCapable(nonexistent) = %d agents, want 0", len(got))
		}
	})
}

func TestMessages(t *testing.T) {
	s := New()

	msg1 := Message{Type: "task_request", TaskReq: &pb.TaskRequest{TaskId: "t1"}, Received: time.Now()}
	msg2 := Message{Type: "peer_request", PeerReq: &pb.PeerRequest{RequestId: "r1"}, Received: time.Now()}
	msg3 := Message{Type: "direct_message", DirectMsg: &pb.DirectMessage{MessageId: "m1"}, Received: time.Now()}

	s.PushMessage(msg1)
	s.PushMessage(msg2)
	s.PushMessage(msg3)

	msgs := s.PopMessages()
	if len(msgs) != 3 {
		t.Fatalf("PopMessages() returned %d messages, want 3", len(msgs))
	}
	if msgs[0].Type != "task_request" {
		t.Errorf("msgs[0].Type = %q, want %q", msgs[0].Type, "task_request")
	}
	if msgs[1].Type != "peer_request" {
		t.Errorf("msgs[1].Type = %q, want %q", msgs[1].Type, "peer_request")
	}
	if msgs[2].Type != "direct_message" {
		t.Errorf("msgs[2].Type = %q, want %q", msgs[2].Type, "direct_message")
	}

	// Subsequent pop returns empty.
	msgs2 := s.PopMessages()
	if len(msgs2) != 0 {
		t.Errorf("second PopMessages() returned %d messages, want 0", len(msgs2))
	}
}

func TestTask(t *testing.T) {
	s := New()

	task := &pb.TaskRequest{TaskId: "task-1", Prompt: "do stuff"}
	s.SetTask(task)
	got := s.GetTask()
	if got == nil || got.GetTaskId() != "task-1" {
		t.Errorf("GetTask() = %v, want task with ID task-1", got)
	}

	// Clear task.
	s.SetTask(nil)
	if got := s.GetTask(); got != nil {
		t.Errorf("GetTask() after clear = %v, want nil", got)
	}
}

func TestConnectionInfo(t *testing.T) {
	s := New()
	s.SetAgentID("agent-42")
	s.SetStatus(StatusConnected)
	s.SetRoster([]*pb.AgentInfo{{Id: "a1"}, {Id: "a2"}})

	info := s.GetConnectionInfo()
	if info.AgentID != "agent-42" {
		t.Errorf("ConnectionInfo.AgentID = %q, want %q", info.AgentID, "agent-42")
	}
	if info.Status != StatusConnected {
		t.Errorf("ConnectionInfo.Status = %q, want %q", info.Status, StatusConnected)
	}
	if info.PeerCount != 2 {
		t.Errorf("ConnectionInfo.PeerCount = %d, want %d", info.PeerCount, 2)
	}
}

func TestGetUptime(t *testing.T) {
	s := New()
	time.Sleep(10 * time.Millisecond)
	uptime := s.GetUptime()
	if uptime < 10*time.Millisecond {
		t.Errorf("GetUptime() = %s, want >= 10ms", uptime)
	}
}

func TestConcurrentAccess(t *testing.T) {
	s := New()
	var wg sync.WaitGroup

	// Concurrent writers.
	for i := 0; i < 10; i++ {
		wg.Add(1)
		go func(n int) {
			defer wg.Done()
			s.SetAgentID("agent")
			s.SetStatus(StatusConnected)
			s.SetRoster([]*pb.AgentInfo{{Id: "a1"}})
			s.PushMessage(Message{Type: "task_request"})
			s.SetTask(&pb.TaskRequest{TaskId: "t1"})
		}(i)
	}

	// Concurrent readers.
	for i := 0; i < 10; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			_ = s.GetAgentID()
			_ = s.GetStatus()
			_ = s.IsConnected()
			_ = s.GetRoster()
			_, _ = s.GetAgent("a1")
			_ = s.GetCapable("test")
			_ = s.PopMessages()
			_ = s.GetTask()
			_ = s.GetConnectionInfo()
			_ = s.GetUptime()
		}()
	}

	wg.Wait()
}
