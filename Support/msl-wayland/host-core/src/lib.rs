use serde::Serialize;
use std::collections::HashMap;
use std::ffi::{c_char, c_void, CStr, CString};
use std::sync::mpsc::{self, Receiver, Sender};
use std::sync::{Arc, Mutex};
use std::thread::{self, JoinHandle};

#[cfg(feature = "real-smithay")]
use smithay as _;

#[repr(C)]
pub struct WaylandCoreCallbacks {
    pub on_frame: Option<extern "C" fn(*const u8, usize, *mut c_void)>,
    pub on_ime_state: Option<extern "C" fn(*const u8, usize, *mut c_void)>,
    pub on_log: Option<extern "C" fn(*const c_char, *mut c_void)>,
    pub on_exit: Option<extern "C" fn(i32, *mut c_void)>,
}

#[derive(Clone)]
struct CallbackSink {
    callbacks: Arc<WaylandCoreCallbacks>,
    user_data: usize,
}

impl CallbackSink {
    fn log(&self, message: &str) {
        if let Some(callback) = self.callbacks.on_log {
            if let Ok(c_string) = CString::new(message) {
                callback(c_string.as_ptr(), self.user_data as *mut c_void);
            }
        }
    }

    fn emit_frame(&self, session_id: &str, width: i32, height: i32) {
        #[derive(Serialize)]
        struct DamageRect {
            x: i32,
            y: i32,
            width: i32,
            height: i32,
        }
        #[derive(Serialize)]
        struct FrameEnvelope<'a> {
            kind: &'static str,
            frame: FramePayload<'a>,
        }
        #[derive(Serialize)]
        struct FramePayload<'a> {
            #[serde(rename = "sessionId")]
            session_id: &'a str,
            width: i32,
            height: i32,
            stride: i32,
            #[serde(rename = "pixelFormat")]
            pixel_format: &'static str,
            #[serde(rename = "damageRects")]
            damage_rects: Vec<DamageRect>,
            #[serde(rename = "dataBase64")]
            data_base64: String,
            #[serde(rename = "epochMs")]
            epoch_ms: i64,
        }
        if let Some(callback) = self.callbacks.on_frame {
            let width = width.max(1);
            let height = height.max(1);
            let stride = width * 4;
            let mut pixels = vec![0_u8; (stride * height) as usize];
            for y in 0..height {
                for x in 0..width {
                    let offset = (y * stride + x * 4) as usize;
                    pixels[offset] = (x % 255) as u8;
                    pixels[offset + 1] = (y % 255) as u8;
                    pixels[offset + 2] = 0x66;
                    pixels[offset + 3] = 0xff;
                }
            }
            let envelope = FrameEnvelope {
                kind: "frame",
                frame: FramePayload {
                    session_id,
                    width,
                    height,
                    stride,
                    pixel_format: "bgra8888",
                    damage_rects: vec![DamageRect { x: 0, y: 0, width, height }],
                    data_base64: base64_encode(&pixels),
                    epoch_ms: epoch_ms(),
                },
            };
            if let Ok(data) = serde_json::to_vec(&envelope) {
                callback(data.as_ptr(), data.len(), self.user_data as *mut c_void);
            }
        }
    }

    fn emit_ime_state(&self, payload: &[u8]) {
        if let Some(callback) = self.callbacks.on_ime_state {
            callback(payload.as_ptr(), payload.len(), self.user_data as *mut c_void);
        }
    }

    fn exit(&self, code: i32) {
        if let Some(callback) = self.callbacks.on_exit {
            callback(code, self.user_data as *mut c_void);
        }
    }
}

struct SessionState {
    width: i32,
    height: i32,
}

enum Command {
    Start,
    Stop,
    Attach(String),
    Detach(String),
    Geometry(String, i32, i32),
    TextInput(Vec<u8>),
}

pub struct MSLWaylandCoreHandle {
    sink: CallbackSink,
    tx: Sender<Command>,
    sessions: Arc<Mutex<HashMap<String, SessionState>>>,
    worker: Option<JoinHandle<()>>,
}

#[no_mangle]
pub extern "C" fn core_create(
    callbacks: *const WaylandCoreCallbacks,
    user_data: *mut c_void,
) -> *mut MSLWaylandCoreHandle {
    if callbacks.is_null() {
        return std::ptr::null_mut();
    }
    let callbacks = unsafe { Arc::new(std::ptr::read(callbacks)) };
    let sink = CallbackSink {
        callbacks,
        user_data: user_data as usize,
    };
    let (tx, rx) = mpsc::channel();
    let sessions = Arc::new(Mutex::new(HashMap::new()));
    let worker_sessions = sessions.clone();
    let worker_sink = sink.clone();
    let worker = thread::Builder::new()
        .name("msl-wayland-core".to_string())
        .spawn(move || worker_main(worker_sink, worker_sessions, rx))
        .ok();

    Box::into_raw(Box::new(MSLWaylandCoreHandle {
        sink,
        tx,
        sessions,
        worker,
    }))
}

#[no_mangle]
pub extern "C" fn core_start(handle: *mut MSLWaylandCoreHandle) -> bool {
    with_handle(handle, |handle| handle.tx.send(Command::Start).is_ok()).unwrap_or(false)
}

#[no_mangle]
pub extern "C" fn core_stop(handle: *mut MSLWaylandCoreHandle) {
    let _ = with_handle(handle, |handle| handle.tx.send(Command::Stop));
}

#[no_mangle]
pub extern "C" fn core_destroy(handle: *mut MSLWaylandCoreHandle) {
    if handle.is_null() {
        return;
    }
    let mut boxed = unsafe { Box::from_raw(handle) };
    let _ = boxed.tx.send(Command::Stop);
    if let Some(worker) = boxed.worker.take() {
        let _ = worker.join();
    }
}

#[no_mangle]
pub extern "C" fn core_attach_session(handle: *mut MSLWaylandCoreHandle, session_id: *const c_char) -> bool {
    with_handle(handle, |handle| {
        c_str(session_id)
            .map(|session_id| handle.tx.send(Command::Attach(session_id)).is_ok())
            .unwrap_or(false)
    })
    .unwrap_or(false)
}

#[no_mangle]
pub extern "C" fn core_detach_session(handle: *mut MSLWaylandCoreHandle, session_id: *const c_char) {
    let _ = with_handle(handle, |handle| {
        if let Some(session_id) = c_str(session_id) {
            let _ = handle.tx.send(Command::Detach(session_id));
        }
    });
}

#[no_mangle]
pub extern "C" fn core_send_text_input_state(
    handle: *mut MSLWaylandCoreHandle,
    _session_id: *const c_char,
    bytes: *const u8,
    count: usize,
) {
    let _ = with_handle(handle, |handle| {
        if bytes.is_null() || count == 0 {
            return;
        }
        let payload = unsafe { std::slice::from_raw_parts(bytes, count) }.to_vec();
        let _ = handle.tx.send(Command::TextInput(payload));
    });
}

#[no_mangle]
pub extern "C" fn core_set_window_geometry(
    handle: *mut MSLWaylandCoreHandle,
    session_id: *const c_char,
    width: i32,
    height: i32,
) {
    let _ = with_handle(handle, |handle| {
        if let Some(session_id) = c_str(session_id) {
            let _ = handle.tx.send(Command::Geometry(session_id, width, height));
        }
    });
}

fn worker_main(
    sink: CallbackSink,
    sessions: Arc<Mutex<HashMap<String, SessionState>>>,
    rx: Receiver<Command>,
) {
    sink.log("msl-wayland-core thread started");
    while let Ok(command) = rx.recv() {
        match command {
            Command::Start => sink.log("core_start"),
            Command::Stop => {
                sink.log("core_stop");
                break;
            }
            Command::Attach(session_id) => {
                if let Ok(mut sessions) = sessions.lock() {
                    sessions.entry(session_id.clone()).or_insert(SessionState { width: 1280, height: 800 });
                }
                sink.log(&format!("attach_session {}", session_id));
                sink.emit_frame(&session_id, 1280, 800);
            }
            Command::Detach(session_id) => {
                if let Ok(mut sessions) = sessions.lock() {
                    sessions.remove(&session_id);
                }
                sink.log(&format!("detach_session {}", session_id));
            }
            Command::Geometry(session_id, width, height) => {
                if let Ok(mut sessions) = sessions.lock() {
                    sessions.insert(session_id.clone(), SessionState { width, height });
                }
                sink.emit_frame(&session_id, width, height);
            }
            Command::TextInput(payload) => {
                sink.emit_ime_state(&payload);
            }
        }
    }
    sink.exit(0);
}

fn with_handle<T>(
    handle: *mut MSLWaylandCoreHandle,
    body: impl FnOnce(&mut MSLWaylandCoreHandle) -> T,
) -> Option<T> {
    if handle.is_null() {
        return None;
    }
    Some(body(unsafe { &mut *handle }))
}

fn c_str(value: *const c_char) -> Option<String> {
    if value.is_null() {
        return None;
    }
    unsafe { CStr::from_ptr(value) }.to_str().ok().map(ToOwned::to_owned)
}

fn epoch_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|value| value.as_millis() as i64)
        .unwrap_or_default()
}

fn base64_encode(bytes: &[u8]) -> String {
    const TABLE: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::with_capacity(bytes.len().div_ceil(3) * 4);
    let mut index = 0;
    while index < bytes.len() {
        let b0 = bytes[index];
        let b1 = *bytes.get(index + 1).unwrap_or(&0);
        let b2 = *bytes.get(index + 2).unwrap_or(&0);
        let n = ((b0 as u32) << 16) | ((b1 as u32) << 8) | b2 as u32;
        out.push(TABLE[((n >> 18) & 0x3f) as usize] as char);
        out.push(TABLE[((n >> 12) & 0x3f) as usize] as char);
        out.push(if index + 1 < bytes.len() {
            TABLE[((n >> 6) & 0x3f) as usize] as char
        } else {
            '='
        });
        out.push(if index + 2 < bytes.len() {
            TABLE[(n & 0x3f) as usize] as char
        } else {
            '='
        });
        index += 3;
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;
    use std::time::Duration;

    #[derive(Default)]
    struct CallbackRecorder {
        frames: Mutex<Vec<String>>,
        ime_payloads: Mutex<Vec<Vec<u8>>>,
        logs: Mutex<Vec<String>>,
        exits: Mutex<Vec<i32>>,
    }

    extern "C" fn on_frame(bytes: *const u8, count: usize, user_data: *mut c_void) {
        let recorder = unsafe { &*(user_data as *const CallbackRecorder) };
        let payload = unsafe { std::slice::from_raw_parts(bytes, count) };
        recorder
            .frames
            .lock()
            .unwrap()
            .push(String::from_utf8_lossy(payload).into_owned());
    }

    extern "C" fn on_ime_state(bytes: *const u8, count: usize, user_data: *mut c_void) {
        let recorder = unsafe { &*(user_data as *const CallbackRecorder) };
        let payload = unsafe { std::slice::from_raw_parts(bytes, count) };
        recorder.ime_payloads.lock().unwrap().push(payload.to_vec());
    }

    extern "C" fn on_log(message: *const c_char, user_data: *mut c_void) {
        let recorder = unsafe { &*(user_data as *const CallbackRecorder) };
        let message = unsafe { CStr::from_ptr(message) }.to_string_lossy().into_owned();
        recorder.logs.lock().unwrap().push(message);
    }

    extern "C" fn on_exit(code: i32, user_data: *mut c_void) {
        let recorder = unsafe { &*(user_data as *const CallbackRecorder) };
        recorder.exits.lock().unwrap().push(code);
    }

    #[test]
    fn base64_encoder_matches_expected_padding() {
        assert_eq!(base64_encode(b""), "");
        assert_eq!(base64_encode(b"f"), "Zg==");
        assert_eq!(base64_encode(b"fo"), "Zm8=");
        assert_eq!(base64_encode(b"foo"), "Zm9v");
    }

    #[test]
    fn ffi_lifecycle_emits_frame_ime_and_exit() {
        let recorder = Box::new(CallbackRecorder::default());
        let recorder_ptr = Box::into_raw(recorder);
        let callbacks = WaylandCoreCallbacks {
            on_frame: Some(on_frame),
            on_ime_state: Some(on_ime_state),
            on_log: Some(on_log),
            on_exit: Some(on_exit),
        };

        let handle = core_create(&callbacks, recorder_ptr.cast());
        assert!(!handle.is_null());
        assert!(core_start(handle));

        let session = CString::new("session-a").unwrap();
        assert!(core_attach_session(handle, session.as_ptr()));
        core_set_window_geometry(handle, session.as_ptr(), 640, 480);
        core_send_text_input_state(handle, session.as_ptr(), b"{}".as_ptr(), 2);
        core_stop(handle);
        core_destroy(handle);

        std::thread::sleep(Duration::from_millis(25));

        let recorder = unsafe { Box::from_raw(recorder_ptr) };
        let frames = recorder.frames.lock().unwrap();
        let ime_payloads = recorder.ime_payloads.lock().unwrap();
        let logs = recorder.logs.lock().unwrap();
        let exits = recorder.exits.lock().unwrap();

        assert!(frames.iter().any(|frame| frame.contains("\"kind\":\"frame\"")));
        assert!(frames.iter().any(|frame| frame.contains("\"sessionId\":\"session-a\"")));
        assert_eq!(ime_payloads.first().cloned(), Some(b"{}".to_vec()));
        assert!(logs.iter().any(|line| line.contains("attach_session session-a")));
        assert_eq!(exits.as_slice(), &[0]);
    }
}
