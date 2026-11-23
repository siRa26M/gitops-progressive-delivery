package main

import (
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func testCfg(t *testing.T, errorRate float64) config {
	dir := t.TempDir()
	_ = os.WriteFile(filepath.Join(dir, "API_KEY"), []byte("s3cr3t\n"), 0o600)
	return config{Env: "test", Pod: "pod-0", ErrorRate: errorRate, SecretsDir: dir}
}

func TestRootOK(t *testing.T) {
	m := newMetrics()
	srv := httptest.NewServer(newMux(testCfg(t, 0), m))
	defer srv.Close()

	resp, err := http.Get(srv.URL + "/")
	if err != nil || resp.StatusCode != http.StatusOK {
		t.Fatalf("want 200, got %v %v", resp, err)
	}
}

func TestErrorInjectionAndMetrics(t *testing.T) {
	m := newMetrics()
	srv := httptest.NewServer(newMux(testCfg(t, 1), m))
	defer srv.Close()

	resp, _ := http.Get(srv.URL + "/")
	if resp.StatusCode != http.StatusInternalServerError {
		t.Fatalf("want 500 with ERROR_RATE=1, got %d", resp.StatusCode)
	}

	rec := httptest.NewRecorder()
	m.render(rec)
	if !strings.Contains(rec.Body.String(), `http_requests_total{route="/",code="500"} 1`) {
		t.Fatalf("metrics missing 500 counter:\n%s", rec.Body.String())
	}
}

func TestSecretFingerprintNeverLeaksValue(t *testing.T) {
	srv := httptest.NewServer(newMux(testCfg(t, 0), newMetrics()))
	defer srv.Close()

	resp, _ := http.Get(srv.URL + "/secret")
	buf := new(strings.Builder)
	_, _ = bufCopy(buf, resp)
	if strings.Contains(buf.String(), "s3cr3t") {
		t.Fatal("secret value leaked")
	}
	if !strings.Contains(buf.String(), fingerprint([]byte("s3cr3t"))) {
		t.Fatalf("fingerprint missing: %s", buf.String())
	}
}

func bufCopy(b *strings.Builder, r *http.Response) (int64, error) {
	defer r.Body.Close()
	p := make([]byte, 4096)
	n, err := r.Body.Read(p)
	b.Write(p[:n])
	return int64(n), err
}
