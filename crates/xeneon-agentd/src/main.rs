use std::path::PathBuf;

use anyhow::Result;
use clap::Parser;
use tracing_subscriber::EnvFilter;
use xeneon_agent_core::{Config, DaemonRuntime, socket_path};

#[derive(Debug, Parser)]
#[command(version, about = "XENEON EDGE Herdr state and action daemon")]
struct Args {
    /// Override the XDG configuration file.
    #[arg(long, env = "XENEON_AGENT_CONFIG")]
    config: Option<PathBuf>,

    /// Override the user-only daemon socket.
    #[arg(long, env = "XENEON_AGENT_SOCKET")]
    socket: Option<PathBuf>,
}

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| EnvFilter::new("xeneon_agentd=info,xeneon_agent_core=info")),
        )
        .init();
    let args = Args::parse();
    let config = Config::load(args.config.as_deref())?;
    let path = socket_path(args.socket.as_deref())?;
    let (runtime, invalidations) = DaemonRuntime::new(config)?;
    runtime.run(&path, invalidations).await
}
