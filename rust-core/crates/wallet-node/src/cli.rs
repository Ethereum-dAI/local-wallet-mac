use std::path::PathBuf;

use clap::{Parser, Subcommand};
use thiserror::Error;

use crate::admin::AdminArgs;

#[derive(Debug, Parser)]
pub struct Cli {
    #[arg(long, value_name = "N")]
    pub ready_fd: Option<u32>,

    #[arg(long, value_name = "N")]
    pub alive_fd: Option<u32>,

    #[arg(long, value_name = "N")]
    pub secret_fd: Option<u32>,

    #[arg(long, value_name = "ADDR")]
    pub http: Option<String>,

    #[arg(long)]
    pub print_ready: bool,

    #[arg(long)]
    pub print_api_version: bool,

    #[arg(long, value_name = "PATH")]
    pub config: Option<PathBuf>,

    #[arg(long)]
    pub debug: bool,

    #[arg(long, value_name = "URL")]
    pub manifest_url: Option<String>,

    #[command(subcommand)]
    pub command: Option<CliCommand>,
}

#[derive(Debug, Subcommand)]
pub enum CliCommand {
    Admin(AdminArgs),
}

#[derive(Debug, Error)]
pub enum CliError {
    #[error("missing file descriptor pair: --ready-fd requires --alive-fd")]
    MissingAliveFd,

    #[error("missing file descriptor pair: --alive-fd requires --ready-fd")]
    MissingReadyFd,

    #[error("--http cannot be used with --ready-fd or --alive-fd")]
    HttpAndFdsMutuallyExclusive,

    #[error("--secret-fd requires --ready-fd")]
    SecretFdRequiresReadyFd,

    #[error("--print-ready requires --http")]
    PrintReadyRequiresHttp,

    #[error("--manifest-url requires --debug")]
    ManifestUrlRequiresDebug,

    #[error(transparent)]
    Clap(#[from] clap::Error),
}

impl Cli {
    pub fn validate(&self) -> Result<(), CliError> {
        if self.ready_fd.is_some() && self.alive_fd.is_none() {
            return Err(CliError::MissingAliveFd);
        }

        if self.alive_fd.is_some() && self.ready_fd.is_none() {
            return Err(CliError::MissingReadyFd);
        }

        if self.http.is_some() && (self.ready_fd.is_some() || self.alive_fd.is_some()) {
            return Err(CliError::HttpAndFdsMutuallyExclusive);
        }

        if self.secret_fd.is_some() && self.ready_fd.is_none() {
            return Err(CliError::SecretFdRequiresReadyFd);
        }

        if self.print_ready && self.http.is_none() {
            return Err(CliError::PrintReadyRequiresHttp);
        }

        if self.manifest_url.is_some() && !self.debug {
            return Err(CliError::ManifestUrlRequiresDebug);
        }

        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::{Cli, CliError};
    use clap::Parser;

    fn parse(args: &[&str]) -> Cli {
        Cli::try_parse_from(args).expect("cli args should parse")
    }

    #[test]
    fn validates_ready_and_alive_fds() {
        let cli = parse(&["wallet-node", "--ready-fd", "3", "--alive-fd", "4"]);

        assert!(cli.validate().is_ok());
    }

    #[test]
    fn validates_secret_fd_with_ready_fd() {
        let cli = parse(&[
            "wallet-node",
            "--ready-fd",
            "3",
            "--alive-fd",
            "4",
            "--secret-fd",
            "5",
        ]);

        assert!(cli.validate().is_ok());
    }

    #[test]
    fn validates_http() {
        let cli = parse(&["wallet-node", "--http", "127.0.0.1:0"]);

        assert!(cli.validate().is_ok());
    }

    #[test]
    #[should_panic]
    fn rejects_invalid_port_in_http_arg() {
        // Current Phase 1 CLI stores --http as a raw String, so clap does not
        // validate the address until production parsing is tightened.
        assert!(Cli::try_parse_from(["wallet-node", "--http", "127.0.0.1:notaport"]).is_err());
    }

    #[test]
    fn accepts_ipv6_loopback_in_http_arg() {
        let cli = parse(&["wallet-node", "--http", "[::1]:0"]);

        assert_eq!(cli.http.as_deref(), Some("[::1]:0"));
    }

    #[test]
    fn accepts_explicit_port_in_http_arg() {
        let cli = parse(&["wallet-node", "--http", "127.0.0.1:55555"]);

        assert_eq!(cli.http.as_deref(), Some("127.0.0.1:55555"));
    }

    #[test]
    fn validates_http_with_print_ready() {
        let cli = parse(&["wallet-node", "--http", "127.0.0.1:0", "--print-ready"]);

        assert!(cli.validate().is_ok());
    }

    #[test]
    fn validates_print_api_version() {
        let cli = parse(&["wallet-node", "--print-api-version"]);

        assert!(cli.validate().is_ok());
    }

    #[test]
    fn accepts_manifest_url_with_debug() {
        let cli = parse(&[
            "wallet-node",
            "--http",
            "127.0.0.1:0",
            "--debug",
            "--manifest-url",
            "https://example.invalid/kernel.json",
        ]);

        assert!(cli.validate().is_ok());
        assert_eq!(
            cli.manifest_url.as_deref(),
            Some("https://example.invalid/kernel.json")
        );
    }

    #[test]
    fn rejects_ready_fd_without_alive_fd() {
        let cli = parse(&["wallet-node", "--ready-fd", "3"]);

        assert!(matches!(cli.validate(), Err(CliError::MissingAliveFd)));
    }

    #[test]
    fn rejects_alive_fd_without_ready_fd() {
        let cli = parse(&["wallet-node", "--alive-fd", "4"]);

        assert!(matches!(cli.validate(), Err(CliError::MissingReadyFd)));
    }

    #[test]
    fn rejects_negative_fd() {
        assert!(
            Cli::try_parse_from(["wallet-node", "--ready-fd", "-1", "--alive-fd", "4"]).is_err()
        );
    }

    #[test]
    fn accepts_large_fd_numbers() {
        let cli = parse(&[
            "wallet-node",
            "--ready-fd",
            "999999",
            "--alive-fd",
            "1000000",
        ]);

        assert_eq!(cli.ready_fd, Some(999999));
        assert_eq!(cli.alive_fd, Some(1000000));
    }

    #[test]
    fn rejects_http_with_ready_and_alive_fds() {
        let cli = parse(&[
            "wallet-node",
            "--ready-fd",
            "3",
            "--alive-fd",
            "4",
            "--http",
            "127.0.0.1:0",
        ]);

        assert!(matches!(
            cli.validate(),
            Err(CliError::HttpAndFdsMutuallyExclusive)
        ));
    }

    #[test]
    fn rejects_secret_fd_without_ready_fd() {
        let cli = parse(&["wallet-node", "--http", "127.0.0.1:0", "--secret-fd", "5"]);

        assert!(matches!(
            cli.validate(),
            Err(CliError::SecretFdRequiresReadyFd)
        ));
    }

    #[test]
    fn rejects_print_ready_without_http() {
        let cli = parse(&["wallet-node", "--print-ready"]);

        assert!(matches!(
            cli.validate(),
            Err(CliError::PrintReadyRequiresHttp)
        ));
    }

    #[test]
    fn rejects_manifest_url_without_debug() {
        let cli = parse(&[
            "wallet-node",
            "--http",
            "127.0.0.1:0",
            "--manifest-url",
            "https://example.invalid/kernel.json",
        ]);

        assert!(matches!(
            cli.validate(),
            Err(CliError::ManifestUrlRequiresDebug)
        ));
    }
}
