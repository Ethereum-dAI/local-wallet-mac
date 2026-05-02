fn main() {
    // Fresh finalized mainnet checkpoint for local development / this build.
    // Source: https://lodestar-mainnet.chainsafe.io
    // Slot: 14233856, timestamp: 2026-05-01T10:11:35Z.
    // Release builds must refresh this before shipping so the checkpoint remains
    // inside the daemon's 2-week weak-subjectivity window.
    println!(
        "cargo:rustc-env=BUNDLED_CHECKPOINT=0xb18daf09db8adb681e9b6bc09c955a19c3e30b6604971614e5f85585e763a6f1"
    );
    println!("cargo:rustc-env=BUNDLED_CHECKPOINT_SLOT_TIMESTAMP=1777630295");
    println!("cargo:rerun-if-changed=build.rs");
}
