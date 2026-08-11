#![allow(dead_code)]

use std::fs::File;
use std::io::{self, Write};
use std::os::unix::io::{FromRawFd, RawFd};
use std::path::PathBuf;

#[derive(serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ReadyEvent {
    pub token: String,
    pub api_version: u32,
    pub daemon_spawn_protocol: u32,
    pub socket_path: Option<PathBuf>,
    pub http_addr: Option<String>,
}

/// Sent on the ready fd when startup fails before a `ReadyEvent` exists.
///
/// Without it the parent only observes the pipe closing, and every downstream
/// error it reports is "ready pipe closed before ready event" — true, and
/// useless. The daemon already knows exactly why it is exiting; this hands that
/// reason across the same channel. The parent distinguishes the two shapes by
/// the presence of `error`.
#[derive(serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct StartupFailure<'a> {
    pub error: &'a str,
}

/// Write a `StartupFailure` as compact JSON + newline to the given raw fd.
///
/// Shares `write_to_fd`'s ownership contract: the fd is consumed, so this and
/// `write_to_fd` are mutually exclusive on a given launch.
pub fn write_failure_to_fd(reason: &str, ready_fd: RawFd) -> io::Result<()> {
    let mut file = unsafe { <File as FromRawFd>::from_raw_fd(ready_fd) };
    serde_json::to_writer(&mut file, &StartupFailure { error: reason })?;
    file.write_all(b"\n")?;
    file.flush()
}

pub fn write_to_stdout(event: &ReadyEvent) -> io::Result<()> {
    let stdout = io::stdout();
    let mut lock = stdout.lock();
    serde_json::to_writer(&mut lock, event)?;
    writeln!(lock)?;
    lock.flush()
}

/// Write a ReadyEvent as compact JSON + newline to the given raw fd, then drop the File (closing the fd).
/// # Safety / ownership
/// The fd is consumed by this call -- caller must not use it again.
/// The fd was passed to the daemon as --ready-fd N over argv; the runtime takes ownership the moment
/// it parses the CLI, and write_to_fd is the unique consumer.
pub fn write_to_fd(event: &ReadyEvent, ready_fd: RawFd) -> io::Result<()> {
    // The fd was passed to the daemon as --ready-fd N over argv; the runtime
    // takes ownership the moment it parses the CLI, and write_to_fd is the
    // unique consumer.
    let mut file = unsafe { <File as FromRawFd>::from_raw_fd(ready_fd) };
    serde_json::to_writer(&mut file, event)?;
    file.write_all(b"\n")?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::{ReadyEvent, StartupFailure};

    #[test]
    fn serializes_startup_failure() {
        let json = serde_json::to_string(&StartupFailure {
            error: "execution RPC chain id validation failed",
        })
        .expect("serialize startup failure");

        assert_eq!(
            json,
            r#"{"error":"execution RPC chain id validation failed"}"#
        );
    }

    /// The parent tells the two shapes apart by `error`, so a ready event must
    /// never carry that key.
    #[test]
    fn ready_event_has_no_error_field() {
        let json = serde_json::to_string(&ReadyEvent {
            token: "abc".to_string(),
            api_version: 1,
            daemon_spawn_protocol: 1,
            socket_path: None,
            http_addr: None,
        })
        .expect("serialize ready event");

        assert!(!json.contains("\"error\""), "{json}");
    }

    #[test]
    fn serializes_daemon_spawn_protocol() {
        let event = ReadyEvent {
            token: "abc".to_string(),
            api_version: 1,
            daemon_spawn_protocol: 1,
            socket_path: None,
            http_addr: None,
        };

        let json = serde_json::to_string(&event).expect("serialize ready event");

        assert_eq!(
            json,
            r#"{"token":"abc","apiVersion":1,"daemonSpawnProtocol":1,"socketPath":null,"httpAddr":null}"#
        );
    }

    #[test]
    fn serializes_http_addr_with_null_socket_path() {
        let event = ReadyEvent {
            token: "abc".to_string(),
            api_version: 1,
            daemon_spawn_protocol: 1,
            socket_path: None,
            http_addr: Some("127.0.0.1:1234".to_string()),
        };

        let json = serde_json::to_string(&event).expect("serialize ready event");

        assert_eq!(
            json,
            r#"{"token":"abc","apiVersion":1,"daemonSpawnProtocol":1,"socketPath":null,"httpAddr":"127.0.0.1:1234"}"#
        );
    }

    #[test]
    fn serializes_socket_path_with_null_http_addr() {
        let event = ReadyEvent {
            token: "abc".to_string(),
            api_version: 1,
            daemon_spawn_protocol: 1,
            socket_path: Some("/tmp/x.sock".into()),
            http_addr: None,
        };

        let json = serde_json::to_string(&event).expect("serialize ready event");

        assert_eq!(
            json,
            r#"{"token":"abc","apiVersion":1,"daemonSpawnProtocol":1,"socketPath":"/tmp/x.sock","httpAddr":null}"#
        );
    }
}
