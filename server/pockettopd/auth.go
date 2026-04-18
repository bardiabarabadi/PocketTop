package main

import (
	"net/http"
	"os"
	"strings"
	"sync"
)

// authMiddleware enforces Bearer-token auth on wrapped handlers. The API
// key is loaded from disk on first use and cached in memory. Whitespace
// is trimmed from the file contents (trailing newlines from openssl).
type authMiddleware struct {
	keyFile string

	mu     sync.RWMutex
	loaded bool
	key    string
	err    error
}

func newAuthMiddleware(keyFile string) *authMiddleware {
	return &authMiddleware{keyFile: keyFile}
}

// loadKey lazily reads the API key file and caches the result.
func (a *authMiddleware) loadKey() (string, error) {
	a.mu.RLock()
	if a.loaded {
		key, err := a.key, a.err
		a.mu.RUnlock()
		return key, err
	}
	a.mu.RUnlock()

	a.mu.Lock()
	defer a.mu.Unlock()
	if a.loaded {
		return a.key, a.err
	}
	data, err := os.ReadFile(a.keyFile)
	a.loaded = true
	if err != nil {
		a.err = err
		return "", err
	}
	a.key = strings.TrimSpace(string(data))
	return a.key, nil
}

// wrap returns an http.Handler that rejects requests missing or
// mismatching the Bearer token.
func (a *authMiddleware) wrap(next http.HandlerFunc) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		expected, err := a.loadKey()
		if err != nil || expected == "" {
			http.Error(w, `{"error":"api key not configured"}`, http.StatusInternalServerError)
			return
		}
		hdr := r.Header.Get("Authorization")
		const prefix = "Bearer "
		if !strings.HasPrefix(hdr, prefix) {
			http.Error(w, `{"error":"missing bearer token"}`, http.StatusUnauthorized)
			return
		}
		provided := strings.TrimSpace(hdr[len(prefix):])
		if provided != expected {
			http.Error(w, `{"error":"invalid bearer token"}`, http.StatusUnauthorized)
			return
		}
		next.ServeHTTP(w, r)
	})
}
