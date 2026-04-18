package main

import (
	"compress/gzip"
	"io"
	"net/http"
	"strings"
	"sync"
)

// gzipMiddleware wraps a handler so that clients advertising
// `Accept-Encoding: gzip` receive a gzipped body. `URLSession` on iOS
// sets that header by default (it also transparently decompresses on the
// way in), so enabling this is a pure win for every Swift client.
//
// Responses from /health and /version gzip to ~30 bytes — smaller than
// the wire headers, so the tradeoff is neutral. /history drops from
// ~130 KB to ~21 KB (measured on the test host), a ~6× reduction.
//
// We intentionally don't skip small responses by length: the stdlib
// ResponseWriter doesn't know the content size up front unless the
// handler sets Content-Length, and tracking that adds complexity we
// don't need at this scale.
func gzipMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !strings.Contains(r.Header.Get("Accept-Encoding"), "gzip") {
			next.ServeHTTP(w, r)
			return
		}
		// Content-Length would lie once we gzip; strip it. Vary tells
		// any intermediary cache that encoding is negotiated.
		w.Header().Del("Content-Length")
		w.Header().Set("Content-Encoding", "gzip")
		w.Header().Set("Vary", "Accept-Encoding")

		gz := gzipPool.Get().(*gzip.Writer)
		defer gzipPool.Put(gz)
		gz.Reset(w)
		defer gz.Close()

		next.ServeHTTP(&gzipResponseWriter{Writer: gz, ResponseWriter: w}, r)
	})
}

type gzipResponseWriter struct {
	io.Writer
	http.ResponseWriter
}

func (g *gzipResponseWriter) Write(b []byte) (int, error) {
	return g.Writer.Write(b)
}

// Pool the gzip writers — each NewWriter allocates ~250 KB of
// compression state, so we don't want to churn them at 1 Hz.
var gzipPool = sync.Pool{
	New: func() any {
		// DefaultCompression is the right tradeoff for JSON — higher
		// levels spend a lot more CPU for a few percent gain.
		gz, _ := gzip.NewWriterLevel(io.Discard, gzip.DefaultCompression)
		return gz
	},
}
