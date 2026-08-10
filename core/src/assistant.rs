//! The built-in AI assistant: a tool-use agent loop over the Anthropic
//! Messages API. One `Assistant` is one conversation. A turn runs on a
//! worker thread: it calls the API, executes any requested tools through
//! the host-supplied executor (the same tool surface the MCP server
//! exposes), feeds results back, and repeats until the model stops.
//! Progress is reported through an event sink as JSON objects:
//!
//!   {"type":"turn_started"}
//!   {"type":"assistant_text","text":...}
//!   {"type":"tool_call","name":...,"arguments":{...}}
//!   {"type":"tool_result","name":...,"is_error":bool,"summary":...}
//!   {"type":"error","message":...}
//!   {"type":"turn_finished"}
//!
//! The provider seam is `api_base` (default https://api.anthropic.com);
//! requests are plain non-streaming Messages API calls.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;
use std::time::Duration;

use serde_json::{json, Value};

/// Executes one tool call: (name, arguments JSON) -> MCP CallToolResult
/// JSON (`{"content": [...], "isError": bool}`); None = executor failure.
pub type ToolExecutor = Box<dyn Fn(&str, &str) -> Option<String> + Send + Sync>;

/// Receives event JSON strings, called from the worker thread.
pub type EventSink = Box<dyn Fn(&str) + Send + Sync>;

pub struct AssistantConfig {
    pub api_key: String,
    pub model: String,
    pub system: String,
    pub api_base: String,
    pub max_tokens: u64,
}

/// Newest rendered images kept verbatim in the conversation; older image
/// blocks are replaced by a placeholder so history (and request size)
/// does not grow by megabytes of base64 per render.
const MAX_HISTORY_IMAGES: usize = 2;

/// Hard ceiling on API-call rounds within one turn.
const MAX_ROUNDS: usize = 30;

pub struct Assistant {
    inner: Arc<Inner>,
    worker: Mutex<Option<JoinHandle<()>>>,
}

struct Inner {
    config: AssistantConfig,
    /// Anthropic-format tools array.
    tools: Value,
    execute: ToolExecutor,
    events: EventSink,
    history: Mutex<Vec<Value>>,
    busy: AtomicBool,
    cancel: AtomicBool,
}

impl Assistant {
    /// `tools_mcp` is the MCP-format catalog (name/description/inputSchema),
    /// converted here to the Messages API shape.
    pub fn new(
        config: AssistantConfig,
        tools_mcp: &Value,
        execute: ToolExecutor,
        events: EventSink,
    ) -> Result<Assistant, String> {
        let list = tools_mcp
            .as_array()
            .ok_or_else(|| "tools catalog must be a JSON array".to_string())?;
        let tools: Vec<Value> = list
            .iter()
            .map(|tool| {
                json!({
                    "name": tool.get("name").cloned().unwrap_or(Value::Null),
                    "description": tool.get("description").cloned().unwrap_or(Value::Null),
                    "input_schema": tool.get("inputSchema").cloned().unwrap_or(Value::Null),
                })
            })
            .collect();
        if config.api_key.is_empty() {
            return Err("api_key is empty".to_string());
        }
        if config.model.is_empty() {
            return Err("model is empty".to_string());
        }
        Ok(Assistant {
            inner: Arc::new(Inner {
                config,
                tools: Value::Array(tools),
                execute,
                events,
                history: Mutex::new(Vec::new()),
                busy: AtomicBool::new(false),
                cancel: AtomicBool::new(false),
            }),
            worker: Mutex::new(None),
        })
    }

    pub fn is_busy(&self) -> bool {
        self.inner.busy.load(Ordering::SeqCst)
    }

    /// Starts one turn. Returns false (and does nothing) while a turn is
    /// already running.
    pub fn send(&self, user_text: &str) -> bool {
        if self.inner.busy.swap(true, Ordering::SeqCst) {
            return false;
        }
        self.inner.cancel.store(false, Ordering::SeqCst);
        {
            let mut history = self.inner.history.lock().expect("history lock");
            push_user_text(&mut history, user_text);
        }
        let inner = Arc::clone(&self.inner);
        let handle = std::thread::spawn(move || {
            inner.run_turn();
            inner.busy.store(false, Ordering::SeqCst);
        });
        let mut worker = self.worker.lock().expect("worker lock");
        if let Some(previous) = worker.replace(handle) {
            let _ = previous.join(); // already finished: busy was false
        }
        true
    }

    /// Asks the running turn to stop at the next boundary (before the next
    /// API call or tool execution). The in-flight HTTP call is not aborted.
    pub fn cancel(&self) {
        self.inner.cancel.store(true, Ordering::SeqCst);
    }

    /// Cancels and waits for the worker to finish. After this returns the
    /// executor and event sink are no longer called.
    pub fn shutdown(&self) {
        self.cancel();
        let handle = self.worker.lock().expect("worker lock").take();
        if let Some(handle) = handle {
            let _ = handle.join();
        }
    }
}

/// Appends user text, merging into a trailing user message if present so
/// the history never holds consecutive same-role messages.
fn push_user_text(history: &mut Vec<Value>, text: &str) {
    let block = json!({"type": "text", "text": text});
    if let Some(last) = history.last_mut() {
        if last.get("role").and_then(Value::as_str) == Some("user") {
            if let Some(content) = last.get_mut("content").and_then(Value::as_array_mut) {
                content.push(block);
                return;
            }
        }
    }
    history.push(json!({"role": "user", "content": [block]}));
}

impl Inner {
    fn emit(&self, event: Value) {
        (self.events)(&event.to_string());
    }

    fn cancelled(&self) -> bool {
        self.cancel.load(Ordering::SeqCst)
    }

    fn run_turn(&self) {
        self.emit(json!({"type": "turn_started"}));
        for _ in 0..MAX_ROUNDS {
            if self.cancelled() {
                break;
            }
            let request = self.build_request();
            let response = match self.call_api(&request) {
                Ok(response) => response,
                Err(message) => {
                    self.emit(json!({"type": "error", "message": message}));
                    break;
                }
            };
            let content = response
                .get("content")
                .and_then(Value::as_array)
                .cloned()
                .unwrap_or_default();
            for block in &content {
                if block.get("type").and_then(Value::as_str) == Some("text") {
                    if let Some(text) = block.get("text").and_then(Value::as_str) {
                        if !text.is_empty() {
                            self.emit(json!({"type": "assistant_text", "text": text}));
                        }
                    }
                }
            }
            {
                let mut history = self.history.lock().expect("history lock");
                history.push(json!({"role": "assistant", "content": content}));
            }
            let stop_reason = response.get("stop_reason").and_then(Value::as_str);
            if stop_reason != Some("tool_use") {
                break;
            }
            let results = self.execute_tools(&content);
            let mut history = self.history.lock().expect("history lock");
            history.push(json!({"role": "user", "content": results}));
            if self.cancelled() {
                break; // history stays valid: tool_results were appended
            }
        }
        self.emit(json!({"type": "turn_finished"}));
    }

    /// Runs every tool_use block, emitting call/result events, and returns
    /// the tool_result blocks. After a cancel, remaining tools report a
    /// cancelled error instead of executing so the transcript stays valid.
    fn execute_tools(&self, content: &[Value]) -> Vec<Value> {
        let mut results = Vec::new();
        for block in content {
            if block.get("type").and_then(Value::as_str) != Some("tool_use") {
                continue;
            }
            let id = block.get("id").cloned().unwrap_or(Value::Null);
            let name = block
                .get("name")
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_string();
            let arguments = block.get("input").cloned().unwrap_or(json!({}));
            if self.cancelled() {
                results.push(json!({
                    "type": "tool_result", "tool_use_id": id,
                    "content": [{"type": "text", "text": "Cancelled by the user."}],
                    "is_error": true,
                }));
                continue;
            }
            self.emit(json!({"type": "tool_call", "name": name, "arguments": arguments}));
            let raw = (self.execute)(&name, &arguments.to_string());
            let (content_blocks, is_error, summary) = convert_tool_result(raw.as_deref());
            self.emit(json!({
                "type": "tool_result", "name": name,
                "is_error": is_error, "summary": summary,
            }));
            results.push(json!({
                "type": "tool_result", "tool_use_id": id,
                "content": content_blocks, "is_error": is_error,
            }));
        }
        results
    }

    fn build_request(&self) -> Value {
        let mut history = self.history.lock().expect("history lock");
        prune_history_images(&mut history);
        json!({
            "model": self.config.model,
            "max_tokens": self.config.max_tokens,
            "system": self.config.system,
            "tools": self.tools,
            "messages": *history,
        })
    }

    /// One Messages API call; retries once on rate-limit/overload/5xx.
    fn call_api(&self, request: &Value) -> Result<Value, String> {
        let url = format!("{}/v1/messages", self.config.api_base.trim_end_matches('/'));
        let agent = ureq::AgentBuilder::new()
            .timeout(Duration::from_secs(180))
            .build();
        let mut attempt = 0;
        loop {
            attempt += 1;
            let outcome = agent
                .post(&url)
                .set("x-api-key", &self.config.api_key)
                .set("anthropic-version", "2023-06-01")
                .set("content-type", "application/json")
                .send_string(&request.to_string());
            let retriable;
            let message = match outcome {
                Ok(response) => {
                    let body = response
                        .into_string()
                        .map_err(|e| format!("could not read the API response: {e}"))?;
                    return serde_json::from_str(&body)
                        .map_err(|e| format!("the API returned invalid JSON: {e}"));
                }
                Err(ureq::Error::Status(code, response)) => {
                    retriable = code == 429 || code == 529 || (500..600).contains(&code);
                    let body = response.into_string().unwrap_or_default();
                    api_error_message(code, &body)
                }
                Err(error) => {
                    retriable = true;
                    format!("could not reach the API: {error}")
                }
            };
            if attempt >= 2 || !retriable || self.cancelled() {
                return Err(message);
            }
            std::thread::sleep(Duration::from_secs(2));
        }
    }
}

/// Extracts the API's own error message when the body carries one.
fn api_error_message(code: u16, body: &str) -> String {
    let detail = serde_json::from_str::<Value>(body)
        .ok()
        .and_then(|v| v.get("error")?.get("message")?.as_str().map(str::to_owned))
        .unwrap_or_else(|| "no detail".to_string());
    format!("API error {code}: {detail}")
}

/// Converts an executor result (MCP CallToolResult JSON) into Messages
/// API tool_result content blocks plus (is_error, display summary).
fn convert_tool_result(raw: Option<&str>) -> (Vec<Value>, bool, String) {
    let failure = |message: &str| {
        (
            vec![json!({"type": "text", "text": message})],
            true,
            message.to_string(),
        )
    };
    let Some(raw) = raw else {
        return failure("The tool failed to execute.");
    };
    let Ok(parsed) = serde_json::from_str::<Value>(raw) else {
        return failure("The tool returned an unreadable result.");
    };
    let is_error = parsed
        .get("isError")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let mut blocks = Vec::new();
    let mut summary = String::new();
    for item in parsed
        .get("content")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
    {
        match item.get("type").and_then(Value::as_str) {
            Some("text") => {
                let text = item.get("text").and_then(Value::as_str).unwrap_or("");
                if summary.is_empty() {
                    summary = text.chars().take(200).collect();
                }
                blocks.push(json!({"type": "text", "text": text}));
            }
            Some("image") => {
                let media_type = item
                    .get("mimeType")
                    .and_then(Value::as_str)
                    .unwrap_or("image/png");
                let data = item.get("data").and_then(Value::as_str).unwrap_or("");
                if summary.is_empty() {
                    summary = "(image)".to_string();
                }
                blocks.push(json!({
                    "type": "image",
                    "source": {"type": "base64", "media_type": media_type, "data": data},
                }));
            }
            _ => {}
        }
    }
    if blocks.is_empty() {
        return failure("The tool returned no content.");
    }
    (blocks, is_error, summary)
}

/// Replaces all but the newest MAX_HISTORY_IMAGES image blocks (inside
/// user-role tool_result content) with a text placeholder, in place.
fn prune_history_images(history: &mut [Value]) {
    let mut seen = 0usize;
    for message in history.iter_mut().rev() {
        if message.get("role").and_then(Value::as_str) != Some("user") {
            continue;
        }
        let Some(content) = message.get_mut("content").and_then(Value::as_array_mut) else {
            continue;
        };
        for entry in content.iter_mut() {
            let Some(inner) = entry.get_mut("content").and_then(Value::as_array_mut) else {
                continue;
            };
            // Newest-first within a message is close enough: renders are
            // one image per tool_result in practice.
            for block in inner.iter_mut() {
                if block.get("type").and_then(Value::as_str) == Some("image") {
                    if seen < MAX_HISTORY_IMAGES {
                        seen += 1;
                    } else {
                        *block = json!({
                            "type": "text",
                            "text": "(an earlier canvas render was here; request a new \
                                     render if you need to see the current state)",
                        });
                    }
                }
            }
        }
    }
}
