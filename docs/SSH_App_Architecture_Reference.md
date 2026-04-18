# SSH-Based Remote Service App — Architecture Reference

> Extracted from the **CloseAI** codebase (iOS app that provisions and connects to an AI backend on a user's VPS via SSH). This document captures every architectural decision, nuance, and gotcha so a new project can reuse the pattern without re-discovering them.

---

## Table of Contents

1. [High-Level Architecture](#1-high-level-architecture)
2. [Tech Stack & Dependencies](#2-tech-stack--dependencies)
3. [Data Models & Persistence](#3-data-models--persistence)
4. [SSH Layer](#4-ssh-layer)
5. [Installer & Shell Script Deployment](#5-installer--shell-script-deployment)
6. [Remote API Server (Python Backend)](#6-remote-api-server-python-backend)
7. [HTTPS / TLS Connection to Remote API](#7-https--tls-connection-to-remote-api)
8. [Credential Management](#8-credential-management)
9. [Connection Recovery & Reconnection](#9-connection-recovery--reconnection)
10. [Upgrade Flow](#10-upgrade-flow)
11. [UI Architecture & Navigation](#11-ui-architecture--navigation)
12. [Nuances, Gotchas & Lessons Learned](#12-nuances-gotchas--lessons-learned)

---

## 1. High-Level Architecture

```
┌─────────────┐    SSH (port 22)    ┌─────────────────────────┐
│  iOS App     │ ─────────────────► │  Linux VPS (Ubuntu)     │
│  (SwiftUI)   │                    │                         │
│              │   HTTPS (port 443) │  ┌─ closeai (systemd) ──┤
│  ChatService │ ◄─────────────────►│  │  FastAPI + Uvicorn   │
│  (URLSession)│   self-signed TLS  │  │  (cert-pinned)       │
│              │                    │  └─► Ollama (port 11434) │
└─────────────┘                    └─────────────────────────┘
```

**The flow is:**
1. User enters VPS credentials (host, port, username, password or SSH key).
2. App connects via SSH, uploads scripts (`.sh` + `.py`), runs preflight checks.
3. App launches a detached install process on the server (Ollama, Python venv, TLS certs, systemd service).
4. App polls the install log file over SSH for JSON progress lines.
5. On success, the app gets back `api_key`, `cert_fingerprint`, and `https_port`.
6. App disconnects SSH and connects directly to the HTTPS API using certificate pinning.
7. Subsequent app launches reconnect via HTTPS using stored credentials. SSH is only re-opened for admin tasks (upgrade, model management, credential recovery).

---

## 2. Tech Stack & Dependencies

### iOS Side
| Component | Library / Framework |
|---|---|
| SSH | **Citadel** (`github.com/orlandos-nl/Citadel`) — pure Swift SSH client built on SwiftNIO/NIOSSH. Supports password, Ed25519, and RSA auth. |
| Persistence | **SwiftData** (iOS 17+) — `@Model` classes, SQLite-backed, `ModelContainer` in app entry point |
| Secrets | **iOS Keychain** via `Security.framework` + optional **LocalAuthentication** (Face ID) |
| Networking | **URLSession** with custom `URLSessionDelegate` for certificate pinning |
| Markdown rendering | **MarkdownUI** (`swift-markdown-ui`) for chat bubbles |
| Crypto | **CryptoKit** (SHA-256 for fingerprints, Ed25519 key generation) |

### Server Side
| Component | Details |
|---|---|
| API framework | **FastAPI** + **Uvicorn** (with `--ssl-certfile`/`--ssl-keyfile` for HTTPS) |
| HTTP client | **httpx** (async, for proxying to Ollama) |
| AI runtime | **Ollama** (installed via `ollama.com/install.sh`, runs as systemd service on port 11434) |
| Process manager | **systemd** (two units: `ollama.service` and `closeai.service`) |
| Firewall | **UFW** (opens SSH + 443/tcp) |
| TLS | Self-signed EC (prime256v1) certificate, 10-year expiry, with IP SAN |

---

## 3. Data Models & Persistence

### SwiftData Schema

**`Server`** (`@Model`) — the primary entity:
```swift
@Model
final class Server {
    var id: UUID
    var serverIdentity: String       // /etc/machine-id — stable across reinstalls
    var name: String                 // display name (usually == host)
    var host: String
    var sshPort: Int
    var sshUsername: String
    var httpsPort: Int               // always 443
    var certFingerprint: String      // SHA-256 of DER-encoded leaf cert (hex, 64 chars)
    var sshHostKeyFingerprint: String // SSH host key fingerprint for pinning
    var activeModel: String?         // e.g. "llama3.2:3b"
    var isInstalled: Bool
    var createdAt: Date
    var updatedAt: Date
    // V2 additions:
    var authMethodRaw: String = "password"   // "password" or "key"
    var keyType: String?
    var publicKeyFingerprint: String?
    var keyComment: String?
    var sudoPasswordSaved: Bool = false
    var keychainKeyAccount: String?  // nil = legacy per-server, or "app-shared-ssh-key"
}
```

**`ChatSession`** (`@Model`) — conversation container, linked to Server:
```swift
var id: UUID
var serverIdentity: String   // denormalized for cross-device portability
var title: String
var server: Server?          // @Relationship
var messages: [ChatMessage]? // @Relationship(deleteRule: .cascade)
```

**`ChatMessage`** (`@Model`):
```swift
var id: UUID
var role: String        // "user" or "assistant"
var content: String
var createdAt: Date
var isStreaming: Bool
var session: ChatSession?
```

### Schema Migration Strategy
All new fields use **optional-with-default** values (e.g., `var authMethodRaw: String = "password"`), so no explicit `VersionedSchema` or migration plan is needed. SwiftData handles the lightweight migration automatically.

### ModelContainer Setup
```swift
// In the @main App struct:
let schema = Schema([Server.self, ChatSession.self, ChatMessage.self])
let config = ModelConfiguration("CloseAI", schema: schema, isStoredInMemoryOnly: false)
// If container creation fails (schema change), delete the store files and retry:
// .store, .store-wal, .store-shm in Application Support
```

**Nuance:** The `resetStoreFiles()` fallback deletes the entire database if migration fails. This is acceptable for this app because server configs can be re-entered and chat history is non-critical.

---

## 4. SSH Layer

### Library: Citadel

`SSHService` is an **actor** wrapping `SSHClient` from Citadel:

```swift
actor SSHService {
    private var client: SSHClient?

    // Password auth
    func connect(host:port:username:password:expectedFingerprint:) async throws -> HostKeyInfo

    // Ed25519 key auth
    func connectWithEd25519Key(host:port:username:privateKey:expectedFingerprint:) async throws -> HostKeyInfo

    // RSA key auth
    func connectWithRSAKey(host:port:username:privateKey:expectedFingerprint:) async throws -> HostKeyInfo

    // Execute a command, return full stdout
    func execute(_ command: String) async throws -> String

    // Upload file content via base64-over-SSH (avoids SFTP entirely)
    func uploadFile(content: String, remotePath: String) async throws

    func disconnect() async
}
```

### Host Key Verification

On first connection, the app captures the server's host key fingerprint (SHA-256 of the serialized `NIOSSHPublicKey`) via a custom `NIOSSHClientServerAuthenticationDelegate`:

```swift
private final class HostKeyCaptureValidator: NIOSSHClientServerAuthenticationDelegate {
    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        // Compute SHA-256 fingerprint, store it
        // On first connect: always succeed (user verifies in UI)
        // On subsequent connects: compare against stored fingerprint
    }
}
```

The fingerprint is stored in `Server.sshHostKeyFingerprint` and pinned on all future connections. A "legacy fingerprint" detection (`isLegacyFingerprint`) handles pre-V2 records that used a hash of `host:port` instead of the actual host key.

### File Upload Without SFTP

**Critical nuance:** Citadel's SFTP has compatibility issues across versions. The app avoids SFTP entirely and uploads files by base64-encoding the content and decoding on the server via a heredoc:

```swift
func uploadFile(content: String, remotePath: String) async throws {
    let base64 = content.data(using: .utf8)!.base64EncodedString()
    let command = """
    base64 -d > \(remotePath) << 'B64EOF'
    \(base64)
    B64EOF
    """
    _ = try await client.executeCommand(command)
}
```

After upload, the app verifies file size with `wc -c` to catch silent upload failures.

### SSH Key Generation & Storage

**`SSHKeyService`** handles key operations:
- `generateEd25519(comment:)` — generates a new Ed25519 keypair using `Curve25519.Signing.PrivateKey()`, exports to OpenSSH PEM format via Citadel's `.makeSSHRepresentation(comment:)`.
- `loadOrGenerateAppKey(comment:)` — **singleton pattern**: loads the app-wide key from Keychain (account: `"app-shared-ssh-key"`), or generates + saves one. All key-setup servers share this one keypair.
- `parsePrivateKey(pem:passphrase:)` — parses OpenSSH-format private keys. Supports Ed25519 and RSA. Detects encrypted keys and wrong passphrases.
- `makeOpenSSHPublicLine(ed25519PublicKeyRaw:comment:)` — constructs the `ssh-ed25519 AAAA... comment` format manually (wire format: length-prefixed type string + length-prefixed raw public key bytes, base64-encoded).
- `makeFingerprint(fromOpenSSHPublicLine:)` — SHA-256 of the public key blob, base64-encoded, prefixed with `SHA256:` (matches `ssh-keygen -lf` output).

### Sudo Password Handling

The app needs root privileges on the server but connects as a non-root user. Sudo password is piped via stdin, base64-encoded for shell safety:

```swift
private func sudoCommand(_ cmd: String) -> String {
    if sshUserIsRoot { return "bash -c '\(cmd)' 2>/dev/null" }
    let b64 = Data(sudoPassword.utf8).base64EncodedString()
    return "echo \(b64) | base64 -d | sudo -S bash -c '\(cmd)' 2>/dev/null"
}
```

**Root detection:** After every SSH connect, `detectPrivilegeMode()` runs `id -u` and caches whether uid == 0. All sudo-prefixing logic checks this flag first.

**Sudo validation:** Before starting install, `validateSudoPassword()` runs `sudo -k -S -p '' true` and parses the exit code via an `__EXIT:$?` sentinel appended to the command output.

---

## 5. Installer & Shell Script Deployment

### What Gets Uploaded

Two files are bundled in the app's Resources and uploaded via SSH:
1. **`closeai_install.sh`** → `/tmp/closeai_install.sh` — main installer script with subcommands
2. **`main.py`** → `/tmp/closeai_main.py` — the Python FastAPI backend

### Install Script Subcommands

The shell script (`closeai_install.sh`) supports these subcommands:

| Subcommand | Purpose |
|---|---|
| `preflight` | Check OS, architecture, RAM, disk, sudo, internet, GPU. Returns JSON. |
| `install <model>` | Full installation (cleanup → Ollama → Python → firewall → dirs → venv → API key → TLS cert → backend → systemd → model pull → health check). Outputs JSON progress lines. |
| `upgrade` | Re-download Ollama, update pip packages, restart services, pull latest model. |
| `status` | Check if installed, return version + service states. |
| `uninstall` | Stop services, remove all files, clean firewall. |
| `pull_model <name>` | Pull a specific Ollama model. |
| `list_models` | List installed models as JSON array. |
| `delete_model <name>` | Remove a specific model. |

### Install Process Lifecycle (Detached Execution)

**Critical design:** The install script runs detached from the SSH session so it survives connection drops (phone locks, network changes):

```
1. App uploads closeai_install.sh + main.py to /tmp/
2. App creates a launcher script (/tmp/closeai_launcher.sh):
     #!/bin/bash
     echo $$ > /tmp/closeai_install.pid
     exec bash /tmp/closeai_install.sh install 'llama3.2:3b' > /tmp/closeai_install.log 2>&1
3. App starts the launcher fully detached:
     nohup setsid bash /tmp/closeai_launcher.sh > /dev/null 2>&1 < /dev/null &
4. App reads the PID from /tmp/closeai_install.pid
5. App polls /tmp/closeai_install.log every 2 seconds for new JSON lines
6. App checks if process is still running: [ -d /proc/<PID> ] && echo RUNNING || echo EXITED
```

**Why `/proc/PID` instead of `kill -0`:** The install runs as root (via sudo) but the SSH user is non-root. `kill -0` returns EPERM (exit 1) for root-owned processes, indistinguishable from "not running".

### JSON Progress Protocol

The install script emits structured JSON, one object per line:

```json
{"step":"ollama","status":"started","message":"Installing Ollama..."}
{"step":"ollama","status":"completed","message":"Ollama installed"}
{"step":"model","status":"started","message":"Pulling llama3.2:3b..."}
...
{"result":"success","api_key":"abc123...","cert_fingerprint":"def456...","https_port":443,"version":"1.0.0"}
```

Or on error:
```json
{"error":"Failed to install Python packages."}
```

The app parses each line as JSON. Non-JSON lines (MOTD, stderr leaks) are silently skipped. During the model pull phase, the app also parses raw Ollama CLI output lines (e.g., `pulling sha256:abc... 42% ...  1.2 GB/2.0 GB`) to extract byte-level progress.

### SSH Reconnection During Install

If the SSH connection drops during install (phone locked, network switch), the server-side process continues running. The app:
1. Detects the SSH read failure
2. Attempts to reconnect using stored auth credentials (`SSHAuthBundle` enum: `.password(String)` or `.key(ParsedKey)`)
3. Resumes tailing the log file from where it left off (`lastLineCount`)
4. After 5 consecutive reconnect failures, gives up

### Install Steps in Detail

1. **Cleanup** — full teardown of any previous install (systemd stop/disable, rm -rf /opt/closeai, kill lingering ollama processes). Always runs, even on "first" install.
2. **Ollama** — downloads and runs `ollama.com/install.sh`. Creates systemd override to run as the SSH login user (not the `ollama` system user) to avoid home-dir permission issues. Waits up to 60s for Ollama API to become ready.
3. **Python** — `apt-get install python3 python3-venv`. Handles apt lock contention (`wait_for_apt` stops unattended-upgrades timers, polls lock files, runs `dpkg --configure -a`).
4. **Firewall** — `ufw allow OpenSSH`, `ufw allow 443/tcp`, `ufw enable`.
5. **Directories** — `/opt/closeai/{certs,backend,data}`.
6. **Python venv** — creates venv, installs `fastapi`, `uvicorn[standard]`, `httpx`.
7. **API key** — `openssl rand -hex 32`, saved to `/opt/closeai/.api_key` (chmod 600).
8. **TLS certificate** — self-signed EC cert with the server's public IP in the SAN:
   ```bash
   server_ip=$(curl -4 -s https://api.ipify.org || curl -4 -s https://ifconfig.me || hostname -I | awk '{print $1}')
   openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
       -keyout key.pem -out cert.pem -days 3650 -subj "/CN=closeai" \
       -addext "subjectAltName=IP:${server_ip},IP:127.0.0.1"
   ```
   **Nuance:** iOS 14+ requires the connecting IP in subjectAltName. A CN-only cert causes `SecTrustEvaluateWithError` to fail even when fingerprint-pinned.
9. **Credential cache** — writes `~/.closeai/api_key` and `~/.closeai/cert_fp` (user-readable) so key-auth users can refresh credentials without sudo.
10. **Backend** — copies `main.py` from `/tmp/closeai_main.py` to `/opt/closeai/backend/main.py`.
11. **Systemd service** — creates `/etc/systemd/system/closeai.service`:
    ```ini
    [Service]
    Type=simple
    WorkingDirectory=/opt/closeai/backend
    ExecStart=/opt/closeai/venv/bin/uvicorn main:app --host 0.0.0.0 --port 443 \
        --ssl-certfile /opt/closeai/certs/cert.pem --ssl-keyfile /opt/closeai/certs/key.pem
    Environment=OLLAMA_HOST=http://localhost:11434
    Environment=API_KEY_FILE=/opt/closeai/.api_key
    Restart=always
    RestartSec=3
    ```
12. **Model pull** — `ollama pull <model>`. Waits for Ollama to be ready first.
13. **Health check** — polls `curl --insecure https://localhost/health` for up to 30 seconds.

### Post-Install Verification (App Side)

After the install script reports success, the app performs additional verification:

1. **`restartAndWaitForService()`** — restarts the closeai systemd service, reloads UFW, polls localhost health via SSH for up to 45 seconds.
2. **`waitForExternalReachability(host:httpsPort:apiKey:certFingerprint:)`** — creates a `ChatService` and tries to reach the server's `/health`, `/status`, `/version`, and `/models` endpoints from the iOS device directly (not via SSH). Up to 20 attempts with 3-second intervals. This confirms the server is reachable from the public internet, not just localhost.
3. **`readConnectionDetailsFromServer()`** — re-reads the API key and cert fingerprint directly from the server files (via SSH+sudo) as the source of truth, rather than trusting values from the install log stream.

---

## 6. Remote API Server (Python Backend)

### Endpoints

| Method | Path | Auth | Purpose |
|---|---|---|---|
| GET | `/health` | None | Returns `{"status": "ok"}` |
| GET | `/version` | None | Returns `{"version": "1.0.0", "api": "v1"}` |
| GET | `/status` | Bearer | Server status: model info, disk usage, Ollama health, feature flags |
| GET | `/models` | Bearer | List installed Ollama models |
| POST | `/models/pull` | Bearer | Pull a model (SSE streaming progress) |
| POST | `/chat` | Bearer | Chat completion (SSE streaming) |

### Auth

Simple Bearer token authentication. The API key is loaded from `/opt/closeai/.api_key` on first request and cached in a module-level variable:

```python
def verify_auth(request: Request) -> None:
    auth = request.headers.get("Authorization", "")
    if not auth.startswith("Bearer "):
        raise HTTPException(status_code=401)
    if auth[7:] != get_api_key():
        raise HTTPException(status_code=401)
```

### Streaming Protocol

Both `/chat` and `/models/pull` use **Server-Sent Events (SSE)**:

```
data: {"content": "Hello", "done": false}\n\n
data: {"content": " world", "done": false}\n\n
data: {"content": "", "done": true}\n\n
data: [DONE]\n\n
```

The backend proxies to Ollama's streaming API using `httpx.AsyncClient.stream()`, reformats each JSON chunk, and emits SSE `data:` lines. The final sentinel is `data: [DONE]`.

### Ollama Proxying

The backend acts as a thin proxy between the iOS app and Ollama:
- `/chat` → `POST {OLLAMA_HOST}/api/chat` (streaming)
- `/models` → `GET {OLLAMA_HOST}/api/tags`
- `/models/pull` → `POST {OLLAMA_HOST}/api/pull` (streaming)

The OLLAMA_HOST is passed via environment variable (`http://localhost:11434`).

---

## 7. HTTPS / TLS Connection to Remote API

### Certificate Pinning

The app uses a custom `URLSessionDelegate` that computes the SHA-256 fingerprint of the leaf certificate's DER encoding and compares it to the stored fingerprint:

```swift
final class CertPinningDelegate: NSObject, URLSessionDelegate {
    func urlSession(_:didReceive:completionHandler:) {
        // Extract leaf cert from SecTrust
        // Compute SHA-256 of SecCertificateCopyData(leafCert)
        // Compare hex string to expectedFingerprint
        // IMPORTANT: Must call SecTrustEvaluateWithError before returning .useCredential
        // Use BasicX509 policy (not SSL policy) because our cert has no hostname SAN
    }
}
```

**Critical nuances:**

1. **`SecTrustEvaluateWithError` must be called.** On iOS 15+, URLSession requires this to have been called on the serverTrust object. Without it, the session silently cancels the request (NSURLErrorCancelled / -999).

2. **BasicX509 policy, not SSL.** The self-signed cert only has `CN=closeai` and an IP SAN. The default SSL policy checks hostname/SAN against the URL's host, which would fail for some configurations. We use `SecPolicyCreateBasicX509()` instead and rely on fingerprint comparison for identity verification.

3. **Anchor certificate.** We set the leaf cert as the only trust anchor with `SecTrustSetAnchorCertificates` + `SecTrustSetAnchorCertificatesOnly(true)` so the self-signed cert is trusted.

### URLSession Connection Pooling (`ChatSessionPool`)

**Problem discovered:** Multiple SwiftUI views create separate `ChatService` instances for the same server. Each creates its own `URLSession` with a custom delegate, which opens its own TCP/TLS connection pool. This caused a 15-30 second cold-start hang on the first request after install.

**Solution:** `ChatSessionPool` (singleton, `@unchecked Sendable`) — a process-wide pool keyed by `"host:port:certFP.prefix(16)"`. All `ChatService` instances for the same server share one warm `URLSession`:

```swift
nonisolated private final class ChatSessionPool: @unchecked Sendable {
    static let shared = ChatSessionPool()
    private let lock = NSLock()
    private var sessions: [String: URLSession] = [:]

    func session(host: String, port: Int, certFingerprint: String) -> URLSession {
        let key = "\(host):\(port):\(certFingerprint.prefix(16))"
        // Return existing or create new with CertPinningDelegate
    }
}
```

**Nuance:** Pooled sessions use a 15s request timeout and 30s resource timeout. Streaming sessions (chat, model pull) do NOT use the pool — they create ephemeral `URLSession` instances with their own delegate that combines cert pinning + incremental data delivery.

### Streaming with URLSessionDataDelegate

**Why not `URLSession.bytes(for:)`:** Known compatibility issues with custom delegates and some TLS configurations.

Instead, the app uses `URLSessionDataDelegate.didReceive(data:)` which fires as bytes arrive from the network:

```swift
private final class StreamingSessionDelegate: NSObject, URLSessionDelegate, URLSessionDataDelegate {
    private var lineBuffer = ""

    func urlSession(_:dataTask:didReceive data:) {
        lineBuffer += String(data: data, encoding: .utf8) ?? ""
        // Process every complete "\n"-delimited line
        // Parse "data: {...}" SSE lines
        // Decode ChatChunk JSON, yield content tokens via AsyncThrowingStream continuation
    }
}
```

Each streaming request gets its own `URLSession` instance (the delegate holds a strong reference to keep it alive). The `continuation.onTermination` handler calls `delegate.cancel()` which calls `session.invalidateAndCancel()` to abort the HTTP request immediately — this closes the connection and causes the server to stop generating tokens.

---

## 8. Credential Management

### What Goes Where

| Secret | Storage | Protection |
|---|---|---|
| SSH password | iOS Keychain (`sshPassword` + server UUID account) | `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` |
| SSH private key (PEM) | iOS Keychain (`sshPrivateKey` + `"app-shared-ssh-key"` or per-server UUID) | No biometry (intentional — removed Face ID friction) |
| Sudo password | iOS Keychain (`sudoPassword` + server UUID account) | **With biometry** (`biometryCurrentSet` access control) |
| API key | iOS Keychain (`apiKey` + server UUID account) | Standard |
| Saved connection password | iOS Keychain (`savedConnectionPassword` + `"host:port:username"` account) | Standard |
| Cert fingerprint | SwiftData (`Server.certFingerprint`) | N/A (not a secret — public info) |
| API key (server-side) | `/opt/closeai/.api_key` (chmod 600, root-only) | File permissions |
| API key (user cache) | `~/.closeai/api_key` (chmod 600, user-readable) | File permissions |
| Cert FP (user cache) | `~/.closeai/cert_fp` (chmod 600, user-readable) | File permissions |

### KeychainService API

```swift
struct KeychainService {
    static let sshAppKeyAccount = "app-shared-ssh-key"

    // Standard save (no biometry)
    static func save(key: KeychainKey, value: String, account: String) throws

    // Save with optional biometry requirement
    static func save(key: KeychainKey, value: String, account: String, requiresBiometry: Bool) throws

    // Standard load (no biometry prompt)
    static func load(key: KeychainKey, account: String) -> String?

    // Load with Face ID / Touch ID prompt — returns Result to distinguish cancel/fail/notFound
    static func loadWithBiometry(key: KeychainKey, account: String, reason: String) -> Result<String, KeychainError>

    static func delete(key: KeychainKey, account: String) throws
}
```

The service identifier is `"com.DaraConsultingInc.CloseAI"` — each item is stored with service `"\(service).\(key.rawValue)"` and the account string.

**Biometry nuance:** SSH private keys are saved with `requiresBiometry: false` to avoid Face ID friction on every SSH connect. Sudo passwords are saved with `requiresBiometry: true` (only prompted when needed for credential refresh or upgrades).

### App-Wide Shared SSH Key

All servers set up via key-setup share a single Ed25519 keypair stored under account `"app-shared-ssh-key"`. The key is generated once and reused. `Server.keychainKeyAccount` records which Keychain account to use (`nil` for legacy per-server storage). When loading, the app tries `keychainKeyAccount` first, then falls back to `server.id.uuidString`.

---

## 9. Connection Recovery & Reconnection

### `ConnectionRecoveryService`

When the app launches with an already-installed server, it needs to establish a fresh HTTPS connection. The recovery flow:

1. **Password-auth servers:** Load SSH password from Keychain → SSH connect → optionally restart backend services → read API key + cert fingerprint from server files → disconnect SSH → return `ConnectionDetails`.

2. **Key-auth servers:**
   - Load PEM from Keychain (try app-wide account, fallback to per-server)
   - SSH connect with key
   - **Try user-readable cache first** (`~/.closeai/api_key` + `~/.closeai/cert_fp`) — no sudo needed
   - If cache miss: load sudo password (with biometry) → read from `/opt/closeai/.api_key` + compute cert fingerprint via openssl
   - If no saved sudo password: throw `sudoPasswordRequired`

### `SSHConnectionHelper`

Shared utility used by `UpgradeService`, `ModelManagerService`, etc.:

```swift
struct SSHConnectionHelper {
    static func connect(to server: Server) async throws -> SSHService
    // Handles password vs key auth, host key pinning, Keychain lookup
}
```

### `verifyConnection()` 

After recovering credentials, verifies HTTPS connectivity with up to 10 attempts:
```swift
func verifyConnection(host:port:apiKey:certFingerprint:attempts:delayNanoseconds:) async throws -> ChatService
// Calls /version then /status on each attempt
```

---

## 10. Upgrade Flow

### `UpgradeService`

Checks `AppVersion.bundledScriptVersion` against the server's `/version` endpoint response. If server version is older (semver numeric compare), shows an upgrade banner.

Upgrade flow:
1. SSH connect (via `SSHConnectionHelper`)
2. Detect if root via `id -u`
3. Upload latest `closeai_install.sh`
4. Execute `bash /tmp/closeai_install.sh upgrade` (with sudo if needed)
5. Parse JSON-line output, yield human-readable messages
6. Check for `"status":"completed"` in output

**Nuance:** Upgrade uses synchronous SSH execute (blocks until complete), unlike install which uses detached execution + log polling. This is fine because upgrades are faster and the user is watching a progress sheet.

---

## 11. UI Architecture & Navigation

### View Hierarchy

```
CloseAIApp (@main)
  └─ RootView
       ├─ ServerSetupView (no installed servers)
       │    └─ NavigationStack with Destination enum:
       │         ├─ .fingerprint → HostFingerprintView
       │         ├─ .keySetup → KeySetupView
       │         ├─ .importVerify → ImportVerifyView
       │         ├─ .installWithSudoPrompt → InstallSudoPromptView
       │         ├─ .preflight → PreflightView
       │         ├─ .install → InstallProgressView
       │         └─ .bootstrap → BootstrapProgressView
       ├─ ServerListView (multiple installed servers)
       └─ MainTabView (single or selected installed server)
            ├─ ChatContainerView → ChatView
            └─ ServerStatusView
```

### Navigation Pattern

Uses a typed `NavigationPath` with a `Destination` enum:
```swift
@State private var path = NavigationPath()
private enum Destination: Hashable {
    case fingerprint, preflight, install, bootstrap, importVerify, keySetup, installWithSudoPrompt
}
```

### EphemeralSetupState

**Problem discovered:** Passing 7+ `@State` value-type props through `navigationDestination` closures caused a SwiftUI state-commit race — the destination closure captured stale values because `@State` commits are asynchronous.

**Solution:** `@Observable final class EphemeralSetupState` — a reference-type container that's synchronously visible to all navigation closures:

```swift
@Observable
final class EphemeralSetupState {
    var importedKey: ParsedKey?
    var importedPem: String = ""
    var importedComment: String = ""
    var pendingHostFingerprint: String = ""
    var pendingGeneratedKey: GeneratedKey?
    var server: Server?
    var hostKeyInfo: SSHService.HostKeyInfo?
}
```

Stored as `@State private var ephemeral = EphemeralSetupState()` on `ServerSetupView`. The class reference survives view re-creation, and mutations are immediately visible.

### View-to-View Communication via Notifications

```swift
extension Notification.Name {
    static let serverSetupComplete      // object: Server — triggers RootView to show MainTabView
    static let serverDisconnected       // triggers return to setup
    static let modelInstalled           // refreshes model list
    static let serverInstallCompleteReconnect  // triggers fresh reconnect via setup form
    static let certFingerprintChanged   // TLS delegate discovered a new fingerprint
}
```

### Auth Method Picker

Two options in the setup form:
- **`.password`** — user enters SSH password, used for both SSH auth and sudo
- **`.keySetup`** — app generates Ed25519 key, user copies public key to server, then app tests the connection

### Setup Flow Branches

**Password flow:**
```
Form → Connect (SSH) → HostFingerprintView → PreflightView → InstallProgressView → BootstrapProgressView → MainTabView
```

**Key-setup flow:**
```
Form → KeySetupView (generate key, user adds pubkey to server) → ImportVerifyView (test connection)
  → InstallSudoPromptView (get sudo password) → PreflightView → InstallProgressView → BootstrapProgressView → MainTabView
```

**Reconnect flow (existing install detected):**
```
Form → Connect → checkExistingInstall() → save credentials → post notification → MainTabView
```

---

## 12. Nuances, Gotchas & Lessons Learned

### SSH / Server-Side

1. **apt lock contention on fresh Ubuntu VPS:** `unattended-upgrades` runs automatically after first boot and holds the apt lock for minutes. The installer explicitly stops all apt timers/services and polls lock files with a 5-minute timeout. Also runs `dpkg --configure -a` to fix interrupted dpkg state.

2. **Ollama user override:** The Ollama installer creates a system user `ollama` whose home directory may be missing or unwritable on some VPS configs. The install script overrides the systemd unit to run as the actual SSH login user.

3. **Ollama port conflict:** After `systemctl stop ollama`, orphaned `ollama serve` processes can hold port 11434 in TIME_WAIT. The script does `pkill -x ollama` + `sleep 2` + `systemctl reset-failed ollama` before restarting.

4. **Base64 for sudo password transport:** Passwords are base64-encoded before being piped to `sudo -S` to avoid shell escaping issues with special characters.

5. **stderr suppression:** All sudo commands append `2>/dev/null` to suppress the `[sudo] password for user:` prompt from contaminating the command output. The `fail()` helper in the shell script emits JSON to stdout so the app always gets structured output.

6. **User-readable credential cache:** Key-auth users can't sudo to read `/opt/closeai/.api_key`. The install script writes a copy to `~/.closeai/api_key` (user-owned). The recovery service tries this cache first, falling back to sudo only if needed.

### iOS / Networking

7. **TLS SAN requirement:** iOS 14+ requires the server's IP in the certificate's subjectAltName extension. The install script auto-detects the public IP via `api.ipify.org` / `ifconfig.me` / `hostname -I` and embeds it.

8. **SecTrustEvaluateWithError required:** On iOS 15+, even with a custom delegate that returns `.useCredential`, you must call `SecTrustEvaluateWithError` first. Without it, URLSession silently cancels (-999).

9. **URLSession.bytes incompatibility:** `URLSession.bytes(for:)` has known issues with custom delegates and some TLS configurations. Use `URLSessionDataDelegate.didReceive(data:)` for reliable streaming.

10. **Connection pool cold-start stall:** Each URLSession with a custom delegate has its own TCP/TLS connection pool. Multiple views creating separate ChatService instances caused 15-30s hangs. Solved with `ChatSessionPool` (process-wide singleton).

11. **SwiftUI @State race condition:** `@State` value-type mutations are committed asynchronously. When a `navigationDestination` closure reads them, it may see stale values. Solved with `@Observable class EphemeralSetupState` (reference-type, synchronous mutations).

12. **InstallerService disconnect before MainTabView:** `InstallerService.disconnect()` must run before navigating to MainTabView. Otherwise the SSH connection lingers and contends with the HTTPS connection.

### Debug Logging

13. **Global debug switch:** `dbg(_:)` in `DebugLog.swift` — a `nonisolated` function gated by `closeAIDebugEnabled`. Flip to `false` before release. Uses `@autoclosure` so string interpolation is skipped when disabled.

### Versioning

14. **Script version sync:** `AppVersion.bundledScriptVersion` in Swift must match `PRIVATEAI_VERSION` in `closeai_install.sh`. Bumped in the same commit. The app compares this against the server's `/version` response for upgrade detection.

15. **Server identity stability:** `Server.serverIdentity` is set from `/etc/machine-id` (or `/var/lib/dbus/machine-id`), not from the IP address. This allows the app to recognize the same server even if its IP changes.

### SavedConnectionStore

16. **Recent connections:** SSH connection details (host, port, username) are saved in UserDefaults (JSON-encoded `[SavedConnection]`, max 10, sorted by `lastUsed`). Passwords for saved connections are stored separately in Keychain under account `"host:port:username"`. This lets users quickly re-fill the setup form.
