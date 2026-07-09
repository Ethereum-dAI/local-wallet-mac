fn main() {
    // Fresh finalized mainnet checkpoint for local development / this build.
    // Source: https://lodestar-mainnet.chainsafe.io
    // Slot: 14413568, timestamp: 2026-05-26T09:13:59Z.
    // Release builds must refresh this before shipping so the checkpoint remains
    // inside the daemon's 2-week weak-subjectivity window.
    println!(
        "cargo:rustc-env=BUNDLED_CHECKPOINT=0xf2e9ce57284a3299e95cf9801be462bc5f5c96c2f555b1c049ac9d1664177518"
    );
    println!("cargo:rustc-env=BUNDLED_CHECKPOINT_SLOT_TIMESTAMP=1779786839");
    println!("cargo:rerun-if-changed=build.rs");
}
