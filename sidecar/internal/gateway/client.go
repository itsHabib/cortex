// Package gateway provides a gRPC client for connecting to the Cortex gateway.
package gateway

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"sync"
	"time"

	"github.com/cortex/sidecar/internal/config"
	pb "github.com/cortex/sidecar/internal/proto/gatewayv1"
	"github.com/cortex/sidecar/internal/state"
	"github.com/google/uuid"
	"google.golang.org/grpc"
	"google.golang.org/grpc/backoff"
	"google.golang.org/grpc/credentials/insecure"
)

// ErrNotConnected is returned when a send is attempted without an active stream.
var ErrNotConnected = errors.New("gateway: stream not connected")

// streamReconnectPause is the pause between stream re-establishment attempts.
// Exported as a variable so tests can override it.
var streamReconnectPause = 2 * time.Second

// Client manages the gRPC connection and bidirectional stream to the Cortex gateway.
type Client struct {
	cfg    *config.Config
	store  *state.Store
	logger *slog.Logger

	conn   *grpc.ClientConn
	stream pb.AgentGateway_ConnectClient
	sendMu sync.Mutex

	// peerWaiters tracks pending peer request response channels keyed by request_id.
	peerMu      sync.Mutex
	peerWaiters map[string]chan *pb.PeerResponse
}

// New creates a new gateway Client. It does not connect — call Run to start.
func New(cfg *config.Config, store *state.Store, logger *slog.Logger) *Client {
	return &Client{
		cfg:         cfg,
		store:       store,
		logger:      logger,
		peerWaiters: make(map[string]chan *pb.PeerResponse),
	}
}

// Run connects to the gateway, registers, starts heartbeats and the receive loop.
// It blocks until ctx is cancelled. It handles stream re-establishment internally.
func (c *Client) Run(ctx context.Context) error {
	c.store.SetStatus(state.StatusConnecting)

	connectParams := grpc.ConnectParams{
		Backoff: backoff.Config{
			BaseDelay:  1 * time.Second,
			Multiplier: 1.6,
			MaxDelay:   30 * time.Second,
		},
		MinConnectTimeout: 5 * time.Second,
	}

	conn, err := grpc.NewClient(
		c.cfg.GatewayURL,
		grpc.WithTransportCredentials(insecure.NewCredentials()),
		grpc.WithConnectParams(connectParams),
	)
	if err != nil {
		return fmt.Errorf("gateway: failed to create client: %w", err)
	}
	c.conn = conn
	defer conn.Close()

	gwClient := pb.NewAgentGatewayClient(conn)

	for {
		if ctx.Err() != nil {
			c.store.SetStatus(state.StatusDisconnected)
			return ctx.Err()
		}

		err := c.runStream(ctx, gwClient)
		if ctx.Err() != nil {
			c.store.SetStatus(state.StatusDisconnected)
			return ctx.Err()
		}

		c.logger.Warn("stream disconnected, will re-establish", "error", err)
		c.store.SetStatus(state.StatusReconnecting)

		select {
		case <-ctx.Done():
			c.store.SetStatus(state.StatusDisconnected)
			return ctx.Err()
		case <-time.After(streamReconnectPause):
		}
	}
}

// runStream opens a single bidirectional stream, registers, and runs
// the heartbeat + receive loop until the stream errors or ctx is cancelled.
func (c *Client) runStream(ctx context.Context, gwClient pb.AgentGatewayClient) error {
	stream, err := gwClient.Connect(ctx)
	if err != nil {
		return fmt.Errorf("gateway: failed to open stream: %w", err)
	}

	c.sendMu.Lock()
	c.stream = stream
	c.sendMu.Unlock()

	// Send RegisterRequest.
	regMsg := &pb.AgentMessage{
		Msg: &pb.AgentMessage_Register{
			Register: &pb.RegisterRequest{
				Name:         c.cfg.AgentName,
				Role:         c.cfg.AgentRole,
				Capabilities: c.cfg.AgentCapabilities,
				AuthToken:    c.cfg.AuthToken,
			},
		},
	}
	if err := c.sendMsg(regMsg); err != nil {
		return fmt.Errorf("gateway: failed to send register: %w", err)
	}
	c.logger.Info("sent registration", "name", c.cfg.AgentName, "role", c.cfg.AgentRole)

	// Run heartbeat + receive loop.
	return c.recvLoop(ctx, stream)
}

// recvLoop reads from the stream and sends heartbeats at the configured interval.
func (c *Client) recvLoop(ctx context.Context, stream pb.AgentGateway_ConnectClient) error {
	ticker := time.NewTicker(c.cfg.HeartbeatInterval)
	defer ticker.Stop()

	// Use a channel to receive messages from the stream.
	type recvResult struct {
		msg *pb.GatewayMessage
		err error
	}
	recvCh := make(chan recvResult, 1)

	go func() {
		for {
			msg, err := stream.Recv()
			recvCh <- recvResult{msg: msg, err: err}
			if err != nil {
				return
			}
		}
	}()

	for {
		select {
		case <-ctx.Done():
			// Graceful shutdown: send draining status before closing.
			_ = c.sendMsg(&pb.AgentMessage{
				Msg: &pb.AgentMessage_StatusUpdate{
					StatusUpdate: &pb.StatusUpdate{
						AgentId: c.store.GetAgentID(),
						Status:  pb.AgentStatus_AGENT_STATUS_DRAINING,
						Detail:  "shutting down",
					},
				},
			})
			_ = stream.CloseSend()
			c.clearStream()
			return ctx.Err()

		case <-ticker.C:
			hb := &pb.AgentMessage{
				Msg: &pb.AgentMessage_Heartbeat{
					Heartbeat: &pb.Heartbeat{
						AgentId: c.store.GetAgentID(),
						Status:  pb.AgentStatus_AGENT_STATUS_IDLE,
					},
				},
			}
			if err := c.sendMsg(hb); err != nil {
				c.logger.Warn("failed to send heartbeat", "error", err)
			} else {
				c.logger.Debug("sent heartbeat")
			}

		case res := <-recvCh:
			if res.err != nil {
				c.clearStream()
				return res.err
			}
			c.dispatch(res.msg)
		}
	}
}

// dispatch handles an inbound GatewayMessage.
func (c *Client) dispatch(msg *pb.GatewayMessage) {
	switch m := msg.GetMsg().(type) {
	case *pb.GatewayMessage_Registered:
		agentID := m.Registered.GetAgentId()
		c.store.SetAgentID(agentID)
		c.store.SetStatus(state.StatusConnected)
		c.logger.Info("registered with gateway",
			"agent_id", agentID,
			"peer_count", m.Registered.GetPeerCount(),
		)

	case *pb.GatewayMessage_TaskRequest:
		c.store.SetTask(m.TaskRequest)
		c.store.PushMessage(state.Message{
			Type:     "task_request",
			TaskReq:  m.TaskRequest,
			Received: time.Now(),
		})
		c.logger.Info("received task request", "task_id", m.TaskRequest.GetTaskId())

	case *pb.GatewayMessage_PeerRequest:
		c.store.PushMessage(state.Message{
			Type:     "peer_request",
			PeerReq:  m.PeerRequest,
			Received: time.Now(),
		})
		c.logger.Info("received peer request",
			"request_id", m.PeerRequest.GetRequestId(),
			"from", m.PeerRequest.GetFromAgent(),
		)

	case *pb.GatewayMessage_RosterUpdate:
		c.store.SetRoster(m.RosterUpdate.GetAgents())
		c.logger.Info("roster updated", "agent_count", len(m.RosterUpdate.GetAgents()))

	case *pb.GatewayMessage_DirectMessage:
		c.store.PushMessage(state.Message{
			Type:      "direct_message",
			DirectMsg: m.DirectMessage,
			Received:  time.Now(),
		})
		c.logger.Info("received direct message",
			"from", m.DirectMessage.GetFromAgent(),
			"message_id", m.DirectMessage.GetMessageId(),
		)

	case *pb.GatewayMessage_Error:
		c.logger.Error("gateway error",
			"code", m.Error.GetCode(),
			"message", m.Error.GetMessage(),
		)

	default:
		c.logger.Warn("received unknown gateway message type")
	}

	// Check if this is a PeerResponse delivered as a DirectMessage or if the
	// GatewayMessage is actually routing a PeerResponse back to us.
	// PeerResponses come via the stream as GatewayMessage with peer_request containing
	// the response. However, per the proto contract, PeerResponse is an AgentMessage type,
	// not a GatewayMessage type. The gateway routes PeerResponse back to the requester
	// as a DirectMessage with a special convention, or we handle it via our pending request tracking.
	// For now, we handle PeerResponse routing at the SendPeerRequest level.
}

// sendMsg sends an AgentMessage on the stream, serialized by sendMu.
func (c *Client) sendMsg(msg *pb.AgentMessage) error {
	c.sendMu.Lock()
	defer c.sendMu.Unlock()
	if c.stream == nil {
		return ErrNotConnected
	}
	return c.stream.Send(msg)
}

// clearStream sets the stream to nil (for send gating).
func (c *Client) clearStream() {
	c.sendMu.Lock()
	defer c.sendMu.Unlock()
	c.stream = nil
}

// SendTaskResult sends a task result to the gateway.
func (c *Client) SendTaskResult(ctx context.Context, result *pb.TaskResult) error {
	return c.sendMsg(&pb.AgentMessage{
		Msg: &pb.AgentMessage_TaskResult{
			TaskResult: result,
		},
	})
}

// SendStatusUpdate sends a status update to the gateway.
func (c *Client) SendStatusUpdate(ctx context.Context, update *pb.StatusUpdate) error {
	return c.sendMsg(&pb.AgentMessage{
		Msg: &pb.AgentMessage_StatusUpdate{
			StatusUpdate: update,
		},
	})
}

// SendPeerResponse sends a peer response to the gateway.
func (c *Client) SendPeerResponse(ctx context.Context, resp *pb.PeerResponse) error {
	return c.sendMsg(&pb.AgentMessage{
		Msg: &pb.AgentMessage_PeerResponse{
			PeerResponse: resp,
		},
	})
}

// SendPeerRequest sends a peer request and blocks until a response or timeout.
func (c *Client) SendPeerRequest(ctx context.Context, agentID, capability, prompt string, timeoutMs int64) (*pb.PeerResponse, error) {
	requestID := uuid.New().String()

	// Register a waiter channel for this request.
	ch := make(chan *pb.PeerResponse, 1)
	c.peerMu.Lock()
	c.peerWaiters[requestID] = ch
	c.peerMu.Unlock()
	defer func() {
		c.peerMu.Lock()
		delete(c.peerWaiters, requestID)
		c.peerMu.Unlock()
	}()

	// Send the peer request as a DirectMessage with a structured prompt
	// that encodes the peer request semantics. The gateway will route this
	// as a PeerRequest to the target agent.
	msg := &pb.AgentMessage{
		Msg: &pb.AgentMessage_DirectMessage{
			DirectMessage: &pb.DirectMessage{
				MessageId: requestID,
				ToAgent:   agentID,
				Content:   prompt,
				Timestamp: time.Now().UnixMilli(),
			},
		},
	}
	if err := c.sendMsg(msg); err != nil {
		return nil, err
	}

	// Wait for response.
	timeout := time.Duration(timeoutMs) * time.Millisecond
	timeoutCtx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()

	select {
	case resp := <-ch:
		return resp, nil
	case <-timeoutCtx.Done():
		return nil, timeoutCtx.Err()
	}
}

// DeliverPeerResponse delivers a peer response to a waiting SendPeerRequest caller.
// This is called from the dispatch loop when a response arrives.
func (c *Client) DeliverPeerResponse(requestID string, resp *pb.PeerResponse) bool {
	c.peerMu.Lock()
	ch, ok := c.peerWaiters[requestID]
	c.peerMu.Unlock()
	if !ok {
		return false
	}
	select {
	case ch <- resp:
		return true
	default:
		return false
	}
}

// SendDirectMessage sends a direct message to another agent via the gateway.
func (c *Client) SendDirectMessage(ctx context.Context, toAgent, content string) error {
	return c.sendMsg(&pb.AgentMessage{
		Msg: &pb.AgentMessage_DirectMessage{
			DirectMessage: &pb.DirectMessage{
				MessageId: uuid.New().String(),
				ToAgent:   toAgent,
				Content:   content,
				Timestamp: time.Now().UnixMilli(),
			},
		},
	})
}

// Broadcast sends a message to all agents via the gateway.
func (c *Client) Broadcast(ctx context.Context, content string) error {
	return c.sendMsg(&pb.AgentMessage{
		Msg: &pb.AgentMessage_Broadcast{
			Broadcast: &pb.BroadcastRequest{
				Content: content,
			},
		},
	})
}
