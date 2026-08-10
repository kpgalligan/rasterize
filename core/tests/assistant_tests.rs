//! Integration tests for the built-in assistant, driven through the C
//! FFI with a scripted mock of the Anthropic Messages API.

use std::ffi::{c_char, c_void, CStr, CString};
use std::io::Read;
use std::ptr;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use rasterize_core::ffi_agent::rz_agent_string_create;
use rasterize_core::ffi_assistant::{rz_assistant_free, rz_assistant_new, rz_assistant_send};
use serde_json::{json, Value};

// ---- Mock Messages API ---------------------------------------------------

struct MockApi {
    port: u16,
    /// (x-api-key header, request body) per request, in order.
    requests: Arc<Mutex<Vec<(String, Value)>>>,
    server: Arc<tiny_http::Server>,
}

impl Drop for MockApi {
    fn drop(&mut self) {
        self.server.unblock();
    }
}

/// Serves the scripted (status, body) responses in order; 500 when the
/// script runs out.
fn start_mock(script: Vec<(u16, Value)>) -> MockApi {
    let server = Arc::new(tiny_http::Server::http("127.0.0.1:0").expect("bind mock server"));
    let port = server.server_addr().to_ip().expect("ip addr").port();
    let requests: Arc<Mutex<Vec<(String, Value)>>> = Arc::new(Mutex::new(Vec::new()));
    let accept = Arc::clone(&server);
    let seen = Arc::clone(&requests);
    std::thread::spawn(move || {
        let mut script = script.into_iter();
        for mut request in accept.incoming_requests() {
            let api_key = request
                .headers()
                .iter()
                .find(|h| h.field.equiv("x-api-key"))
                .map(|h| h.value.to_string())
                .unwrap_or_default();
            let mut body = String::new();
            let _ = request.as_reader().read_to_string(&mut body);
            let parsed: Value = serde_json::from_str(&body).unwrap_or(Value::Null);
            seen.lock().expect("requests lock").push((api_key, parsed));
            let (status, reply) = script
                .next()
                .unwrap_or((500, json!({"error": {"message": "script exhausted"}})));
            let _ = request.respond(
                tiny_http::Response::from_string(reply.to_string()).with_status_code(status),
            );
        }
    });
    MockApi {
        port,
        requests,
        server,
    }
}

// ---- FFI plumbing --------------------------------------------------------

/// Event sink: context is a `*const Mutex<Vec<String>>`.
unsafe extern "C" fn event_sink(context: *mut c_void, event_json: *const c_char) {
    let events = unsafe { &*(context as *const Mutex<Vec<String>>) };
    let event = unsafe { CStr::from_ptr(event_json) }
        .to_str()
        .expect("event utf8")
        .to_string();
    events.lock().expect("events lock").push(event);
}

/// Tool executor: "echo" returns text "echo:<args>", "render" returns an
/// image block, "fail" returns NULL.
unsafe extern "C" fn tool_executor(
    _context: *mut c_void,
    tool_name: *const c_char,
    arguments_json: *const c_char,
) -> *mut c_char {
    let name = unsafe { CStr::from_ptr(tool_name) }.to_str().unwrap();
    let arguments = unsafe { CStr::from_ptr(arguments_json) }.to_str().unwrap();
    let result = match name {
        "fail" => return ptr::null_mut(),
        "render" => json!({
            "content": [
                {"type": "image", "data": "aW1n", "mimeType": "image/png"},
                {"type": "text", "text": "rendered"},
            ],
            "isError": false,
        }),
        _ => json!({
            "content": [{"type": "text", "text": format!("echo:{arguments}")}],
            "isError": false,
        }),
    };
    let result = CString::new(result.to_string()).unwrap();
    unsafe { rz_agent_string_create(result.as_ptr()) }
}

const TOOLS: &str = r#"[
  {"name": "echo", "description": "Echoes.",
   "inputSchema": {"type": "object", "properties": {"x": {"type": "integer"}}}},
  {"name": "render", "description": "Renders.",
   "inputSchema": {"type": "object", "properties": {}}}
]"#;

struct Session {
    handle: *mut rasterize_core::assistant::Assistant,
    events: Box<Mutex<Vec<String>>>,
}

fn new_session(port: u16) -> Session {
    let events: Box<Mutex<Vec<String>>> = Box::new(Mutex::new(Vec::new()));
    let config = json!({
        "api_key": "test-key",
        "model": "test-model",
        "system": "You are a test.",
        "api_base": format!("http://127.0.0.1:{port}"),
        "max_tokens": 512,
    });
    let config = CString::new(config.to_string()).unwrap();
    let tools = CString::new(TOOLS).unwrap();
    let mut err: *mut c_char = ptr::null_mut();
    let handle = unsafe {
        rz_assistant_new(
            config.as_ptr(),
            tools.as_ptr(),
            tool_executor,
            ptr::null_mut(),
            event_sink,
            &*events as *const Mutex<Vec<String>> as *mut c_void,
            &mut err,
        )
    };
    assert!(err.is_null(), "unexpected error: {}", unsafe {
        CStr::from_ptr(err).to_string_lossy()
    });
    assert!(!handle.is_null());
    Session { handle, events }
}

impl Session {
    fn send(&self, text: &str) -> bool {
        let text = CString::new(text).unwrap();
        unsafe { rz_assistant_send(self.handle, text.as_ptr()) }
    }

    /// Waits until turn_finished arrives, then returns all events parsed.
    fn wait_turn(&self) -> Vec<Value> {
        let deadline = Instant::now() + Duration::from_secs(10);
        loop {
            {
                let events = self.events.lock().expect("events lock");
                if events.iter().any(|e| e.contains("turn_finished")) {
                    return events
                        .iter()
                        .map(|e| serde_json::from_str(e).expect("event json"))
                        .collect();
                }
            }
            assert!(Instant::now() < deadline, "turn never finished");
            std::thread::sleep(Duration::from_millis(20));
        }
    }

    fn clear_events(&self) {
        self.events.lock().expect("events lock").clear();
    }
}

impl Drop for Session {
    fn drop(&mut self) {
        unsafe { rz_assistant_free(self.handle) };
    }
}

fn kinds(events: &[Value]) -> Vec<String> {
    events
        .iter()
        .map(|e| e["type"].as_str().unwrap_or("?").to_string())
        .collect()
}

// ---- Tests ---------------------------------------------------------------

#[test]
fn tool_use_round_trip() {
    let mock = start_mock(vec![
        (
            200,
            json!({
                "content": [
                    {"type": "text", "text": "Let me check."},
                    {"type": "tool_use", "id": "tu_1", "name": "echo", "input": {"x": 1}},
                ],
                "stop_reason": "tool_use",
            }),
        ),
        (
            200,
            json!({"content": [{"type": "text", "text": "Done."}],
                   "stop_reason": "end_turn"}),
        ),
    ]);
    let session = new_session(mock.port);
    assert!(session.send("hello"));
    let events = session.wait_turn();
    assert_eq!(
        kinds(&events),
        [
            "turn_started",
            "assistant_text",
            "tool_call",
            "tool_result",
            "assistant_text",
            "turn_finished"
        ]
    );
    assert_eq!(events[1]["text"], "Let me check.");
    assert_eq!(events[2]["name"], "echo");
    assert_eq!(events[2]["arguments"]["x"], 1);
    assert_eq!(events[3]["is_error"], false);
    assert_eq!(events[4]["text"], "Done.");

    let requests = mock.requests.lock().expect("requests lock");
    assert_eq!(requests.len(), 2);
    let (key, first) = &requests[0];
    assert_eq!(key, "test-key");
    assert_eq!(first["model"], "test-model");
    assert_eq!(first["system"], "You are a test.");
    assert_eq!(first["tools"][0]["name"], "echo");
    assert!(first["tools"][0]["input_schema"].is_object());
    assert_eq!(first["messages"][0]["role"], "user");
    assert_eq!(first["messages"][0]["content"][0]["text"], "hello");

    // The follow-up carries the assistant tool_use and our tool_result.
    let (_, second) = &requests[1];
    let messages = second["messages"].as_array().unwrap();
    assert_eq!(messages.len(), 3);
    assert_eq!(messages[1]["role"], "assistant");
    assert_eq!(messages[2]["role"], "user");
    let result = &messages[2]["content"][0];
    assert_eq!(result["type"], "tool_result");
    assert_eq!(result["tool_use_id"], "tu_1");
    assert_eq!(result["content"][0]["text"], r#"echo:{"x":1}"#);
}

#[test]
fn api_error_surfaces_as_event() {
    let mock = start_mock(vec![(
        400,
        json!({"type": "error", "error": {"type": "invalid_request_error",
               "message": "bad tool schema"}}),
    )]);
    let session = new_session(mock.port);
    assert!(session.send("hello"));
    let events = session.wait_turn();
    assert_eq!(kinds(&events), ["turn_started", "error", "turn_finished"]);
    let message = events[1]["message"].as_str().unwrap();
    assert!(message.contains("400") && message.contains("bad tool schema"));
}

#[test]
fn executor_failure_reports_tool_error_and_loop_continues() {
    let mock = start_mock(vec![
        (
            200,
            json!({
                "content": [{"type": "tool_use", "id": "tu_9", "name": "fail", "input": {}}],
                "stop_reason": "tool_use",
            }),
        ),
        (
            200,
            json!({"content": [{"type": "text", "text": "Recovered."}],
                   "stop_reason": "end_turn"}),
        ),
    ]);
    let session = new_session(mock.port);
    assert!(session.send("go"));
    let events = session.wait_turn();
    let result = events.iter().find(|e| e["type"] == "tool_result").unwrap();
    assert_eq!(result["is_error"], true);
    let requests = mock.requests.lock().expect("requests lock");
    let (_, second) = &requests[1];
    assert_eq!(second["messages"][2]["content"][0]["is_error"], true);
}

#[test]
fn images_convert_and_older_ones_prune() {
    // Three rounds of the render tool in one turn: the fourth request may
    // keep only the newest two images; the oldest becomes a placeholder.
    let tool_round = |id: &str| {
        (
            200,
            json!({
                "content": [{"type": "tool_use", "id": id, "name": "render", "input": {}}],
                "stop_reason": "tool_use",
            }),
        )
    };
    let mock = start_mock(vec![
        tool_round("tu_a"),
        tool_round("tu_b"),
        tool_round("tu_c"),
        (
            200,
            json!({"content": [{"type": "text", "text": "Seen."}],
                   "stop_reason": "end_turn"}),
        ),
    ]);
    let session = new_session(mock.port);
    assert!(session.send("look"));
    session.wait_turn();

    let requests = mock.requests.lock().expect("requests lock");
    assert_eq!(requests.len(), 4);
    // Second request: image arrives in API format.
    let (_, second) = &requests[1];
    let image = &second["messages"][2]["content"][0]["content"][0];
    assert_eq!(image["type"], "image");
    assert_eq!(image["source"]["type"], "base64");
    assert_eq!(image["source"]["media_type"], "image/png");
    assert_eq!(image["source"]["data"], "aW1n");
    // Fourth request: three renders happened; only two images survive.
    let (_, fourth) = &requests[3];
    let text = fourth.to_string();
    assert_eq!(text.matches("\"type\":\"image\"").count(), 2);
    assert!(text.contains("earlier canvas render"));
}

#[test]
fn send_while_busy_is_rejected() {
    // A turn that stays in flight long enough to observe busy: script an
    // empty vec so the request 500s only after the mock's accept loop gets
    // it — still fast, so retry logic (2s sleep) keeps the turn alive.
    let mock = start_mock(vec![(529, json!({"error": {"message": "overloaded"}}))]);
    let session = new_session(mock.port);
    assert!(session.send("first"));
    // The 529 retry path sleeps 2s, so the turn is reliably still busy.
    std::thread::sleep(Duration::from_millis(300));
    assert!(!session.send("second"));
    session.wait_turn();
    session.clear_events();
    // After the turn ends, sending works again.
    assert!(session.send("third"));
    session.wait_turn();
}
