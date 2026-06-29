# Spawn Shim

`CSpawn` is the macOS process-launch bridge for `wallet-node`. Swift `Process`
does not provide reliable arbitrary fd inheritance for the daemon lifecycle
pipes, so the app launches the daemon through `posix_spawn`.

## Integration Path

1. Build the daemon from the sibling `local-wallet-daemon` repo:

   ```sh
   cd ../local-wallet-daemon
   cargo build -p wallet-node
   ```

2. Run the Swift shim test from this repo:

   ```sh
   cd wallet-macos
   swift test --filter SpawnHelperTests
   ```

The test resolves `../local-wallet-daemon/target/debug/wallet-node` relative to
`wallet-macos/Package.swift`. Set `WALLET_NODE_BIN=/absolute/path/to/wallet-node`
to test a non-default binary path.

## Design

The shim uses `posix_spawn_file_actions_adddup2` to map three pipe
ends into the child:

- **fd `3` — ready** (daemon→app): the daemon's ready pipe write end. The
  daemon writes a ready JSON carrying the bearer token and socket path.
- **fd `4` — alive** (app→daemon): the alive pipe read end. EOF on this fd (the
  app closing its write end) triggers daemon shutdown.
- **fd `5` — secret** (app→daemon): the secret pipe read end. The app writes the
  bundler-EOA secret payload here at startup.

The daemon is always launched as:

```text
wallet-node --ready-fd 3 --alive-fd 4 --secret-fd 5
```

Fixed fd numbering keeps the Swift side independent from the parent process's
current descriptor table and matches the daemon's fd lifecycle tests.

## Spawn Protocol Versioning

The daemon writes `daemonSpawnProtocol: <u32>` in its ready JSON (alongside
`apiVersion`). The current value is `1`. Future changes to the fd contract
(numbering, framing, additional pipes) bump this integer. The app spawner
currently reads only `apiVersion` from the ready JSON and does not yet read or
gate on `daemonSpawnProtocol`; refusing to integrate on an unrecognized version
is aspirational, not implemented today.

## Failure Modes

- `FD_CLOEXEC`: fds duplicated with `adddup2` are available in the child at
  fd `3`, fd `4`, and fd `5`, but unrelated parent-only pipe ends must be marked
  close-on-exec or closed through file actions so they do not leak.
- Alive pipe: if the child inherits the alive pipe write end, closing the app's
  write end will not produce EOF and the daemon will stay alive.
- Fd numbering: callers should treat fd `3` as daemon-owned ready write, fd `4`
  as daemon-owned alive read, and fd `5` as daemon-owned secret read after
  spawn. Passing the same fd for more than one role is rejected with `EINVAL`.
- Spawn errors: `wallet_node_spawn_helper` returns the `errno`-style integer
  from `posix_spawn` or file-action setup; the Swift wrapper surfaces this as
  `SpawnError`.

## Daemon-Side Lifecycle

At startup the daemon reads its bundler-EOA secret payload from fd `5` (the
app's write end of the secret pipe).

The spawned daemon owns two complementary lifecycle guarantees on top of the
fd-4 alive pipe: it watches fd `4` for EOF and shuts down when the parent app
closes its end, and it independently exits when `getppid() == 1` (orphan
backstop) — so the daemon dies even if the alive pipe is bypassed or the parent
crashes without cleanly closing it.
