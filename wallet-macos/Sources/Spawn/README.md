# Spawn Shim

`CSpawn` is the macOS process-launch bridge for `wallet-node`. Swift `Process`
does not provide reliable arbitrary fd inheritance for the daemon lifecycle
pipes, so the app launches the daemon through `posix_spawn`.

## Integration Path

1. Build the daemon:

   ```sh
   cd rust-core
   cargo build -p wallet-node
   ```

2. Run the Swift shim test:

   ```sh
   cd wallet-macos
   swift test --filter SpawnHelperTests
   ```

The test resolves `../rust-core/target/debug/wallet-node` relative to
`wallet-macos/Package.swift`. Set `WALLET_NODE_BIN=/absolute/path/to/wallet-node`
to test another binary.

## Design

The shim uses option B: `posix_spawn_file_actions_adddup2` maps the daemon's
ready pipe write end to child fd `3` and the alive pipe read end to child fd `4`.
The daemon is always launched as:

```text
wallet-node --ready-fd 3 --alive-fd 4
```

Fixed fd numbering keeps the Swift side independent from the parent process's
current descriptor table and matches the daemon's fd lifecycle tests.

## Failure Modes

- `FD_CLOEXEC`: fds duplicated with `adddup2` are available in the child at
  fd `3` and fd `4`, but unrelated parent-only pipe ends must be marked
  close-on-exec or closed through file actions so they do not leak.
- Alive pipe: if the child inherits the alive pipe write end, closing the app's
  write end will not produce EOF and the daemon will stay alive.
- Fd numbering: callers should treat fd `3` as daemon-owned ready write and fd
  `4` as daemon-owned alive read after spawn. Passing the same fd for both roles
  is rejected with `EINVAL`.
- Spawn errors: `wallet_node_spawn_helper` returns the `errno`-style integer
  from `posix_spawn` or file-action setup; the Swift wrapper surfaces this as
  `SpawnError`.
