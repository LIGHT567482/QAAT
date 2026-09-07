package main

import (
	"context"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/redis/go-redis/v9"

	"github.com/qaat/api-gateway/internal/clock"
	"github.com/qaat/api-gateway/internal/config"
	"github.com/qaat/api-gateway/internal/jobs"
	"github.com/qaat/api-gateway/internal/keepalive"
	"github.com/qaat/api-gateway/internal/router"
	"github.com/qaat/api-gateway/internal/scheduler"
)

func main() {
	cfg, err := config.Load()
	if err != nil {
		slog.Error("config load failed", "error", err)
		os.Exit(1)
	}

	logger := newLogger(cfg.LogLevel)

	// ─── Database ─────────────────────────────────────────────────────────────
	poolCfg, err := pgxpool.ParseConfig(cfg.DBURL)
	if err != nil {
		logger.Error("postgres config parse failed", "error", err)
		os.Exit(1)
	}
	// Clear any tenant GUC before a pooled connection is handed out, so a
	// session-scoped app.current_tenant from a previous request can never leak
	// to a different tenant. Each handler re-sets it via middleware.SetTenantConn.
	poolCfg.BeforeAcquire = func(ctx context.Context, c *pgx.Conn) bool {
		_, err := c.Exec(ctx, "SELECT set_config('app.current_tenant', '', false)")
		return err == nil
	}
	// Pin every connection to the institution's timezone so SQL's CURRENT_DATE,
	// now() and EXTRACT(ISODOW …) answer the same "what day is it" that
	// clock.Today() does in Go. Without this the two disagree by the container's
	// UTC offset, which is how a session opened in the evening could be filed
	// under tomorrow.
	poolCfg.AfterConnect = func(ctx context.Context, c *pgx.Conn) error {
		_, err := c.Exec(ctx, "SET TIME ZONE '"+clock.Name()+"'")
		return err
	}
	pool, err := pgxpool.NewWithConfig(context.Background(), poolCfg)
	if err != nil {
		logger.Error("postgres connect failed", "error", err)
		os.Exit(1)
	}
	defer pool.Close()

	pingCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := pool.Ping(pingCtx); err != nil {
		logger.Error("postgres ping failed", "error", err)
		os.Exit(1)
	}
	logger.Info("postgres connected", "timezone", clock.Name())

	// Privileged pool for the ADMIN-gated, cross-tenant platform handlers only.
	// Falls back to the data-plane pool if ADMIN_DB_URL is unset/identical.
	adminPool := pool
	if cfg.AdminDBURL != "" && cfg.AdminDBURL != cfg.DBURL {
		adminCfg, err := pgxpool.ParseConfig(cfg.AdminDBURL)
		if err != nil {
			logger.Error("admin postgres config parse failed", "error", err)
			os.Exit(1)
		}
		// The same Kampala pin as the data-plane pool. The admin pool runs the
		// rooms "in use right now" query and the scheduled jobs, both of which
		// key on CURRENT_DATE; without this they'd count days in UTC and a
		// session between 00:00 and 03:00 Kampala time would vanish from "in
		// use" (the date changed in UTC before it did at the school).
		adminCfg.AfterConnect = func(ctx context.Context, c *pgx.Conn) error {
			_, err := c.Exec(ctx, "SET TIME ZONE '"+clock.Name()+"'")
			return err
		}
		adminPool, err = pgxpool.NewWithConfig(context.Background(), adminCfg)
		if err != nil {
			logger.Error("admin postgres connect failed", "error", err)
			os.Exit(1)
		}
		defer adminPool.Close()
		if err := adminPool.Ping(pingCtx); err != nil {
			logger.Error("admin postgres ping failed", "error", err)
			os.Exit(1)
		}
		logger.Info("admin postgres connected", "timezone", clock.Name())
	}

	// ─── Redis ────────────────────────────────────────────────────────────────
	opts, err := redis.ParseURL(cfg.RedisURL)
	if err != nil {
		logger.Error("redis URL parse failed", "error", err)
		os.Exit(1)
	}
	rdb := redis.NewClient(opts)
	defer rdb.Close()

	if _, err := rdb.Ping(context.Background()).Result(); err != nil {
		logger.Error("redis ping failed", "error", err)
		os.Exit(1)
	}
	logger.Info("redis connected")

	// ─── Router ───────────────────────────────────────────────────────────────
	handler := router.New(
		cfg.JWT.PublicKey,
		cfg.JWT.Issuer,
		cfg.JWT.Audience,
		rdb,
		pool,
		adminPool,
		cfg.CORSOrigins,
		cfg.Env,
		router.Upstreams{
			AuthService:    cfg.AuthServiceURL,
			SessionManager: cfg.SessionManagerURL,
			SyncReceiver:   cfg.SyncReceiverURL,
		},
	)

	// ─── Scheduled jobs ───────────────────────────────────────────────────────
	// Reminders, the attendance chase and the QA escalation. Runs in-process
	// rather than as a Render cron job because the free plan has no cron service —
	// and because the scheduler is written to catch up on every window it slept
	// through, which an external trigger would have to reimplement anyway.
	//
	// The admin pool: these jobs read across every tenant in one sweep, so they
	// cannot use the RLS-confined data-plane connection.
	sched := scheduler.New(adminPool, logger)
	jobs.Register(sched, adminPool)
	jobs.RegisterEmployeeJobs(sched, adminPool)
	sched.Start(context.Background())
	defer sched.Stop()

	// ─── keepalive warm loop ──────────────────────────────────────────────────
	// The gateway keeps ITSELF and every sibling public service awake by pinging
	// their /health endpoints on a timer (see internal/keepalive). This is what
	// stops the free-tier instances from sleeping into a 502 mid-request: while
	// the gateway is up, nothing in the stack idles out. Production (render.yaml)
	// sets WARM_ENABLED=true; local dev is left with it off so a laptop running the
	// compose stack doesn't ping the real prod instances.
	warmSiblings := cfg.WarmSiblingURLs
	if len(warmSiblings) == 0 {
		// Derive each sibling's health URL from the configured service URLs. Render
		// addresses them by their public onrender.com URLs (free tier has no private
		// service type), and every sibling answers GET /health.
		for _, base := range []string{cfg.AuthServiceURL, cfg.SessionManagerURL, cfg.SyncReceiverURL, cfg.NotificationURL} {
			if base == "" {
				continue
			}
			warmSiblings = append(warmSiblings, strings.TrimRight(base, "/")+"/health")
		}
	}
	keepalive.Start(context.Background(), logger, keepalive.Targets{
		Self:     cfg.WarmSelfURL,
		Siblings: warmSiblings,
		Interval: time.Duration(cfg.WarmIntervalSeconds) * time.Second,
		Disabled: !cfg.WarmEnabled,
	})

	// ─── Server ───────────────────────────────────────────────────────────────
	srv := &http.Server{
		Addr:         ":" + cfg.Port,
		Handler:      handler,
		ReadTimeout:  15 * time.Second,
		WriteTimeout: 30 * time.Second,
		IdleTimeout:  60 * time.Second,
	}

	go func() {
		logger.Info("api-gateway listening", "port", cfg.Port)
		if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			logger.Error("server error", "error", err)
			os.Exit(1)
		}
	}()

	// ─── Graceful shutdown ────────────────────────────────────────────────────
	quit := make(chan os.Signal, 1)
	signal.Notify(quit, syscall.SIGINT, syscall.SIGTERM)
	<-quit

	logger.Info("shutting down api-gateway")
	shutdownCtx, shutdownCancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer shutdownCancel()
	if err := srv.Shutdown(shutdownCtx); err != nil {
		logger.Error("shutdown error", "error", err)
	}
}

func newLogger(level string) *slog.Logger {
	var lvl slog.Level
	switch level {
	case "debug":
		lvl = slog.LevelDebug
	case "warn":
		lvl = slog.LevelWarn
	case "error":
		lvl = slog.LevelError
	default:
		lvl = slog.LevelInfo
	}
	return slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: lvl}))
}
