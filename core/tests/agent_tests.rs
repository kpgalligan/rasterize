//! Integration tests for the embedded MCP server, driven through the C
//! FFI (`rz_agent_*`) like a host application would, with a raw TCP HTTP
//! client standing in for an MCP client.

use std::ffi::{c_char, c_void, CStr, CString};
use std::io::{Read, Write};
use std::net::TcpStream;
use std::ptr;

use rasterize_core::ffi_agent::{
    rz_agent_server_start, rz_agent_server_stop, rz_agent_string_create,
};
use serde_json::{json, Value};

/// Test handler: echoes the tool name and arguments back as a text block;
/// the tool name "fail" exercises the NULL (handler failure) path.
unsafe extern "C" fn echo_handler(
    _context: *mut c_void,
    tool_name: *const c_char,
    arguments_json: *const c_char,
) -> *mut c_char {
    let name = unsafe { CStr::from_ptr(tool_name) }.to_str().unwrap();
    let arguments = unsafe { CStr::from_ptr(arguments_json) }.to_str().unwrap();
    if name == "fail" {
        return ptr::null_mut();
    }
    let result = json!({
        "content": [{"type": "text", "text": format!("{name}:{arguments}")}],
        "isError": false,
    });
    let result = CString::new(result.to_string()).unwrap();
    unsafe { rz_agent_string_create(result.as_ptr()) }
}

const TOOLS: &str = r#"[
  {"name": "echo", "description": "Echoes.",
   "inputSchema": {"type": "object", "properties": {}}}
]"#;

fn start_server() -> u16 {
    let name = CString::new("rasterize-test").unwrap();
    let version = CString::new("0.0.0").unwrap();
    let tools = CString::new(TOOLS).unwrap();
    let mut err: *mut c_char = ptr::null_mut();
    let port = unsafe {
        rz_agent_server_start(
            0,
            name.as_ptr(),
            version.as_ptr(),
            tools.as_ptr(),
            echo_handler,
            ptr::null_mut(),
            &mut err,
        )
    };
    assert!(err.is_null(), "unexpected error: {}", unsafe {
        CStr::from_ptr(err).to_string_lossy()
    });
    assert_ne!(port, 0);
    port
}

/// Sends one HTTP request and returns (status code, body).
fn http(port: u16, method: &str, body: &str) -> (u16, String) {
    let mut stream = TcpStream::connect(("127.0.0.1", port)).unwrap();
    let request = format!(
        "{method} /mcp HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\n\
         Content-Type: application/json\r\n\
         Accept: application/json, text/event-stream\r\n\
         Content-Length: {}\r\nConnection: close\r\n\r\n{body}",
        body.len()
    );
    stream.write_all(request.as_bytes()).unwrap();
    let mut response = String::new();
    stream.read_to_string(&mut response).unwrap();
    let status: u16 = response
        .split_whitespace()
        .nth(1)
        .and_then(|s| s.parse().ok())
        .expect("status line");
    let body = response
        .split_once("\r\n\r\n")
        .map(|(_, b)| b.to_string())
        .unwrap_or_default();
    (status, body)
}

fn rpc(port: u16, message: Value) -> (u16, Value) {
    let (status, body) = http(port, "POST", &message.to_string());
    let parsed = if body.is_empty() {
        Value::Null
    } else {
        serde_json::from_str(&body).unwrap_or(Value::Null)
    };
    (status, parsed)
}

/// One test function: the server is process-global state (one per
/// process), so the protocol walk must be a single sequential scenario.
#[test]
fn mcp_session_over_streamable_http() {
    let port = start_server();

    // initialize negotiates a known protocol version verbatim.
    let (status, reply) = rpc(
        port,
        json!({"jsonrpc": "2.0", "id": 1, "method": "initialize",
               "params": {"protocolVersion": "2025-03-26",
                          "capabilities": {},
                          "clientInfo": {"name": "test", "version": "0"}}}),
    );
    assert_eq!(status, 200);
    assert_eq!(reply["result"]["protocolVersion"], "2025-03-26");
    assert_eq!(reply["result"]["serverInfo"]["name"], "rasterize-test");
    assert!(reply["result"]["capabilities"]["tools"].is_object());

    // An unknown requested version is answered with the newest supported.
    let (_, reply) = rpc(
        port,
        json!({"jsonrpc": "2.0", "id": 2, "method": "initialize",
               "params": {"protocolVersion": "1999-01-01"}}),
    );
    assert_eq!(reply["result"]["protocolVersion"], "2025-06-18");

    // Notifications get 202 with no body.
    let (status, reply) = rpc(
        port,
        json!({"jsonrpc": "2.0", "method": "notifications/initialized"}),
    );
    assert_eq!(status, 202);
    assert_eq!(reply, Value::Null);

    // ping.
    let (status, reply) = rpc(port, json!({"jsonrpc": "2.0", "id": 3, "method": "ping"}));
    assert_eq!(status, 200);
    assert!(reply["result"].is_object());

    // tools/list returns the catalog verbatim.
    let (status, reply) = rpc(
        port,
        json!({"jsonrpc": "2.0", "id": 4, "method": "tools/list"}),
    );
    assert_eq!(status, 200);
    assert_eq!(reply["result"]["tools"][0]["name"], "echo");

    // tools/call round-trips through the handler.
    let (status, reply) = rpc(
        port,
        json!({"jsonrpc": "2.0", "id": 5, "method": "tools/call",
               "params": {"name": "echo", "arguments": {"x": 1}}}),
    );
    assert_eq!(status, 200);
    assert_eq!(reply["result"]["content"][0]["text"], r#"echo:{"x":1}"#);
    assert_eq!(reply["result"]["isError"], false);

    // A handler failure surfaces as a JSON-RPC internal error.
    let (_, reply) = rpc(
        port,
        json!({"jsonrpc": "2.0", "id": 6, "method": "tools/call",
               "params": {"name": "fail"}}),
    );
    assert_eq!(reply["error"]["code"], -32603);

    // Missing tool name is invalid params.
    let (_, reply) = rpc(
        port,
        json!({"jsonrpc": "2.0", "id": 7, "method": "tools/call", "params": {}}),
    );
    assert_eq!(reply["error"]["code"], -32602);

    // Unknown method.
    let (_, reply) = rpc(
        port,
        json!({"jsonrpc": "2.0", "id": 8, "method": "resources/list"}),
    );
    assert_eq!(reply["error"]["code"], -32601);

    // Malformed JSON is a parse error over HTTP 400.
    let (status, body) = http(port, "POST", "{nope");
    assert_eq!(status, 400);
    assert!(body.contains("-32700"));

    // Batches are answered element-wise; notifications produce no entry.
    let (status, reply) = rpc(
        port,
        json!([
            {"jsonrpc": "2.0", "id": 9, "method": "ping"},
            {"jsonrpc": "2.0", "method": "notifications/initialized"},
            {"jsonrpc": "2.0", "id": 10, "method": "ping"}
        ]),
    );
    assert_eq!(status, 200);
    assert_eq!(reply.as_array().map(Vec::len), Some(2));

    // GET (no server-push stream) and DELETE (no sessions) are 405.
    assert_eq!(http(port, "GET", "").0, 405);
    assert_eq!(http(port, "DELETE", "").0, 405);

    // A second server cannot start while this one runs.
    let name = CString::new("second").unwrap();
    let version = CString::new("0").unwrap();
    let tools = CString::new("[]").unwrap();
    let mut err: *mut c_char = ptr::null_mut();
    let second = unsafe {
        rz_agent_server_start(
            0,
            name.as_ptr(),
            version.as_ptr(),
            tools.as_ptr(),
            echo_handler,
            ptr::null_mut(),
            &mut err,
        )
    };
    assert_eq!(second, 0);
    assert!(!err.is_null());
    unsafe { rasterize_core::ffi::rz_string_free(err) };

    // Stop, then the port refuses connections and a restart works.
    rz_agent_server_stop();
    assert!(TcpStream::connect(("127.0.0.1", port)).is_err());
    let port2 = start_server();
    let (status, _) = rpc(port2, json!({"jsonrpc": "2.0", "id": 11, "method": "ping"}));
    assert_eq!(status, 200);
    rz_agent_server_stop();
}

/// Catalog that is not a JSON array must be rejected at start.
#[test]
fn rejects_non_array_catalog() {
    let name = CString::new("bad").unwrap();
    let version = CString::new("0").unwrap();
    let tools = CString::new("{}").unwrap();
    let mut err: *mut c_char = ptr::null_mut();
    let port = unsafe {
        rz_agent_server_start(
            0,
            name.as_ptr(),
            version.as_ptr(),
            tools.as_ptr(),
            echo_handler,
            ptr::null_mut(),
            &mut err,
        )
    };
    // Either this runs before the big scenario grabs the slot (port 0 with
    // a catalog error) or after (already-running error) — both reject.
    assert_eq!(port, 0);
    assert!(!err.is_null());
    unsafe { rasterize_core::ffi::rz_string_free(err) };
}
