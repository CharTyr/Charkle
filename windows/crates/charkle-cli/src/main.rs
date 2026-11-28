//! Native Windows Pure MCP v2 stdio helper (`charkle-cli.exe`).
//!
//! Intentionally stripped down to ONLY:
//! - `charkle-cli mcp [--library-dir <path>]` — JSON-RPC 2.0 MCP server on stdio
//!   (supports both NDJSON and LSP-style `Content-Length` framing + batch arrays)
//! - `charkle-cli doctor [--library-dir <path>]` — readiness & capability diagnostics
//! - `--version` / `-v` — prints `charkle-mcp <version>`
//! - `--help` / `-h` — prints usage
//!
//! Opens `Library.sqlite3` directly in SQLite WAL mode, enforces `ExternalAgentConfig`
//! (3-tier access policy, soft-trash only), and signals any running `charkle-desktop.exe`
//! via `Local\CharkleLibraryChanged` after every write tool call.

use std::io::{self, BufRead, BufReader, IsTerminal, Read, Write};
use std::path::PathBuf;
use std::sync::Arc;

use charkle_core::agent::{resolve_default_data_dir, CharkleExternalAgentService, SERVER_VERSION};
use charkle_core::engine::LiveCharkleEngine;
use charkle_platform_win::wake::pulse_library_changed;
use clap::{CommandFactory, Parser, Subcommand};
use serde_json::{json, Value};

#[derive(Debug, Parser)]
#[command(
    name = "charkle-cli",
    version = SERVER_VERSION,
    about = "Charkle Windows Pure MCP v2 stdio Server",
    disable_version_flag = true
)]
struct Cli {
    /// Override Charkle library data directory (defaults to AppData / CHARKLE_LIBRARY_DIR).
    #[arg(long, global = true)]
    library_dir: Option<PathBuf>,

    /// Print version (`charkle-mcp <version>`).
    #[arg(short = 'v', long = "version", global = true)]
    version: bool,

    /// Force compact single-line JSON output for `doctor`.
    #[arg(long, global = true)]
    compact: bool,

    /// Force pretty-printed JSON output for `doctor`.
    #[arg(long, global = true)]
    pretty: bool,

    #[command(subcommand)]
    command: Option<Commands>,
}

#[derive(Debug, Subcommand, PartialEq, Eq)]
enum Commands {
    /// Run JSON-RPC 2.0 Model Context Protocol (MCP v2) server on stdio.
    Mcp,
    /// Check library health, policy & MCP v2 capabilities.
    Doctor,
    /// Catch-all for retired legacy business CLI subcommands (exits with status 2).
    #[command(external_subcommand)]
    Retired(Vec<String>),
}

#[derive(Debug, PartialEq, Eq)]
enum ParsedAction {
    Mcp {
        library_dir: Option<PathBuf>,
    },
    Doctor {
        library_dir: Option<PathBuf>,
        compact: bool,
        pretty: bool,
    },
    Version,
    Help,
    Retired {
        command: String,
    },
}

fn resolve_action(cli: Cli, stdin_is_tty: bool) -> ParsedAction {
    if cli.version {
        return ParsedAction::Version;
    }
    match cli.command {
        None => {
            if stdin_is_tty {
                ParsedAction::Help
            } else {
                ParsedAction::Mcp {
                    library_dir: cli.library_dir,
                }
            }
        }
        Some(Commands::Mcp) => ParsedAction::Mcp {
            library_dir: cli.library_dir,
        },
        Some(Commands::Doctor) => ParsedAction::Doctor {
            library_dir: cli.library_dir,
            compact: cli.compact,
            pretty: cli.pretty,
        },
        Some(Commands::Retired(args)) => ParsedAction::Retired {
            command: args.into_iter().next().unwrap_or_default(),
        },
    }
}

fn format_json_output(value: &Value, pretty: bool) -> String {
    if pretty {
        serde_json::to_string_pretty(value).unwrap_or_else(|_| value.to_string())
    } else {
        serde_json::to_string(value).unwrap_or_else(|_| value.to_string())
    }
}

#[tokio::main]
async fn main() {
    let _ = tracing_subscriber::fmt()
        .with_writer(std::io::stderr)
        .try_init();

    let stdin_is_tty = io::stdin().is_terminal();
    let stdout_is_tty = io::stdout().is_terminal();
    let cli = Cli::parse();

    match resolve_action(cli, stdin_is_tty) {
        ParsedAction::Version => {
            println!("charkle-mcp {SERVER_VERSION}");
        }
        ParsedAction::Help => {
            let _ = Cli::command().print_help();
            println!(
                "\n\nNOTES:\n  - When stdin is piped (non-TTY) and no subcommand is given, `mcp` starts automatically.\n  - Legacy business CLI subcommands were retired in Pure MCP v2; connect via stdio MCP (`charkle-cli.exe mcp`) or Streamable HTTP MCP (`/api/v1/mcp`)."
            );
        }
        ParsedAction::Retired { command } => {
            eprintln!(
                "Error: subcommand `{command}` was retired in Charkle Pure MCP v2.\n\
                 Use `charkle-cli.exe mcp` (stdio MCP) or Charkle Desktop's Streamable HTTP MCP endpoint (`/api/v1/mcp`).\n\
                 Run `charkle-cli.exe doctor` to verify library & MCP readiness."
            );
            std::process::exit(2);
        }
        ParsedAction::Doctor {
            library_dir,
            compact,
            pretty,
        } => {
            let data_dir = library_dir.unwrap_or_else(resolve_default_data_dir);
            let engine = match LiveCharkleEngine::open(&data_dir) {
                Ok(e) => Arc::new(e),
                Err(err) => {
                    eprintln!(
                        "Failed to open Charkle library at {}: {err}",
                        data_dir.display()
                    );
                    std::process::exit(1);
                }
            };
            let service = CharkleExternalAgentService::new(engine, data_dir, None);
            let report = service.run_diagnostics();
            let use_pretty = !compact && (pretty || stdout_is_tty);
            println!("{}", format_json_output(&report, use_pretty));
            if !report["ok"].as_bool().unwrap_or(false) {
                std::process::exit(1);
            }
        }
        ParsedAction::Mcp { library_dir } => {
            let data_dir = library_dir.unwrap_or_else(resolve_default_data_dir);
            let engine = match LiveCharkleEngine::open(&data_dir) {
                Ok(e) => Arc::new(e),
                Err(err) => {
                    eprintln!(
                        "Failed to open Charkle library at {}: {err}",
                        data_dir.display()
                    );
                    std::process::exit(1);
                }
            };
            let wake_dir = data_dir.clone();
            let service = CharkleExternalAgentService::new(
                engine,
                data_dir,
                Some(Arc::new(move |_| {
                    pulse_library_changed(Some(&wake_dir));
                })),
            );
            run_mcp_stdio(&service).await;
        }
    }
}

const MAX_MCP_CONTENT_LENGTH: usize = 16 * 1024 * 1024;
const MAX_MCP_LINE_BYTES: usize = MAX_MCP_CONTENT_LENGTH + 4096;

/// Reads one newline-terminated line with a hard byte bound so hostile stdin cannot cause OOM.
fn read_bounded_line<R: BufRead>(
    reader: &mut R,
    out: &mut String,
    max_bytes: usize,
) -> io::Result<Option<usize>> {
    out.clear();
    let mut raw = Vec::new();
    loop {
        let avail = reader.fill_buf()?;
        if avail.is_empty() {
            if raw.is_empty() {
                return Ok(None);
            }
            break;
        }
        if let Some(nl_pos) = avail.iter().position(|&b| b == b'\n') {
            let take = nl_pos + 1;
            if raw.len().saturating_add(take) > max_bytes {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    "Input line exceeds 16 MiB safety limit",
                ));
            }
            raw.extend_from_slice(&avail[..take]);
            reader.consume(take);
            break;
        }
        let take = avail.len();
        if raw.len().saturating_add(take) > max_bytes {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "Input line exceeds 16 MiB safety limit",
            ));
        }
        raw.extend_from_slice(avail);
        reader.consume(take);
    }
    let len = raw.len();
    *out = String::from_utf8_lossy(&raw).into_owned();
    Ok(Some(len))
}

/// Parses an LSP-style `Content-Length` header line case-insensitively with an upper bound.
fn parse_mcp_content_length(header_line: &str) -> Option<Result<usize, &'static str>> {
    let (name, value) = header_line.split_once(':')?;
    if !name.trim().eq_ignore_ascii_case("content-length") {
        return None;
    }
    match value.trim().parse::<usize>() {
        Ok(len) if len <= MAX_MCP_CONTENT_LENGTH => Some(Ok(len)),
        Ok(_) => Some(Err("Content-Length exceeds 16 MiB limit")),
        Err(_) => Some(Err("Invalid Content-Length header value")),
    }
}

fn looks_like_lsp_header(line: &str) -> bool {
    if line.starts_with('{') || line.starts_with('[') {
        return false;
    }
    let Some((name, _)) = line.split_once(':') else {
        return false;
    };
    !name.is_empty() && name.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-')
}

/// Supports both newline-delimited JSON-RPC (MCP stdio spec) and LSP-style `Content-Length` framing
/// regardless of header ordering (e.g. `Content-Type` before `Content-Length`).
async fn run_mcp_stdio(service: &CharkleExternalAgentService) {
    let stdin = io::stdin();
    let stdout = io::stdout();
    let mut reader = BufReader::new(stdin.lock());
    let mut out = stdout.lock();
    let mut line = String::new();

    loop {
        match read_bounded_line(&mut reader, &mut line, MAX_MCP_LINE_BYTES) {
            Ok(Some(_)) => {}
            Ok(None) => break,
            Err(err) => {
                let reply = json!({
                    "jsonrpc": "2.0",
                    "id": Value::Null,
                    "error": { "code": -32600, "message": err.to_string() }
                })
                .to_string();
                let _ = writeln!(out, "{reply}");
                let _ = out.flush();
                break;
            }
        }
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }

        if looks_like_lsp_header(trimmed) {
            let mut parsed_len = parse_mcp_content_length(trimmed);
            let mut header_count = 1usize;
            loop {
                let mut hdr = String::new();
                match read_bounded_line(&mut reader, &mut hdr, 16 * 1024) {
                    Ok(Some(_)) => {
                        let t = hdr.trim();
                        if t.is_empty() {
                            break;
                        }
                        header_count += 1;
                        if header_count > 32 {
                            parsed_len = Some(Err("Too many LSP framing headers"));
                            break;
                        }
                        if let Some(cl) = parse_mcp_content_length(t) {
                            parsed_len = Some(cl);
                        }
                    }
                    _ => break,
                }
            }
            match parsed_len {
                Some(Ok(content_len)) => {
                    let mut buf = vec![0u8; content_len];
                    if reader.read_exact(&mut buf).is_err() {
                        break;
                    }
                    let body = String::from_utf8_lossy(&buf);
                    if let Some(reply) = service.handle_jsonrpc(&body).await {
                        let _ = write!(out, "Content-Length: {}\r\n\r\n{}", reply.len(), reply);
                        let _ = out.flush();
                    }
                }
                Some(Err(msg)) => {
                    let reply = json!({
                        "jsonrpc": "2.0",
                        "id": Value::Null,
                        "error": { "code": -32600, "message": msg }
                    })
                    .to_string();
                    let _ = write!(out, "Content-Length: {}\r\n\r\n{}", reply.len(), reply);
                    let _ = out.flush();
                    break;
                }
                None => {
                    let reply = json!({
                        "jsonrpc": "2.0",
                        "id": Value::Null,
                        "error": { "code": -32600, "message": "Missing Content-Length header" }
                    })
                    .to_string();
                    let _ = write!(out, "Content-Length: {}\r\n\r\n{}", reply.len(), reply);
                    let _ = out.flush();
                }
            }
            continue;
        }

        if let Some(reply) = service.handle_jsonrpc(trimmed).await {
            let _ = writeln!(out, "{reply}");
            let _ = out.flush();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_mcp_content_length_case_insensitive_and_enforces_limit() {
        assert_eq!(
            parse_mcp_content_length("Content-Length: 128"),
            Some(Ok(128))
        );
        assert_eq!(parse_mcp_content_length("content-length: 42"), Some(Ok(42)));
        assert_eq!(parse_mcp_content_length("CONTENT-LENGTH: 0"), Some(Ok(0)));
        assert!(matches!(
            parse_mcp_content_length("Content-Length: 99999999999"),
            Some(Err(_))
        ));
        assert!(matches!(
            parse_mcp_content_length("Content-Length: not-a-number"),
            Some(Err(_))
        ));
        assert_eq!(
            parse_mcp_content_length("Content-Type: application/json"),
            None
        );
    }

    #[test]
    fn pure_mcp_v2_cli_routes_only_mcp_doctor_help_version_and_rejects_retired_subcommands() {
        let eval = |args: &[&str], tty: bool| resolve_action(Cli::parse_from(args), tty);
        assert_eq!(
            eval(&["charkle-cli"], false),
            ParsedAction::Mcp { library_dir: None }
        );
        assert_eq!(eval(&["charkle-cli"], true), ParsedAction::Help);
        assert_eq!(
            eval(&["charkle-cli", "--library-dir", "/tmp/lib", "mcp"], true),
            ParsedAction::Mcp {
                library_dir: Some(PathBuf::from("/tmp/lib")),
            }
        );
        assert_eq!(
            eval(&["charkle-cli", "doctor", "--library-dir=/tmp/lib"], true),
            ParsedAction::Doctor {
                library_dir: Some(PathBuf::from("/tmp/lib")),
                compact: false,
                pretty: false,
            }
        );
        assert_eq!(
            eval(&["charkle-cli", "--version"], true),
            ParsedAction::Version
        );
        assert_eq!(
            eval(&["charkle-cli", "overview"], true),
            ParsedAction::Retired {
                command: "overview".to_string(),
            }
        );
        assert_eq!(
            eval(&["charkle-cli", "search", "sunset"], false),
            ParsedAction::Retired {
                command: "search".to_string(),
            }
        );
    }
}
