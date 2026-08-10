//! C FFI for the built-in assistant (`rz_assistant_*` in the header).
//!
//! An assistant handle is one conversation. The tool handler is shared
//! with the MCP server contract (RzAgentToolHandler, returning strings
//! from rz_agent_string_create); events arrive on a worker thread as
//! JSON strings the host copies before returning.

use std::ffi::{c_char, c_void, CStr, CString};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::ptr;

use serde_json::Value;

use crate::assistant::{Assistant, AssistantConfig};
use crate::ffi_agent::{HostHandler, RzAgentToolHandler};

/// C signature of the event sink: receives each event as a JSON string.
/// Called from the assistant's worker thread; the string is only valid
/// for the duration of the call.
pub type RzAssistantEventHandler =
    unsafe extern "C" fn(context: *mut c_void, event_json: *const c_char);

/// Event handler + context, Send+Sync under the host's validity promise.
struct HostEvents {
    handler: RzAssistantEventHandler,
    context: *mut c_void,
}
unsafe impl Send for HostEvents {}
unsafe impl Sync for HostEvents {}

impl HostEvents {
    fn call(&self, event: &str) {
        let Ok(event) = CString::new(event.replace('\0', " ")) else {
            return;
        };
        unsafe { (self.handler)(self.context, event.as_ptr()) };
    }
}

unsafe fn set_err(err_out: *mut *mut c_char, msg: &str) {
    if err_out.is_null() {
        return;
    }
    let sanitized = msg.replace('\0', " ");
    let cstring = CString::new(sanitized)
        .unwrap_or_else(|_| CString::new("rasterize-core error").expect("static string"));
    unsafe {
        *err_out = cstring.into_raw();
    }
}

/// Creates an assistant conversation. `config_json` is an object with
/// api_key, model, system (all strings; required), and optional api_base
/// and max_tokens. `tools_json` is the MCP-format catalog array (same
/// format rz_agent_server_start takes). Returns NULL on failure with a
/// message through `err_out`.
///
/// # Safety
/// String arguments must be valid NUL-terminated C strings; `err_out`
/// must be NULL or a valid pointer to writable `*mut c_char`. Both
/// handler/context pairs must remain valid and callable from any thread
/// until `rz_assistant_free` returns.
#[no_mangle]
pub unsafe extern "C" fn rz_assistant_new(
    config_json: *const c_char,
    tools_json: *const c_char,
    tool_handler: RzAgentToolHandler,
    tool_context: *mut c_void,
    event_handler: RzAssistantEventHandler,
    event_context: *mut c_void,
    err_out: *mut *mut c_char,
) -> *mut Assistant {
    let outcome = catch_unwind(AssertUnwindSafe(|| {
        let read = |ptr: *const c_char, what: &str| -> Result<String, String> {
            if ptr.is_null() {
                return Err(format!("{what} is NULL"));
            }
            unsafe { CStr::from_ptr(ptr) }
                .to_str()
                .map(str::to_owned)
                .map_err(|_| format!("{what} is not valid UTF-8"))
        };
        let config: Value = serde_json::from_str(&read(config_json, "config_json")?)
            .map_err(|e| format!("config_json is not valid JSON: {e}"))?;
        let tools: Value = serde_json::from_str(&read(tools_json, "tools_json")?)
            .map_err(|e| format!("tools_json is not valid JSON: {e}"))?;
        let field = |key: &str| -> Result<String, String> {
            config
                .get(key)
                .and_then(Value::as_str)
                .map(str::to_owned)
                .ok_or_else(|| format!("config_json is missing \"{key}\""))
        };
        let config = AssistantConfig {
            api_key: field("api_key")?,
            model: field("model")?,
            system: field("system")?,
            api_base: config
                .get("api_base")
                .and_then(Value::as_str)
                .unwrap_or("https://api.anthropic.com")
                .to_string(),
            max_tokens: config
                .get("max_tokens")
                .and_then(Value::as_u64)
                .unwrap_or(4096),
        };
        let tools_host = HostHandler {
            handler: tool_handler,
            context: tool_context,
        };
        let events_host = HostEvents {
            handler: event_handler,
            context: event_context,
        };
        Assistant::new(
            config,
            &tools,
            Box::new(move |name, arguments| tools_host.call(name, arguments)),
            Box::new(move |event| events_host.call(event)),
        )
    }));
    match outcome {
        Ok(Ok(assistant)) => Box::into_raw(Box::new(assistant)),
        Ok(Err(msg)) => {
            unsafe { set_err(err_out, &msg) };
            ptr::null_mut()
        }
        Err(_) => {
            unsafe { set_err(err_out, "internal panic") };
            ptr::null_mut()
        }
    }
}

/// Starts one turn with the user's message. Returns false if a turn is
/// already running (nothing is queued), the handle is NULL, or the text
/// is invalid.
///
/// # Safety
/// `assistant` must be NULL or a live handle from rz_assistant_new;
/// `user_text` must be NULL or a valid NUL-terminated C string.
#[no_mangle]
pub unsafe extern "C" fn rz_assistant_send(
    assistant: *const Assistant,
    user_text: *const c_char,
) -> bool {
    if assistant.is_null() || user_text.is_null() {
        return false;
    }
    let assistant = unsafe { &*assistant };
    let Ok(text) = unsafe { CStr::from_ptr(user_text) }.to_str() else {
        return false;
    };
    catch_unwind(AssertUnwindSafe(|| assistant.send(text))).unwrap_or(false)
}

/// True while a turn is running.
///
/// # Safety
/// `assistant` must be NULL or a live handle from rz_assistant_new.
#[no_mangle]
pub unsafe extern "C" fn rz_assistant_is_busy(assistant: *const Assistant) -> bool {
    if assistant.is_null() {
        return false;
    }
    let assistant = unsafe { &*assistant };
    catch_unwind(AssertUnwindSafe(|| assistant.is_busy())).unwrap_or(false)
}

/// Asks the running turn to stop at the next tool/API boundary. The turn
/// still emits turn_finished when it winds down.
///
/// # Safety
/// `assistant` must be NULL or a live handle from rz_assistant_new.
#[no_mangle]
pub unsafe extern "C" fn rz_assistant_cancel(assistant: *const Assistant) {
    if assistant.is_null() {
        return;
    }
    let assistant = unsafe { &*assistant };
    let _ = catch_unwind(AssertUnwindSafe(|| assistant.cancel()));
}

/// Cancels any running turn, waits for the worker to finish, and frees
/// the handle. After this returns the handlers are never called again.
/// NULL is a safe no-op.
///
/// # Safety
/// `assistant` must be NULL or a live handle from rz_assistant_new,
/// and must not be used afterwards.
#[no_mangle]
pub unsafe extern "C" fn rz_assistant_free(assistant: *mut Assistant) {
    if assistant.is_null() {
        return;
    }
    let assistant = unsafe { Box::from_raw(assistant) };
    let _ = catch_unwind(AssertUnwindSafe(|| assistant.shutdown()));
}
