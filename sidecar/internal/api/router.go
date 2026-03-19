package api

import (
	"log/slog"
	"net/http"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/go-chi/chi/v5/middleware"
)

// NewRouter creates a chi router with all sidecar API routes mounted.
func NewRouter(s *Server) chi.Router {
	r := chi.NewRouter()

	// Middleware stack
	r.Use(middleware.Recoverer)
	r.Use(requestLogger(s.logger))
	r.Use(jsonResponseHeader)

	// Health
	r.Get("/health", s.handleHealth)

	// Roster
	r.Get("/roster", s.handleRosterList)
	r.Get("/roster/{agentID}", s.handleRosterGet)
	r.Get("/roster/capable/{capability}", s.handleRosterCapable)

	// Messages
	r.Get("/messages", s.handleGetMessages)
	r.Post("/messages/{agentID}", s.handleSendMessage)
	r.Post("/broadcast", s.handleBroadcast)

	// Invocation
	r.Post("/ask/{agentID}", s.handleAskAgent)
	r.Post("/ask/capable/{capability}", s.handleAskCapable)

	// Knowledge (Phase 3 stubs)
	r.Get("/knowledge", s.handleQueryKnowledge)
	r.Post("/knowledge", s.handlePublishKnowledge)

	// Status and tasks
	r.Post("/status", s.handleReportStatus)
	r.Get("/task", s.handleGetTask)
	r.Post("/task/result", s.handleSubmitTaskResult)

	// Catch-all 404
	r.NotFound(func(w http.ResponseWriter, r *http.Request) {
		writeError(w, http.StatusNotFound, "not found", "NOT_FOUND")
	})

	return r
}

// requestLogger returns middleware that logs each request via slog.
func requestLogger(logger *slog.Logger) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			start := time.Now()
			ww := middleware.NewWrapResponseWriter(w, r.ProtoMajor)
			next.ServeHTTP(ww, r)
			logger.Info("http request",
				"method", r.Method,
				"path", r.URL.Path,
				"status", ww.Status(),
				"duration_ms", time.Since(start).Milliseconds(),
			)
		})
	}
}

// jsonResponseHeader sets the Content-Type to application/json for all responses.
func jsonResponseHeader(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		next.ServeHTTP(w, r)
	})
}
