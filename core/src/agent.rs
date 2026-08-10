//! Embedded MCP server: the streamable-HTTP transport and JSON-RPC layer
//! for the app's agent integration (tools only — no resources, prompts,
//! or server-initiated streams). The protocol lives here; executing a tool
//! is delegated to the host application through the handler installed at
//! start, so this module stays generic: it knows the catalog it was given
//! and nothing about documents.
//!
//! Transport notes: binds 127.0.0.1 only and answers every JSON-RPC POST
//! with a single `application/json` response (the streamable-HTTP spec
//! allows this in place of an SSE stream). Stateless — no session IDs are
//! issued, and GET/DELETE report 405 as the spec directs for servers
//! without server-push or client-terminated sessions.

use std::io::Read;
use std::net::{Ipv4Addr, SocketAddrV4};
use std::sync::Arc;
use std::thread::JoinHandle;

use serde_json::{json, Value};

/// Executes one tool call: (tool name, arguments JSON) -> CallToolResult
/// JSON (`{"content": [...], "isError": bool}`). None means the handler
/// itself failed (as opposed to the tool reporting an error result).
pub type ToolHandler = Box<dyn Fn(&str, &str) -> Option<String> + Send + Sync>;

pub struct AgentConfig {
    pub name: String,
    pub version: String,
    /// The `tools/list` catalog, pre-validated to be a JSON array.
    pub tools: Value,
    pub handler: ToolHandler,
}

pub struct AgentServer {
    server: Arc<tiny_http::Server>,
    thread: Option<JoinHandle<()>>,
}

impl AgentServer {
    /// Unblocks the accept loop and joins the serving thread.
    pub fn shutdown(mut self) {
        self.server.unblock();
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}

/// Protocol revisions this server implements identically (tools-only
/// servers are unchanged across them). An unknown requested version is
/// answered with the newest we know, per the spec's negotiation rule.
const SUPPORTED_VERSIONS: [&str; 3] = ["2024-11-05", "2025-03-26", "2025-06-18"];
const LATEST_VERSION: &str = "2025-06-18";

const MAX_BODY_BYTES: usize = 8 * 1024 * 1024;

/// Starts the server on 127.0.0.1:`port` (0 picks an ephemeral port) and
/// returns the bound port with the running server.
pub fn start(port: u16, config: AgentConfig) -> Result<(u16, AgentServer), String> {
    if !config.tools.is_array() {
        return Err("tools catalog must be a JSON array".to_string());
    }
    let addr = SocketAddrV4::new(Ipv4Addr::LOCALHOST, port);
    let server = tiny_http::Server::http(addr)
        .map_err(|e| format!("could not bind 127.0.0.1:{port}: {e}"))?;
    let server = Arc::new(server);
    let bound = server
        .server_addr()
        .to_ip()
        .map(|a| a.port())
        .ok_or_else(|| "server bound to a non-IP address".to_string())?;
    let accept = Arc::clone(&server);
    let thread = std::thread::spawn(move || serve(accept, config));
    Ok((
        bound,
        AgentServer {
            server,
            thread: Some(thread),
        },
    ))
}

enum Reply {
    Json(u16, Value),
    Empty(u16),
}

fn serve(server: Arc<tiny_http::Server>, config: AgentConfig) {
    for mut request in server.incoming_requests() {
        // One request at a time: tool calls serialize through the host's
        // main thread anyway, and a panic must not take the loop down.
        let reply = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            handle_request(&mut request, &config)
        }))
        .unwrap_or_else(|_| Reply::Json(500, rpc_error(Value::Null, -32603, "internal error")));
        let _ = match reply {
            Reply::Json(status, body) => request.respond(
                tiny_http::Response::from_string(body.to_string())
                    .with_status_code(status)
                    .with_header(
                        tiny_http::Header::from_bytes(
                            &b"Content-Type"[..],
                            &b"application/json"[..],
                        )
                        .expect("static header"),
                    ),
            ),
            Reply::Empty(status) => {
                request.respond(tiny_http::Response::empty(tiny_http::StatusCode(status)))
            }
        };
    }
}

fn handle_request(request: &mut tiny_http::Request, config: &AgentConfig) -> Reply {
    match request.method() {
        tiny_http::Method::Post => {}
        // No server-initiated SSE stream (GET) and no sessions to delete.
        _ => return Reply::Empty(405),
    }
    if request
        .body_length()
        .is_some_and(|len| len > MAX_BODY_BYTES)
    {
        return Reply::Empty(413);
    }
    let mut body = Vec::new();
    let mut reader = request.as_reader().take(MAX_BODY_BYTES as u64 + 1);
    if reader.read_to_end(&mut body).is_err() || body.len() > MAX_BODY_BYTES {
        return Reply::Empty(413);
    }
    let parsed: Value = match serde_json::from_slice(&body) {
        Ok(v) => v,
        Err(_) => return Reply::Json(400, rpc_error(Value::Null, -32700, "parse error")),
    };
    // A batch (2025-03-26 revision) is answered element-wise; notifications
    // produce no entry. All-notification input gets the bodiless 202.
    let replies: Vec<Value> = match parsed {
        Value::Array(items) => items
            .into_iter()
            .filter_map(|m| handle_message(m, config))
            .collect(),
        single => match handle_message(single, config) {
            Some(reply) => return Reply::Json(200, reply),
            None => return Reply::Empty(202),
        },
    };
    if replies.is_empty() {
        Reply::Empty(202)
    } else {
        Reply::Json(200, Value::Array(replies))
    }
}

/// Answers one JSON-RPC message; None for notifications (nothing to say).
fn handle_message(message: Value, config: &AgentConfig) -> Option<Value> {
    let Some(method) = message.get("method").and_then(Value::as_str) else {
        // A response to a server request — we never send any, so ignore.
        return None;
    };
    let id = message.get("id").cloned();
    let params = message.get("params").cloned().unwrap_or(json!({}));
    let Some(id) = id else {
        return None; // notification: nothing is ever returned
    };

    let reply = match method {
        "initialize" => {
            let requested = params
                .get("protocolVersion")
                .and_then(Value::as_str)
                .unwrap_or("");
            let version = if SUPPORTED_VERSIONS.contains(&requested) {
                requested
            } else {
                LATEST_VERSION
            };
            rpc_result(
                id,
                json!({
                    "protocolVersion": version,
                    "capabilities": {"tools": {}},
                    "serverInfo": {"name": config.name, "version": config.version},
                }),
            )
        }
        "ping" => rpc_result(id, json!({})),
        "tools/list" => rpc_result(id, json!({"tools": config.tools})),
        "tools/call" => {
            let Some(name) = params.get("name").and_then(Value::as_str) else {
                return Some(rpc_error(id, -32602, "tools/call requires a tool name"));
            };
            let arguments = params.get("arguments").cloned().unwrap_or(json!({}));
            let arguments = arguments.to_string();
            match (config.handler)(name, &arguments) {
                None => rpc_error(id, -32603, "tool handler failed"),
                Some(result) => match serde_json::from_str::<Value>(&result) {
                    Ok(value) if value.is_object() => rpc_result(id, value),
                    _ => rpc_error(id, -32603, "tool returned invalid JSON"),
                },
            }
        }
        _ => rpc_error(id, -32601, &format!("method not found: {method}")),
    };
    Some(reply)
}

fn rpc_result(id: Value, result: Value) -> Value {
    json!({"jsonrpc": "2.0", "id": id, "result": result})
}

fn rpc_error(id: Value, code: i64, message: &str) -> Value {
    json!({"jsonrpc": "2.0", "id": id, "error": {"code": code, "message": message}})
}
