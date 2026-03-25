// Package main is the entrypoint for the Cortex sidecar binary.
package main

import (
	"context"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"sync"
	"syscall"
	"time"

	"github.com/cortex/sidecar/internal/api"
	"github.com/cortex/sidecar/internal/config"
	"github.com/cortex/sidecar/internal/gateway"
	"github.com/cortex/sidecar/internal/state"
	"github.com/spf13/cobra"
)

// version is set at build time via ldflags.
var version = "dev"

func main() {
	rootCmd := &cobra.Command{
		Use:   "cortex-sidecar",
		Short: "Cortex agent sidecar — connects to the Cortex gateway via gRPC",
		Long: `The Cortex sidecar runs alongside an agent process, connecting to the
Cortex gateway via gRPC bidirectional streaming. It handles registration,
heartbeats, and message routing, and exposes a local HTTP API for the agent.`,
		Version: version,
		RunE:    run,
	}

	if err := rootCmd.Execute(); err != nil {
		os.Exit(1)
	}
}

func run(cmd *cobra.Command, args []string) error {
	// Load and validate configuration from environment variables.
	cfg, err := config.Load()
	if err != nil {
		return fmt.Errorf("configuration error: %w", err)
	}

	// Set up structured logging.
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{
		Level: slog.LevelInfo,
	}))
	slog.SetDefault(logger)

	logger.Info("starting cortex sidecar",
		"version", version,
		"gateway_url", cfg.GatewayURL,
		"agent_name", cfg.AgentName,
		"agent_role", cfg.AgentRole,
		"sidecar_port", cfg.SidecarPort,
	)

	// Create shared state store.
	store := state.New()

	// Create gateway client.
	gwClient := gateway.New(cfg, store, logger.With("component", "gateway"))

	// Set up signal handling for graceful shutdown.
	ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer cancel()

	var wg sync.WaitGroup

	// Start the gRPC gateway client.
	wg.Add(1)
	go func() {
		defer wg.Done()
		if err := gwClient.Run(ctx); err != nil && ctx.Err() == nil {
			logger.Error("gateway client error", "error", err)
		}
	}()

	// Wire up the HTTP API router via adapters (bridge proto types to API types).
	stateAdapter := &api.StateAdapter{
		GetRosterFn:   store.GetRoster,
		GetAgentFn:    store.GetAgent,
		GetCapableFn:  store.GetCapable,
		PopMessagesFn: func() []api.RawMessage {
			msgs := store.PopMessages()
			result := make([]api.RawMessage, len(msgs))
			for i, m := range msgs {
				result[i] = api.RawMessage{
					Type:      m.Type,
					TaskReq:   m.TaskReq,
					PeerReq:   m.PeerReq,
					DirectMsg: m.DirectMsg,
					Received:  m.Received,
				}
			}
			return result
		},
		GetTaskFn:      store.GetTask,
		IsConnectedFn:  store.IsConnected,
		GetAgentIDFn:   store.GetAgentID,
		GetUptimeFn:    store.GetUptime,
		GetStatusFn:    func() string { return string(store.GetStatus()) },
		GetConnInfoFn: func() api.RawConnectionInfo {
			ci := store.GetConnectionInfo()
			return api.RawConnectionInfo{
				AgentID:   ci.AgentID,
				Status:    string(ci.Status),
				PeerCount: ci.PeerCount,
			}
		},
	}
	gwAdapter := &api.GatewayAdapter{
		SendDirectMessageFn: gwClient.SendDirectMessage,
		BroadcastFn:         gwClient.Broadcast,
		SendPeerRequestFn:   gwClient.SendPeerRequest,
		SendStatusUpdateFn:  gwClient.SendStatusUpdate,
		SendTaskResultFn:    gwClient.SendTaskResult,
	}
	apiServer := api.NewServer(stateAdapter, gwAdapter, logger.With("component", "http"))
	router := api.NewRouter(apiServer)

	httpAddr := fmt.Sprintf("0.0.0.0:%d", cfg.SidecarPort)
	httpServer := &http.Server{
		Addr:              httpAddr,
		Handler:           router,
		ReadHeaderTimeout: 10 * time.Second,
	}

	wg.Add(1)
	go func() {
		defer wg.Done()
		logger.Info("starting HTTP server", "addr", httpAddr)
		if err := httpServer.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			logger.Error("HTTP server error", "error", err)
		}
	}()

	// Wait for shutdown signal.
	<-ctx.Done()
	logger.Info("shutdown signal received, draining...")

	// Graceful shutdown with timeout.
	shutdownCtx, shutdownCancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer shutdownCancel()

	if err := httpServer.Shutdown(shutdownCtx); err != nil {
		logger.Error("HTTP server shutdown error", "error", err)
	}

	// Wait for all goroutines to finish.
	wg.Wait()
	logger.Info("sidecar stopped")
	return nil
}
