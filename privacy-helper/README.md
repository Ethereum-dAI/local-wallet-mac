# privacy-helper

A sidecar process that wraps the Kohaku Privacy Pools V1 protocol for the Local Wallet macOS app.
It accepts a secret payload over fd-5, serves a JSON-RPC API over a Unix socket, and signals
readiness over fd-3. It exits cleanly when fd-4 reaches EOF.

## RPC methods

| Method | Params | Returns | Description |
|--------|--------|---------|-------------|
| `balance` | — | `string` (0x hex wei) | Approved ETH balance inside the privacy pool |
| `prepareShield` | `{ amountWei: string }` | `{ to, data, value }` | Build a shield (deposit) transaction |

All requests require `Authorization: Bearer <token>` matching the daemon token from the fd-5 payload.

## fd contract

| fd | Direction | Content |
|----|-----------|---------|
| 3 (READY_FD) | write | `"ready\n"` once the Unix socket is listening |
| 4 (ALIVE_FD) | read | held open; EOF causes `process.exit(0)` |
| 5 (SECRET_FD) | read | JSON payload (see below) |

### fd-5 JSON payload schema

```json
{
  "entropyHex": "0x<64-hex-chars>",
  "sidecarSocketPath": "/path/to/sidecar.sock",
  "daemon": {
    "socketPath": "/path/to/daemon.sock",
    "token": "<bearer-token>",
    "url": "http://127.0.0.1:<port>"
  }
}
```

Either `socketPath` or `url` must be present in the `daemon` object (socketPath takes priority).

## Persistent state

The sidecar stores privacy-pool state in:

```
~/Library/Application Support/LocalWallet/privacy-pools-sepolia.json
```

(mode 0o600, created automatically)

---

## Manual Sepolia gate (standalone test)

This is a manual verification gate for the full end-to-end flow on Sepolia testnet.
Run after building with `bun run build`.

### Prerequisites

- Local Wallet daemon built: `cargo build -p wallet-node --release` (in `../local-wallet-daemon`)
- Sepolia archive RPC available (Alchemy/Infura)
- `curl`, `jq` installed

### Step 1 — Start the dev daemon

```bash
cd ../local-wallet-daemon
cargo run -p wallet-node -- --http 127.0.0.1:0 --print-ready --debug
```

The daemon prints two lines on startup:
```
token=<TOKEN>
httpAddr=http://127.0.0.1:<PORT>
```

Note these values — you will need them below.

### Step 2 — Prepare the fd-5 payload

Pick a throwaway 32-byte entropy value (never reuse for real funds):

```bash
ENTROPY_HEX="0x$(openssl rand -hex 32)"
DAEMON_TOKEN="<TOKEN from Step 1>"
DAEMON_URL="<httpAddr from Step 1>"
SIDECAR_SOCK="/tmp/privacy-helper-test.sock"
```

Write the payload to a temp file:

```bash
cat > /tmp/ph-payload.json <<EOF
{
  "entropyHex": "$ENTROPY_HEX",
  "sidecarSocketPath": "$SIDECAR_SOCK",
  "daemon": {
    "url": "$DAEMON_URL",
    "token": "$DAEMON_TOKEN"
  }
}
EOF
```

### Step 3 — Launch the sidecar

Pass the payload on fd-5, keep fd-4 open (the alive pipe), and wait for `ready` on fd-3:

```bash
# Using bash process substitution to wire up all three fds
{
  ./dist/privacy-helper \
    3>/tmp/ph-ready \
    4<>/tmp/ph-alive \
    5< /tmp/ph-payload.json
} &
PH_PID=$!

# Wait for ready signal
until [ -s /tmp/ph-ready ]; do sleep 0.1; done
echo "sidecar ready: $(cat /tmp/ph-ready)"
```

### Step 4 — Call `balance`

Expected result: `"0x0"` (no funds in pool yet).

```bash
curl --unix-socket "$SIDECAR_SOCK" \
  -H "Authorization: Bearer $DAEMON_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"balance"}' \
  http://x/
```

Expected response:
```json
{"jsonrpc":"2.0","id":1,"result":"0x0"}
```

### Step 5 — Call `prepareShield`

Shield 0.01 ETH (10000000000000000 wei).

```bash
curl --unix-socket "$SIDECAR_SOCK" \
  -H "Authorization: Bearer $DAEMON_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":2,"method":"prepareShield","params":{"amountWei":"10000000000000000"}}' \
  http://x/
```

Expected response shape:
```json
{"jsonrpc":"2.0","id":2,"result":{"to":"0x...","data":"0x...","value":"10000000000000000"}}
```

### Step 6 — Kill the daemon, confirm `balance` errors

```bash
# Kill the daemon process
kill <daemon-pid>

# Now balance should return a JSON-RPC error
curl --unix-socket "$SIDECAR_SOCK" \
  -H "Authorization: Bearer $DAEMON_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":3,"method":"balance"}' \
  http://x/
```

Expected: response contains `"error"` field (connection refused or similar).

### Step 7 — Teardown

```bash
# Close the alive pipe to trigger clean exit
exec 4>&-
wait $PH_PID
echo "sidecar exited with: $?"
rm -f /tmp/ph-ready /tmp/ph-alive /tmp/ph-payload.json "$SIDECAR_SOCK"
```

---

## Development

```bash
bun install          # install deps
bun test             # run 13 unit tests (no network)
bun run build        # compile to dist/privacy-helper (Mach-O arm64)
```

`dist/` is gitignored — the binary is not committed.
