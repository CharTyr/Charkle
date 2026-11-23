//! Standalone `charkle-cli.exe` binary stub (M1 scaffold; full CLI & MCP stdio land in M5).

use clap::{Parser, Subcommand};

#[derive(Debug, Parser)]
#[command(
    name = "charkle-cli",
    version,
    about = "Charkle Windows CLI & MCP helper"
)]
struct Cli {
    #[command(subcommand)]
    command: Option<Commands>,
}

#[derive(Debug, Subcommand)]
enum Commands {
    /// Print CLI and core workspace readiness status.
    Status,
}

fn main() {
    let _ = tracing_subscriber::fmt()
        .with_writer(std::io::stderr)
        .try_init();
    let cli = Cli::parse();
    let _vault = charkle_core::traits::InMemorySecretVault::new();
    match cli.command.unwrap_or(Commands::Status) {
        Commands::Status => {
            tracing::debug!("charkle-cli status invoked");
            println!(
                "charkle-cli {} (charkle-core linked)",
                env!("CARGO_PKG_VERSION")
            );
        }
    }
}
