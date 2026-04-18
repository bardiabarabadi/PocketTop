import Foundation

// MARK: - Errors

/// Errors surfaced by `MetricsService`. Transport failures are wrapped verbatim
/// so callers can distinguish "server replied with 4xx/5xx" from "network
/// didn't make it".
nonisolated enum MetricsError: Error, Sendable {
    /// Non-2xx HTTP response. `body` is the response body (best-effort UTF-8;
    /// empty string if decoding failed).
    case http(status: Int, body: String)
    /// Underlying network / URLSession error (timeout, TLS pinning failure,
    /// unreachable host, …). The wrapped error's `localizedDescription`
    /// carries detail.
    case transport(Error)
    /// Server returned 2xx but the body failed to decode as the expected type.
    case decode(Error)
    /// The response wasn't an `HTTPURLResponse` — extremely unlikely with
    /// URLSession over https, but the type system requires we handle it.
    case invalidResponse
}

// MARK: - Version response

/// Shape of `GET /version`. Used by the recovery `verifyConnection` flow to
/// confirm the agent is reachable before proceeding to authenticated calls.
nonisolated struct VersionResponse: Codable, Sendable {
    let version: String
    let api: String
}

// MARK: - Service

/// Metrics client for a single server. One instance per open detail screen
/// (the ref doc's `ChatService` analogue).
///
/// ### Sendability of `Server`
///
/// SwiftData `@Model` types are `@MainActor`-bound and not `Sendable`. We
/// therefore do NOT hold a `Server` reference across actor boundaries. Callers
/// extract the stable primitives (host, port, fingerprint, api key) on the
/// main actor and pass them in at init time. `MetricsService.init` captures
/// those plus the api key, and nothing else.
///
/// ### URLSession sharing
///
/// The underlying `URLSession` comes from `MetricsSessionPool.shared`, so
/// multiple `MetricsService` instances for the same host share a warm TLS
/// connection. The pool keys on `(host, port, certFP.prefix(16))`, matching
/// the constructor arguments.
actor MetricsService {
    // MARK: Snapshot of server fields needed for requests
    //
    // We store primitives rather than `Server` because `Server` isn't Sendable.
    private let host: String
    private let httpsPort: Int
    private let certFingerprint: String
    private let apiKey: String

    // MARK: Decoder
    //
    // One shared decoder per instance. Our `Snapshot` types declare explicit
    // CodingKeys for their snake_case fields, so no key-decoding strategy is
    // needed (and mixing one in would double-decode the already-correct keys).
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        return d
    }()

    // MARK: Init

    /// Construct from a `Server` model snapshot. Callers should invoke this on
    /// the main actor where `Server` properties are safe to read, then use the
    /// resulting actor freely.
    ///
    /// The api key is passed separately (not stored on `Server`) because it
    /// lives in the Keychain, not in SwiftData.
    init(server: Server, apiKey: String) {
        self.host = server.host
        self.httpsPort = server.httpsPort
        self.certFingerprint = server.certFingerprint
        self.apiKey = apiKey
    }

    // MARK: Public API

    /// Continuously polls `GET /history` at the given interval and yields
    /// results (success or failure) into the returned `AsyncStream`. Each
    /// yielded response carries only samples with `ts > since`, where
    /// `since` advances as new data arrives — so the first tick delivers
    /// the full 5-min window and subsequent ticks deliver ≤ interval worth
    /// of new samples plus fresh `current` scalars.
    ///
    /// The stream finishes when the consuming task cancels, the
    /// continuation is terminated, or the producer task is cancelled
    /// externally. Transient errors (4xx, timeout, etc.) are yielded as
    /// `.failure` and the loop continues polling.
    nonisolated func historyStream(
        interval: Duration,
        procsLimit: Int? = nil
    ) -> AsyncStream<Result<HistoryResponse, Error>> {
        AsyncStream { continuation in
            let producer = Task {
                var lastTs: Int64 = 0
                while !Task.isCancelled {
                    do {
                        let resp = try await self.history(
                            since: lastTs,
                            procsLimit: procsLimit
                        )
                        if Task.isCancelled { break }
                        // Advance the cursor only when the server actually
                        // has data — an empty ring keeps `ts_end == 0` and
                        // we stay at `since=0` until samples appear.
                        if resp.ts_end > lastTs {
                            lastTs = resp.ts_end
                        }
                        continuation.yield(.success(resp))
                    } catch {
                        if Task.isCancelled { break }
                        continuation.yield(.failure(error))
                    }

                    if Task.isCancelled { break }
                    do {
                        try await Task.sleep(for: interval)
                    } catch {
                        break
                    }
                }
                continuation.finish()
            }

            continuation.onTermination = { _ in
                producer.cancel()
            }
        }
    }

    /// One-shot `GET /history[?since=<ts>][&brief=1]`. Pass `since=0`
    /// (or omit) for the full 5-min ring; pass the last-known `ts_end`
    /// for incremental delivery. Pass `brief=true` to drop the bulky
    /// `current` collections (processes, filesystems, gpu meta) — used
    /// by Home-view tiles that only need the latest-tick scalars.
    func history(
        since: Int64 = 0,
        brief: Bool = false,
        procsLimit: Int? = nil
    ) async throws -> HistoryResponse {
        var query: [String] = []
        if since > 0 { query.append("since=\(since)") }
        if brief { query.append("brief=1") }
        if let n = procsLimit { query.append("procs=\(n)") }
        let path = query.isEmpty ? "/history" : "/history?" + query.joined(separator: "&")
        let data = try await get(path: path)
        do {
            return try decoder.decode(HistoryResponse.self, from: data)
        } catch {
            throw MetricsError.decode(error)
        }
    }

    /// `POST /processes/{pid}/kill` with `{"signal":"TERM"|"KILL"}`.
    /// Returns when the server responds with 2xx; throws `MetricsError.http`
    /// on 4xx/5xx.
    func kill(pid: Int32, signal: KillSignal) async throws {
        let body: [String: String] = ["signal": signal.rawValue]
        let bodyData = try JSONSerialization.data(withJSONObject: body, options: [])
        _ = try await send(
            method: "POST",
            path: "/processes/\(pid)/kill",
            body: bodyData,
            contentType: "application/json"
        )
    }

    /// `GET /version` — unauthenticated endpoint used by the recovery flow to
    /// verify the agent is up before switching to authenticated calls.
    func version() async throws -> VersionResponse {
        let data = try await get(path: "/version")
        do {
            return try decoder.decode(VersionResponse.self, from: data)
        } catch {
            throw MetricsError.decode(error)
        }
    }

    /// `GET /health` — returns normally on 200, throws `MetricsError.http`
    /// otherwise. Body is discarded.
    func health() async throws {
        _ = try await send(method: "GET", path: "/health", body: nil, contentType: nil)
    }

    // MARK: - Request plumbing

    private func get(path: String) async throws -> Data {
        return try await send(method: "GET", path: path, body: nil, contentType: nil)
    }

    /// Low-level HTTP call. Builds the URL, injects Bearer auth, uses the
    /// pooled pinned session, and returns the response body on 2xx.
    private func send(
        method: String,
        path: String,
        body: Data?,
        contentType: String?
    ) async throws -> Data {
        guard let url = URL(string: "https://\(host):\(httpsPort)\(path)") else {
            throw MetricsError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        if let contentType {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        request.httpBody = body

        let session = MetricsSessionPool.shared.session(
            host: host,
            port: httpsPort,
            certFingerprint: certFingerprint
        )

        // NB: intentionally `data(for:)` — the ref doc flags `bytes(for:)` as
        // having known issues with custom delegates. We don't need streaming
        // for polls anyway.
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw MetricsError.transport(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw MetricsError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw MetricsError.http(status: http.statusCode, body: body)
        }
        return data
    }
}
