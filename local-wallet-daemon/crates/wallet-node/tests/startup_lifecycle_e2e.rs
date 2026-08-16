#![cfg(target_os = "macos")]

use std::fs::File;
use std::io::{Read, Write};
use std::net::TcpListener;
use std::os::fd::{AsRawFd, OwnedFd};
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, ExitStatus, Stdio};
use std::sync::mpsc;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use nix::unistd::pipe;

#[test]
#[ignore = "requires macOS kqueue and inherited lifecycle fds"]
fn alive_pipe_closure_cancels_blocked_chain_startup() {
    let home = TempHome::new();
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind local blackhole RPC");
    let rpc_addr = listener.local_addr().expect("read blackhole RPC address");
    let (accepted_tx, accepted_rx) = mpsc::channel();
    let (release_tx, release_rx) = mpsc::channel();
    let blackhole = std::thread::spawn(move || {
        let (_stream, _) = listener.accept().expect("accept wallet-node RPC request");
        accepted_tx.send(()).expect("report accepted RPC request");
        let _ = release_rx.recv_timeout(Duration::from_secs(10));
    });

    let config_path = home.path().join("config.toml");
    std::fs::write(
        &config_path,
        format!(
            r#"[network]
chain_id = 11155111
execution_rpc = "http://{rpc_addr}"
consensus_rpc = "http://127.0.0.1:1"
read_verification = "execution_rpc"
"#,
        ),
    )
    .expect("write local startup config");

    let (ready_read, ready_write) = cloexec_pipe("ready");
    let (alive_read, alive_write) = cloexec_pipe("alive");
    let (secret_read, secret_write) = cloexec_pipe("secret");
    let mut process = ProcessGuard::spawn(
        home.path(),
        &config_path,
        &ready_read,
        &ready_write,
        &alive_read,
        &alive_write,
        &secret_read,
        &secret_write,
    );
    drop(ready_write);
    drop(alive_read);
    drop(secret_read);

    let mut secret_writer = File::from(secret_write);
    secret_writer
        .write_all(
            br#"{"keys":[{"keyRef":"bundler-eoa:default:11155111:1","secret":"0x0101010101010101010101010101010101010101010101010101010101010101"}]}"#,
        )
        .expect("write supplied relayer secret");
    drop(secret_writer);

    accepted_rx
        .recv_timeout(Duration::from_secs(5))
        .expect("wallet-node should reach the blocked local RPC startup stage");

    drop(alive_write);
    let status = process
        .wait_for_exit(Duration::from_secs(3))
        .expect("alive-pipe EOF should cancel blocked startup within 3 seconds");
    assert!(status.success(), "wallet-node exited with {status}");

    let mut ready_output = String::new();
    File::from(ready_read)
        .read_to_string(&mut ready_output)
        .expect("read closed ready pipe");
    assert!(
        ready_output.is_empty(),
        "parent-directed shutdown must not be reported as startup failure: {ready_output}"
    );

    let _ = release_tx.send(());
    blackhole.join().expect("join local blackhole RPC");
}

fn cloexec_pipe(name: &str) -> (OwnedFd, OwnedFd) {
    let (read_fd, write_fd) = pipe().unwrap_or_else(|err| panic!("create {name} pipe: {err}"));
    for fd in [&read_fd, &write_fd] {
        // SAFETY: `fd` is live and owned by this test process.
        let result = unsafe { libc::fcntl(fd.as_raw_fd(), libc::F_SETFD, libc::FD_CLOEXEC) };
        assert_ne!(
            result,
            -1,
            "set FD_CLOEXEC on {name} pipe: {}",
            std::io::Error::last_os_error()
        );
    }
    (read_fd, write_fd)
}

#[allow(clippy::too_many_arguments)]
fn configure_child_fds(
    ready_read: i32,
    ready_write: i32,
    alive_read: i32,
    alive_write: i32,
    secret_read: i32,
    secret_write: i32,
) -> std::io::Result<()> {
    for (source, target) in [(ready_write, 3), (alive_read, 4), (secret_read, 5)] {
        if source != target && unsafe { libc::dup2(source, target) } == -1 {
            return Err(std::io::Error::last_os_error());
        }
    }

    for raw in [
        ready_read,
        ready_write,
        alive_read,
        alive_write,
        secret_read,
        secret_write,
    ] {
        if raw != 3 && raw != 4 && raw != 5 {
            unsafe { libc::close(raw) };
        }
    }

    for target in [3, 4, 5] {
        if unsafe { libc::fcntl(target, libc::F_SETFD, 0) } == -1 {
            return Err(std::io::Error::last_os_error());
        }
    }
    Ok(())
}

struct ProcessGuard {
    child: Child,
}

impl ProcessGuard {
    #[allow(clippy::too_many_arguments)]
    fn spawn(
        home: &Path,
        config_path: &Path,
        ready_read: &OwnedFd,
        ready_write: &OwnedFd,
        alive_read: &OwnedFd,
        alive_write: &OwnedFd,
        secret_read: &OwnedFd,
        secret_write: &OwnedFd,
    ) -> Self {
        let inherited = [
            ready_read.as_raw_fd(),
            ready_write.as_raw_fd(),
            alive_read.as_raw_fd(),
            alive_write.as_raw_fd(),
            secret_read.as_raw_fd(),
            secret_write.as_raw_fd(),
        ];
        let mut command = Command::new(env!("CARGO_BIN_EXE_wallet-node"));
        command
            .args(["--ready-fd", "3", "--alive-fd", "4", "--secret-fd", "5"])
            .arg("--config")
            .arg(config_path)
            .env("HOME", home)
            .env_remove("XDG_DATA_HOME")
            .stdout(Stdio::null())
            .stderr(Stdio::inherit());

        // SAFETY: pre_exec invokes only async-signal-safe fd operations.
        unsafe {
            command.pre_exec(move || {
                configure_child_fds(
                    inherited[0],
                    inherited[1],
                    inherited[2],
                    inherited[3],
                    inherited[4],
                    inherited[5],
                )
            });
        }

        Self {
            child: command.spawn().expect("spawn wallet-node"),
        }
    }

    fn wait_for_exit(&mut self, timeout: Duration) -> Option<ExitStatus> {
        let deadline = Instant::now() + timeout;
        loop {
            match self.child.try_wait() {
                Ok(Some(status)) => return Some(status),
                Ok(None) if Instant::now() < deadline => {
                    std::thread::sleep(Duration::from_millis(20));
                }
                Ok(None) => return None,
                Err(err) => panic!("wait for wallet-node: {err}"),
            }
        }
    }
}

impl Drop for ProcessGuard {
    fn drop(&mut self) {
        if !matches!(self.child.try_wait(), Ok(Some(_))) {
            let _ = self.child.kill();
            let _ = self.child.wait();
        }
    }
}

struct TempHome {
    path: PathBuf,
}

impl TempHome {
    fn new() -> Self {
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("clock after epoch")
            .subsec_nanos();
        let path = PathBuf::from(format!("/tmp/wnlc-{}-{nonce}", std::process::id()));
        std::fs::create_dir_all(&path).expect("create temporary HOME");
        let mut permissions = std::fs::metadata(&path)
            .expect("read temporary HOME metadata")
            .permissions();
        use std::os::unix::fs::PermissionsExt;
        permissions.set_mode(0o700);
        std::fs::set_permissions(&path, permissions).expect("secure temporary HOME");
        Self { path }
    }

    fn path(&self) -> &Path {
        &self.path
    }
}

impl Drop for TempHome {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.path);
    }
}
