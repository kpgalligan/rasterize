//! C FFI for the embedded MCP agent server (`rz_agent_*` in the header).
//!
//! One server per process: `rz_agent_server_start` refuses to start a
//! second. The host's tool handler is a C function pointer invoked from
//! the server thread; its return value must come from
//! [`rz_agent_string_create`] so this side can reclaim the allocation.

use std::ffi::{c_char, c_void, CStr, CString};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::ptr;
use std::sync::Mutex;

use crate::agent::{self, AgentConfig, AgentServer};
use crate::ffi_util::{fallible_op, read_cstr};

/// C signature of the host tool handler. See the header for the contract.
pub type RzAgentToolHandler = unsafe extern "C" fn(
    context: *mut c_void,
    tool_name: *const c_char,
    arguments_json: *const c_char,
) -> *mut c_char;

/// The handler pointer and its context, made Send+Sync so a worker
/// thread may call them. The host guarantees the pair stays valid and
/// callable from any thread for the life of the server (or assistant)
/// it was registered with.
pub(crate) struct HostHandler {
    pub(crate) handler: RzAgentToolHandler,
    pub(crate) context: *mut c_void,
}
unsafe impl Send for HostHandler {}
unsafe impl Sync for HostHandler {}

impl HostHandler {
    pub(crate) fn call(&self, name: &str, arguments: &str) -> Option<String> {
        let name = CString::new(name.replace('\0', " ")).ok()?;
        let arguments = CString::new(arguments.replace('\0', " ")).ok()?;
        let raw = unsafe { (self.handler)(self.context, name.as_ptr(), arguments.as_ptr()) };
        if raw.is_null() {
            return None;
        }
        // Reclaims the rz_agent_string_create allocation.
        let owned = unsafe { CString::from_raw(raw) };
        owned.into_string().ok()
    }
}

static SERVER: Mutex<Option<AgentServer>> = Mutex::new(None);

/// Allocates a NUL-terminated copy of `s` owned by this library, for tool
/// handlers to return. Never freed by the caller: ownership passes back
/// across the handler return.
///
/// # Safety
/// `s` must be NULL or a valid NUL-terminated C string.
#[no_mangle]
pub unsafe extern "C" fn rz_agent_string_create(s: *const c_char) -> *mut c_char {
    if s.is_null() {
        return ptr::null_mut();
    }
    let bytes = unsafe { CStr::from_ptr(s) }.to_bytes().to_vec();
    match CString::new(bytes) {
        Ok(owned) => owned.into_raw(),
        Err(_) => ptr::null_mut(),
    }
}

/// Starts the embedded MCP server on 127.0.0.1 (`port` 0 picks an
/// ephemeral port) and returns the bound port, or 0 on failure with a
/// message through `err_out`. `tools_json` must be the `tools/list`
/// catalog as a JSON array. `handler` is called from the server thread
/// for every `tools/call`; it must return a CallToolResult JSON object
/// allocated with [`rz_agent_string_create`], or NULL for handler failure.
///
/// # Safety
/// String arguments must be valid NUL-terminated C strings; `err_out`
/// must be NULL or a valid pointer to writable `*mut c_char`; `handler`
/// and `context` must remain valid and callable from any thread until
/// `rz_agent_server_stop` returns.
#[no_mangle]
pub unsafe extern "C" fn rz_agent_server_start(
    port: u16,
    server_name: *const c_char,
    server_version: *const c_char,
    tools_json: *const c_char,
    handler: RzAgentToolHandler,
    context: *mut c_void,
    err_out: *mut *mut c_char,
) -> u16 {
    let body = || {
        let name = unsafe { read_cstr(server_name, "server_name") }?;
        let version = unsafe { read_cstr(server_version, "server_version") }?;
        let tools_text = unsafe { read_cstr(tools_json, "tools_json") }?;
        let tools: serde_json::Value = serde_json::from_str(&tools_text)
            .map_err(|e| format!("tools_json is not valid JSON: {e}"))?;

        let mut slot = SERVER
            .lock()
            .map_err(|_| "server lock poisoned".to_string())?;
        if slot.is_some() {
            return Err("agent server already running".to_string());
        }
        let host = HostHandler { handler, context };
        let config = AgentConfig {
            name,
            version,
            tools,
            handler: Box::new(move |tool, arguments| host.call(tool, arguments)),
        };
        let (bound, server) = agent::start(port, config)?;
        *slot = Some(server);
        Ok(bound)
    };
    unsafe {
        fallible_op(
            err_out,
            "panic while starting agent server",
            0,
            body,
            |bound| bound,
        )
    }
}

/// Stops the embedded MCP server and waits for its thread to exit. Safe
/// to call when no server is running. After this returns, the handler
/// and context passed to start are no longer used.
#[no_mangle]
pub extern "C" fn rz_agent_server_stop() {
    let server = catch_unwind(|| SERVER.lock().ok().and_then(|mut slot| slot.take()));
    if let Ok(Some(server)) = server {
        let _ = catch_unwind(AssertUnwindSafe(|| server.shutdown()));
    }
}
