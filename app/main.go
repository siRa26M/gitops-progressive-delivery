// demo-app: a tiny, dependency-free HTTP service used to exercise progressive delivery.
//
// Endpoints:
//   GET /         -> JSON payload (version, env, pod, colour). Honours ERROR_RATE / LATENCY_MS for fault injection.
//   GET /secret   -> SHA-256 fingerprint of the mounted secret (never the value) - proves secret rotation.
//   GET /healthz  -> liveness
//   GET /readyz   -> readiness
//   GET /metrics  -> Prometheus text exposition (http_requests_total{route,code}, app_info{version})
package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"log"
	"math/rand/v2"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

// version is injected at build time: -ldflags "-X main.version=1.2.0"
var version = "dev"

type config struct {
	Port       string
	Env        string
	Message    string
	Pod        string
	ErrorRate  float64
	LatencyMS  int
	SecretsDir string
}

func loadConfig() config {
	return config{
		Port:       getenv("PORT", "8080"),
		Env:        getenv("APP_ENV", "local"),
		Message:    getenv("APP_MESSAGE", "hello from demo-app"),
		Pod:        getenv("POD_NAME", hostname()),
		ErrorRate:  clamp(parseFloat(getenv("ERROR_RATE", "0")), 0, 1),
		LatencyMS:  parseInt(getenv("LATENCY_MS", "0")),
		SecretsDir: getenv("SECRETS_DIR", "/etc/demo-app/secrets"),
	}
}

// ---------------------------------------------------------------- metrics

type counterKey struct{ route, code string }

type metrics struct {
	mu   sync.Mutex
	reqs map[counterKey]uint64
}

func newMetrics() *metrics { return &metrics{reqs: map[counterKey]uint64{}} }

func (m *metrics) inc(route string, code int) {
	m.mu.Lock()
	m.reqs[counterKey{route, strconv.Itoa(code)}]++
	m.mu.Unlock()
}

func (m *metrics) render(w http.ResponseWriter) {
	m.mu.Lock()
	keys := make([]counterKey, 0, len(m.reqs))
	for k := range m.reqs {
		keys = append(keys, k)
	}
	sort.Slice(keys, func(i, j int) bool {
		if keys[i].route == keys[j].route {
			return keys[i].code < keys[j].code
		}
		return keys[i].route < keys[j].route
	})
	var b strings.Builder
	b.WriteString("# HELP http_requests_total Total HTTP requests by route and status code.\n")
	b.WriteString("# TYPE http_requests_total counter\n")
	for _, k := range keys {
		fmt.Fprintf(&b, "http_requests_total{route=%q,code=%q} %d\n", k.route, k.code, m.reqs[k])
	}
	m.mu.Unlock()
	b.WriteString("# HELP app_info Build information.\n# TYPE app_info gauge\n")
	fmt.Fprintf(&b, "app_info{version=%q} 1\n", version)
	w.Header().Set("Content-Type", "text/plain; version=0.0.4")
	_, _ = w.Write([]byte(b.String()))
}

// ---------------------------------------------------------------- handlers

type statusRecorder struct {
	http.ResponseWriter
	code int
}

func (r *statusRecorder) WriteHeader(code int) { r.code = code; r.ResponseWriter.WriteHeader(code) }

func instrument(m *metrics, route string, h http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		rec := &statusRecorder{ResponseWriter: w, code: http.StatusOK}
		h(rec, r)
		m.inc(route, rec.code)
	}
}

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}

func rootHandler(cfg config) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/" {
			writeJSON(w, http.StatusNotFound, map[string]string{"error": "not found"})
			return
		}
		if cfg.LatencyMS > 0 {
			time.Sleep(time.Duration(cfg.LatencyMS) * time.Millisecond)
		}
		if cfg.ErrorRate > 0 && rand.Float64() < cfg.ErrorRate {
			writeJSON(w, http.StatusInternalServerError, map[string]any{
				"error": "injected failure", "version": version, "pod": cfg.Pod,
			})
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{
			"app":     "demo-app",
			"version": version,
			"colour":  colourFor(version),
			"env":     cfg.Env,
			"pod":     cfg.Pod,
			"message": cfg.Message,
		})
	}
}

// secretHandler re-reads the mounted secret on every request. Kubernetes refreshes
// secret volumes in place (no subPath), so a rotated SealedSecret becomes visible
// without a pod restart.
func secretHandler(cfg config) http.HandlerFunc {
	return func(w http.ResponseWriter, _ *http.Request) {
		out := map[string]string{}
		for _, name := range []string{"API_KEY", "DB_PASSWORD"} {
			b, err := os.ReadFile(filepath.Join(cfg.SecretsDir, name))
			if err != nil {
				out[name] = "missing"
				continue
			}
			out[name] = fingerprint(b)
		}
		writeJSON(w, http.StatusOK, map[string]any{"pod": cfg.Pod, "sha256_prefix": out})
	}
}

func fingerprint(b []byte) string {
	sum := sha256.Sum256([]byte(strings.TrimSpace(string(b))))
	return hex.EncodeToString(sum[:])[:12]
}

func newMux(cfg config, m *metrics) *http.ServeMux {
	mux := http.NewServeMux()
	mux.HandleFunc("/", instrument(m, "/", rootHandler(cfg)))
	mux.HandleFunc("/secret", instrument(m, "/secret", secretHandler(cfg)))
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) { _, _ = w.Write([]byte("ok")) })
	mux.HandleFunc("/readyz", func(w http.ResponseWriter, _ *http.Request) { _, _ = w.Write([]byte("ready")) })
	mux.HandleFunc("/metrics", func(w http.ResponseWriter, _ *http.Request) { m.render(w) })
	return mux
}

func main() {
	cfg := loadConfig()
	m := newMetrics()
	srv := &http.Server{
		Addr:              ":" + cfg.Port,
		Handler:           newMux(cfg, m),
		ReadHeaderTimeout: 5 * time.Second,
	}

	go func() {
		log.Printf("demo-app version=%s env=%s error_rate=%.2f listening on :%s", version, cfg.Env, cfg.ErrorRate, cfg.Port)
		if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Fatalf("listen: %v", err)
		}
	}()

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGINT, syscall.SIGTERM)
	<-stop
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	_ = srv.Shutdown(ctx)
	log.Print("shutdown complete")
}

// ---------------------------------------------------------------- helpers

func colourFor(v string) string {
	palette := []string{"blue", "green", "orange", "purple", "teal", "red"}
	h := sha256.Sum256([]byte(v))
	return palette[int(h[0])%len(palette)]
}

func getenv(k, def string) string {
	if v, ok := os.LookupEnv(k); ok && v != "" {
		return v
	}
	return def
}

func hostname() string { h, _ := os.Hostname(); return h }

func parseFloat(s string) float64 { f, _ := strconv.ParseFloat(s, 64); return f }

func parseInt(s string) int { i, _ := strconv.Atoi(s); return i }

func clamp(v, lo, hi float64) float64 {
	if v < lo {
		return lo
	}
	if v > hi {
		return hi
	}
	return v
}
