use std::time::Instant;
use std::time::{SystemTime, UNIX_EPOCH};
use tokio::time::{sleep, timeout, Duration};
use wallet_chain::{run_smoke_test, BlockTag, ChainAdapter, ChainConfig, HeliosChainAdapter};

#[tokio::test]
#[ignore = "requires real Helios sync; run with --include-ignored on a host with network access"]
async fn state_override_startup_smoke_real_helios() {
    init_tracing();

    let mut config = ChainConfig::default();
    if let Ok(execution_rpc) = std::env::var("WALLET_CHAIN_EXECUTION_RPC") {
        config.execution_rpc = execution_rpc;
    }
    if let Ok(consensus_rpc) = std::env::var("WALLET_CHAIN_CONSENSUS_RPC") {
        config.consensus_rpc = consensus_rpc;
    }
    config.data_dir = std::env::temp_dir().join(format!(
        "wallet-chain-helios-smoke-{}-{}",
        std::process::id(),
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos()
    ));

    let (adapter, _handle) = HeliosChainAdapter::start(config.clone())
        .await
        .expect("Helios should start");

    let consensus_started = Instant::now();
    match timeout(Duration::from_secs(180), adapter.wait_consensus_synced()).await {
        Ok(Ok(())) => eprintln!(
            "Helios consensus sync completed in {:?}",
            consensus_started.elapsed()
        ),
        Ok(Err(err)) => panic!(
            "Helios consensus sync failed after {:?}: {err}; diagnostic: {}",
            consensus_started.elapsed(),
            sync_diagnostic(&adapter).await
        ),
        Err(_) => panic!(
            "Helios consensus sync timed out after 180s; diagnostic: {}",
            sync_diagnostic(&adapter).await
        ),
    }

    let sync_started = Instant::now();
    let mut next_diagnostic_at = Duration::ZERO;
    let mut last_diagnostic = "no diagnostic collected yet".to_owned();
    while !adapter.is_synced().await {
        let elapsed = sync_started.elapsed();
        if elapsed >= next_diagnostic_at {
            last_diagnostic = sync_diagnostic(&adapter).await;
            eprintln!(
                "waiting for Helios sync after {:?}: {}",
                elapsed, last_diagnostic
            );
            next_diagnostic_at = elapsed + Duration::from_secs(15);
        }
        assert!(
            elapsed < Duration::from_secs(180),
            "Helios verified latest block was not ready within 180s; last diagnostic: {last_diagnostic}"
        );
        sleep(Duration::from_secs(1)).await;
    }

    let smoke_started = Instant::now();
    run_smoke_test(&adapter)
        .await
        .expect("stateOverride smoke test should pass");
    eprintln!(
        "stateOverride smoke test completed in {:?}",
        smoke_started.elapsed()
    );

    let _ = std::fs::remove_dir_all(config.data_dir);
}

fn init_tracing() {
    let _ = tracing_subscriber::fmt()
        .with_env_filter(
            std::env::var("RUST_LOG").unwrap_or_else(|_| "helios=debug,wallet_chain=debug".into()),
        )
        .with_test_writer()
        .try_init();
}

async fn sync_diagnostic(adapter: &HeliosChainAdapter) -> String {
    let checkpoint = match adapter.current_checkpoint().await {
        Ok(Some(checkpoint)) => format!("checkpoint={checkpoint:#x}"),
        Ok(None) => "checkpoint=null".to_string(),
        Err(err) => format!("checkpoint_error={err}"),
    };
    let current_head = match adapter.current_head().await {
        Ok(head) => format!("helios_head={} helios_hash={:#x}", head.number, head.hash),
        Err(err) => format!("helios_head_error={err}"),
    };
    let finalized_head = match adapter
        .eth_get_block_by_number(BlockTag::Finalized, false)
        .await
    {
        Ok(Some(block)) => format!(
            "helios_finalized={} helios_finalized_hash={:#x}",
            block.header.number, block.header.hash
        ),
        Ok(None) => "helios_finalized=null".to_string(),
        Err(err) => format!("helios_finalized_error={err}"),
    };
    let execution_head = match adapter.execution_rpc_head().await {
        Ok(head) => format!("execution_head={head}"),
        Err(err) => format!("execution_head_error={err}"),
    };
    format!("{checkpoint}; {current_head}; {finalized_head}; {execution_head}")
}
