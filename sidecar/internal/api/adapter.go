// Package api provides adapters to bridge the proto-based state/gateway types
// to the API's interface types.
package api

import (
	"context"
	"fmt"
	"strings"
	"time"

	pb "github.com/cortex/sidecar/internal/proto/gatewayv1"
)

// StateAdapter wraps state.Store to satisfy StateReader.
type StateAdapter struct {
	GetRosterFn      func() []*pb.AgentInfo
	GetAgentFn       func(id string) (*pb.AgentInfo, bool)
	GetCapableFn     func(capability string) []*pb.AgentInfo
	PopMessagesFn    func() []RawMessage
	GetTaskFn        func() *pb.TaskRequest
	IsConnectedFn    func() bool
	GetAgentIDFn     func() string
	GetUptimeFn      func() time.Duration
	GetStatusFn      func() string
	GetConnInfoFn    func() RawConnectionInfo
}

// RawMessage matches the shape of state.Message without importing the package.
type RawMessage struct {
	Type      string
	TaskReq   *pb.TaskRequest
	PeerReq   *pb.PeerRequest
	DirectMsg *pb.DirectMessage
	Received  time.Time
}

// RawConnectionInfo matches state.ConnectionInfo.
type RawConnectionInfo struct {
	AgentID   string
	Status    string
	PeerCount int
}

func (a *StateAdapter) GetRoster() []AgentInfo {
	roster := a.GetRosterFn()
	result := make([]AgentInfo, 0, len(roster))
	for _, agent := range roster {
		result = append(result, protoAgentToAPI(agent))
	}
	return result
}

func (a *StateAdapter) GetAgent(id string) (AgentInfo, bool) {
	agent, ok := a.GetAgentFn(id)
	if !ok {
		return AgentInfo{}, false
	}
	return protoAgentToAPI(agent), true
}

func (a *StateAdapter) GetCapable(capability string) []AgentInfo {
	agents := a.GetCapableFn(capability)
	result := make([]AgentInfo, 0, len(agents))
	for _, agent := range agents {
		result = append(result, protoAgentToAPI(agent))
	}
	return result
}

func (a *StateAdapter) PopMessages() []Message {
	msgs := a.PopMessagesFn()
	result := make([]Message, 0, len(msgs))
	for _, m := range msgs {
		msg := Message{Timestamp: m.Received}
		if m.DirectMsg != nil {
			msg.ID = m.DirectMsg.MessageId
			msg.FromAgent = m.DirectMsg.FromAgent
			msg.Content = m.DirectMsg.Content
		} else if m.PeerReq != nil {
			msg.ID = m.PeerReq.RequestId
			msg.FromAgent = m.PeerReq.FromAgent
			msg.Content = m.PeerReq.Prompt
		}
		result = append(result, msg)
	}
	return result
}

func (a *StateAdapter) GetTask() *TaskInfo {
	task := a.GetTaskFn()
	if task == nil {
		return nil
	}
	return &TaskInfo{
		TaskID:    task.TaskId,
		Prompt:    task.Prompt,
		TimeoutMs: task.TimeoutMs,
		Tools:     task.Tools,
		Context:   task.Context,
	}
}

func (a *StateAdapter) IsConnected() bool                  { return a.IsConnectedFn() }
func (a *StateAdapter) GetAgentID() string                 { return a.GetAgentIDFn() }
func (a *StateAdapter) GetUptime() time.Duration           { return a.GetUptimeFn() }
func (a *StateAdapter) GetStatus() string                  { return a.GetStatusFn() }
func (a *StateAdapter) GetConnectionInfo() ConnectionInfo {
	ci := a.GetConnInfoFn()
	return ConnectionInfo{AgentID: ci.AgentID, Status: ci.Status, PeerCount: ci.PeerCount}
}

// GatewayAdapter wraps gateway.Client to satisfy GatewayClient.
type GatewayAdapter struct {
	SendDirectMessageFn func(ctx context.Context, toAgent, content string) error
	BroadcastFn         func(ctx context.Context, content string) error
	SendPeerRequestFn   func(ctx context.Context, agentID, capability, prompt string, timeoutMs int64) (*pb.PeerResponse, error)
	SendStatusUpdateFn  func(ctx context.Context, update *pb.StatusUpdate) error
	SendTaskResultFn    func(ctx context.Context, result *pb.TaskResult) error
}

func (a *GatewayAdapter) SendDirectMessage(ctx context.Context, toAgent, content string) error {
	return a.SendDirectMessageFn(ctx, toAgent, content)
}

func (a *GatewayAdapter) Broadcast(ctx context.Context, content string) error {
	return a.BroadcastFn(ctx, content)
}

func (a *GatewayAdapter) SendPeerRequest(ctx context.Context, agentID, capability, prompt string, timeoutMs int64) (*PeerResult, error) {
	resp, err := a.SendPeerRequestFn(ctx, agentID, capability, prompt, timeoutMs)
	if err != nil {
		return nil, err
	}
	return &PeerResult{
		Status:     fmt.Sprintf("%d", resp.Status),
		Result:     resp.Result,
		DurationMs: resp.DurationMs,
	}, nil
}

func (a *GatewayAdapter) SendStatusUpdate(ctx context.Context, status, detail string, progress float64) error {
	agentStatus, ok := pb.AgentStatus_value["AGENT_STATUS_"+strings.ToUpper(status)]
	if !ok {
		agentStatus = int32(pb.AgentStatus_AGENT_STATUS_UNSPECIFIED)
	}
	update := &pb.StatusUpdate{
		Status:   pb.AgentStatus(agentStatus),
		Detail:   detail,
		Progress: float32(progress),
	}
	return a.SendStatusUpdateFn(ctx, update)
}

func (a *GatewayAdapter) SendTaskResult(ctx context.Context, taskID, status, resultText string, durationMs int64, inputTokens, outputTokens int32) error {
	taskStatus, ok := pb.TaskStatus_value["TASK_STATUS_"+strings.ToUpper(status)]
	if !ok {
		taskStatus = int32(pb.TaskStatus_TASK_STATUS_UNSPECIFIED)
	}
	result := &pb.TaskResult{
		TaskId:       taskID,
		Status:       pb.TaskStatus(taskStatus),
		ResultText:   resultText,
		DurationMs:   durationMs,
		InputTokens:  inputTokens,
		OutputTokens: outputTokens,
	}
	return a.SendTaskResultFn(ctx, result)
}

func protoAgentToAPI(agent *pb.AgentInfo) AgentInfo {
	return AgentInfo{
		ID:           agent.Id,
		Name:         agent.Name,
		Role:         agent.Role,
		Capabilities: agent.Capabilities,
		Status:       fmt.Sprintf("%d", agent.Status),
		Metadata:     agent.Metadata,
	}
}
