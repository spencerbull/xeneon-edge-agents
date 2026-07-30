use std::{
    path::{Path, PathBuf},
    time::Duration,
};

use anyhow::{Context, Result, bail};
use clap::{Parser, Subcommand};
use serde_json::Value;
use tokio::{
    fs,
    io::{self, AsyncBufReadExt, AsyncWriteExt, BufReader},
    net::UnixStream,
    time::interval,
};
use uuid::Uuid;
use xeneon_agent_core::{ActionResult, ServerMessage, socket_path};

#[derive(Debug, Parser)]
#[command(version, about = "XENEON EDGE portal bridge and diagnostics")]
struct Args {
    #[arg(long, global = true, env = "XENEON_AGENT_SOCKET")]
    socket: Option<PathBuf>,

    #[command(subcommand)]
    command: Command,
}

#[derive(Debug, Subcommand)]
enum Command {
    /// Bidirectionally bridge daemon NDJSON to stdin/stdout for Quickshell.
    QmlBridge,
    /// Print the next complete portal snapshot.
    Snapshot,
    /// Validate the daemon protocol and report connection health.
    Doctor,
    /// Serve a deterministic snapshot file without a daemon.
    Fixture {
        #[arg(long)]
        path: PathBuf,
        #[arg(long, default_value_t = 0)]
        repeat_ms: u64,
    },
}

#[tokio::main]
async fn main() -> Result<()> {
    let args = Args::parse();
    match args.command {
        Command::QmlBridge => qml_bridge(&socket_path(args.socket.as_deref())?).await,
        Command::Snapshot => print_snapshot(&socket_path(args.socket.as_deref())?).await,
        Command::Doctor => doctor(&socket_path(args.socket.as_deref())?).await,
        Command::Fixture { path, repeat_ms } => fixture(&path, repeat_ms).await,
    }
}

async fn connect(path: &Path) -> Result<UnixStream> {
    UnixStream::connect(path)
        .await
        .with_context(|| format!("connecting to {}", path.display()))
}

async fn qml_bridge(path: &Path) -> Result<()> {
    let stream = connect(path).await?;
    let (read, mut write) = stream.into_split();
    let writer = tokio::spawn(async move {
        let mut stdin = io::stdin();
        io::copy(&mut stdin, &mut write).await?;
        write.shutdown().await
    });

    let mut lines = BufReader::new(read).lines();
    let mut stdout = io::stdout();
    while let Some(line) = lines.next_line().await? {
        stdout.write_all(line.as_bytes()).await?;
        stdout.write_all(b"\n").await?;
        stdout.flush().await?;
    }
    writer.abort();
    Ok(())
}

async fn print_snapshot(path: &Path) -> Result<()> {
    let stream = connect(path).await?;
    let mut lines = BufReader::new(stream).lines();
    while let Some(line) = lines.next_line().await? {
        let value: Value = serde_json::from_str(&line)?;
        if value["type"] == "snapshot" {
            println!("{line}");
            return Ok(());
        }
    }
    bail!("daemon closed before sending a snapshot")
}

async fn doctor(path: &Path) -> Result<()> {
    let stream = connect(path).await?;
    let mut lines = BufReader::new(stream).lines();
    let line = lines
        .next_line()
        .await?
        .context("daemon closed before protocol handshake")?;
    let value: Value = serde_json::from_str(&line).context("daemon returned invalid JSON")?;
    if value["type"] != "snapshot" || value["schema_version"] != 1 {
        bail!("unsupported daemon protocol: {value}");
    }
    let agents = value["agents"].as_array().map_or(0, Vec::len);
    let sessions = value["sessions"].as_array().map_or(0, Vec::len);
    println!(
        "ok: schema=1 connection={} sessions={sessions} agents={agents}",
        value["connection"].as_str().unwrap_or("unknown")
    );
    Ok(())
}

async fn fixture(path: &Path, repeat_ms: u64) -> Result<()> {
    let contents = fs::read_to_string(path)
        .await
        .with_context(|| format!("reading fixture {}", path.display()))?;
    let fixture: Value = serde_json::from_str(contents.trim())
        .with_context(|| format!("parsing fixture {}", path.display()))?;
    if fixture["type"] != "snapshot" || fixture["schema_version"] != 1 {
        bail!("fixture must be a schema-v1 snapshot envelope");
    }

    let encoded = serde_json::to_string(&fixture)?;
    let mut stdout = io::stdout();
    stdout.write_all(encoded.as_bytes()).await?;
    stdout.write_all(b"\n").await?;
    stdout.flush().await?;

    let mut lines = BufReader::new(io::stdin()).lines();
    if repeat_ms == 0 {
        while let Some(line) = lines.next_line().await? {
            fixture_action_result(&line, &mut stdout).await?;
        }
        return Ok(());
    }

    let mut tick = interval(Duration::from_millis(repeat_ms.max(250)));
    tick.tick().await;
    loop {
        tokio::select! {
            line = lines.next_line() => {
                let Some(line) = line? else {
                    return Ok(());
                };
                fixture_action_result(&line, &mut stdout).await?;
            }
            _ = tick.tick() => {
                stdout.write_all(encoded.as_bytes()).await?;
                stdout.write_all(b"\n").await?;
                stdout.flush().await?;
            }
        }
    }
}

async fn fixture_action_result(line: &str, stdout: &mut io::Stdout) -> Result<()> {
    let command: Value = serde_json::from_str(line)?;
    let request_id = command["request_id"]
        .as_str()
        .map(str::to_owned)
        .unwrap_or_else(|| Uuid::new_v4().to_string());
    let result = ActionResult {
        schema_version: 1,
        request_id,
        ok: true,
        code: "fixture".into(),
        message: format!(
            "fixture accepted {}",
            command["action"].as_str().unwrap_or("unknown")
        ),
    };
    let message = ServerMessage::ActionResult { result };
    stdout
        .write_all(serde_json::to_string(&message)?.as_bytes())
        .await?;
    stdout.write_all(b"\n").await?;
    stdout.flush().await?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    #[test]
    fn fixture_result_contains_no_forwarded_payload() {
        let command = json!({
            "type": "command",
            "request_id": "one",
            "action": "open",
            "agent_id": "agent"
        });
        assert_eq!(command["action"], "open");
        assert!(command.get("keys").is_none());
        assert!(command.get("text").is_none());
    }
}
