use std::process::Command;

fn main() {
    // Try to probe the current git short SHA. On any failure (no git, not a repo,
    // shallow checkout in CI without history, etc.), do nothing — option_env! at
    // the call site falls back to a friendly placeholder.
    let probe = Command::new("git")
        .args(["rev-parse", "--short", "HEAD"])
        .output();

    if let Ok(out) = probe {
        if out.status.success() {
            let sha = String::from_utf8_lossy(&out.stdout).trim().to_string();
            if !sha.is_empty() {
                println!("cargo:rustc-env=WALLET_NODE_GIT_SHA={sha}");
            }
        }
    }

    // Re-run when HEAD moves (commits, branch switches, rebases all touch this file).
    // The path is relative to the crate root (crates/wallet-node/).
    // From there, ../../.git/HEAD reaches the repo root .git/HEAD.
    // If this path is wrong the worst case is the build script does not re-run on
    // new commits — not a correctness bug, just a freshness issue.
    println!("cargo:rerun-if-changed=../../.git/HEAD");
}
