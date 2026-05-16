use serde::{Deserialize, Serialize};
use std::collections::hash_map::DefaultHasher;
use std::collections::HashMap;
use std::ffi::{c_char, c_void, CStr, CString};
use std::hash::{Hash, Hasher};
use std::io::{Read, Write};
use std::os::fd::FromRawFd;
use std::ptr;
use std::sync::mpsc::{self, Receiver, Sender};
use std::sync::{Arc, Mutex, OnceLock};
use std::thread::{self, JoinHandle};

#[cfg(feature = "real-smithay")]
use smithay as _;

#[repr(C)]
pub struct WaylandCoreCallbacks {
    pub on_frame: Option<extern "C" fn(*const u8, usize, *mut c_void)>,
    pub on_ime_state: Option<extern "C" fn(*const u8, usize, *mut c_void)>,
    pub on_log: Option<extern "C" fn(*const c_char, *mut c_void)>,
    pub on_exit: Option<extern "C" fn(i32, *mut c_void)>,
    pub on_frame_shared: Option<extern "C" fn(*const u8, usize, *mut c_void)>,
    pub on_cursor: Option<extern "C" fn(*const u8, usize, *mut c_void)>,
    pub on_window_event: Option<extern "C" fn(*const u8, usize, *mut c_void)>,
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

    fn emit_shm_frame(&self, frame: ExtractedShmFrame) {
        if let Some(callback) = self.callbacks.on_frame_shared {
            match write_shared_frame(&frame) {
                Ok(shared_frame) => {
                    self.log(&format!(
                        "shared_frame_callback_emit session={} shm={} width={} height={} slot={} generation={}",
                        shared_frame.session_id,
                        shared_frame.shm_name,
                        shared_frame.width,
                        shared_frame.height,
                        shared_frame.slot,
                        shared_frame.generation
                    ));
                    let envelope = SharedFrameEnvelope {
                        kind: "frame",
                        shared_frame,
                    };
                    match serde_json::to_vec(&envelope) {
                        Ok(data) => callback(data.as_ptr(), data.len(), self.user_data as *mut c_void),
                        Err(error) => self.log(&format!("shared_frame_metadata_encode_failed error={error}")),
                    }
                    return;
                }
                Err(error) => {
                    self.log(&format!("shared_frame_write_failed error={error} fallback=json"));
                }
            }
        }

        if let Some(callback) = self.callbacks.on_frame {
            self.log(&format!(
                "frame_callback_emit session={} width={} height={}",
                frame.session_id, frame.width, frame.height
            ));
            let envelope = FrameEnvelope {
                kind: "frame",
                frame: FramePayload {
                    session_id: &frame.session_id,
                    width: frame.width,
                    height: frame.height,
                    stride: frame.stride,
                    pixel_format: frame.pixel_format.as_str(),
                    damage_rects: frame.damage_rects,
                    data_base64: base64_encode(&frame.pixels),
                    epoch_ms: epoch_ms(),
                },
            };
            if let Ok(data) = serde_json::to_vec(&envelope) {
                write_frame_snapshot(&frame.session_id, &data);
                callback(data.as_ptr(), data.len(), self.user_data as *mut c_void);
            }
        } else {
            self.log(&format!(
                "frame_callback_missing session={} width={} height={}",
                frame.session_id, frame.width, frame.height
            ));
        }
    }

    fn emit_ime_state(&self, payload: &[u8]) {
        if let Some(callback) = self.callbacks.on_ime_state {
            callback(
                payload.as_ptr(),
                payload.len(),
                self.user_data as *mut c_void,
            );
        }
    }

    fn emit_cursor(&self, cursor: CursorPayload) {
        let envelope = CursorEnvelope {
            kind: "cursor",
            cursor,
        };
        match serde_json::to_vec(&envelope) {
            Ok(data) => {
                if let Some(callback) = self.callbacks.on_cursor {
                    callback(data.as_ptr(), data.len(), self.user_data as *mut c_void);
                }
            }
            Err(error) => self.log(&format!("cursor_payload_encode_failed error={error}")),
        }
    }

    fn emit_window_event(&self, event: WindowEventPayload) {
        let envelope = WindowEventEnvelope {
            kind: "windowEvent",
            window_event: event,
        };
        match serde_json::to_vec(&envelope) {
            Ok(data) => {
                if let Some(callback) = self.callbacks.on_window_event {
                    callback(data.as_ptr(), data.len(), self.user_data as *mut c_void);
                }
            }
            Err(error) => self.log(&format!("window_event_encode_failed error={error}")),
        }
    }

    fn exit(&self, code: i32) {
        if let Some(callback) = self.callbacks.on_exit {
            callback(code, self.user_data as *mut c_void);
        }
    }
}

fn write_frame_snapshot(session_id: &str, data: &[u8]) {
    let Ok(dir) = std::env::var("MSL_WAYLAND_FRAME_DIR") else {
        return;
    };
    let name = sanitize_snapshot_name(session_id);
    let path = std::path::Path::new(&dir).join(format!("{}.json", name));
    if std::fs::create_dir_all(&dir).is_ok() {
        let _ = std::fs::write(path, data);
    }
}

fn sanitize_snapshot_name(value: &str) -> String {
    value
        .chars()
        .map(|ch| {
            if ch.is_ascii_alphanumeric() || ch == '-' || ch == '_' || ch == '.' {
                ch
            } else {
                '_'
            }
        })
        .collect()
}

#[derive(Clone, Copy, Debug, Serialize)]
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
    pixel_format: &'a str,
    #[serde(rename = "damageRects")]
    damage_rects: Vec<DamageRect>,
    #[serde(rename = "dataBase64")]
    data_base64: String,
    #[serde(rename = "epochMs")]
    epoch_ms: i64,
}

#[derive(Serialize)]
struct SharedFrameEnvelope {
    kind: &'static str,
    #[serde(rename = "sharedFrame")]
    shared_frame: SharedFramePayload,
}

#[derive(Serialize)]
struct SharedFramePayload {
    #[serde(rename = "sessionId")]
    session_id: String,
    #[serde(rename = "shmName")]
    shm_name: String,
    width: i32,
    height: i32,
    stride: i32,
    #[serde(rename = "pixelFormat")]
    pixel_format: &'static str,
    #[serde(rename = "damageRects")]
    damage_rects: Vec<DamageRect>,
    slot: u32,
    #[serde(rename = "slotOffset")]
    slot_offset: usize,
    #[serde(rename = "slotSize")]
    slot_size: usize,
    #[serde(rename = "mappedSize")]
    mapped_size: usize,
    generation: u64,
    #[serde(rename = "layoutGeneration")]
    layout_generation: u64,
    #[serde(rename = "epochMs")]
    epoch_ms: i64,
}

#[derive(Serialize)]
struct CursorEnvelope {
    kind: &'static str,
    cursor: CursorPayload,
}

#[derive(Serialize)]
struct CursorPayload {
    #[serde(rename = "sessionId")]
    session_id: String,
    width: i32,
    height: i32,
    stride: i32,
    #[serde(rename = "hotspotX")]
    hotspot_x: i32,
    #[serde(rename = "hotspotY")]
    hotspot_y: i32,
    #[serde(rename = "pixelFormat")]
    pixel_format: &'static str,
    #[serde(rename = "dataBase64")]
    data_base64: String,
    #[serde(rename = "epochMs")]
    epoch_ms: i64,
}

#[derive(Serialize)]
struct WindowEventEnvelope {
    kind: &'static str,
    #[serde(rename = "windowEvent")]
    window_event: WindowEventPayload,
}

#[derive(Serialize)]
struct WindowEventPayload {
    #[serde(rename = "sessionId")]
    session_id: String,
    #[serde(rename = "eventType")]
    event_type: &'static str,
    title: Option<String>,
    #[serde(rename = "appId")]
    app_id: Option<String>,
    serial: Option<u32>,
    seat: Option<u32>,
    edge: Option<u32>,
    #[serde(rename = "pointerX")]
    pointer_x: Option<f64>,
    #[serde(rename = "pointerY")]
    pointer_y: Option<f64>,
    #[serde(rename = "epochMs")]
    epoch_ms: i64,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum ShmPixelFormat {
    Argb8888,
    Xrgb8888,
}

impl ShmPixelFormat {
    fn as_str(self) -> &'static str {
        "bgra8888"
    }
}

#[derive(Debug)]
struct ExtractedShmFrame {
    session_id: String,
    width: i32,
    height: i32,
    stride: i32,
    pixel_format: ShmPixelFormat,
    damage_rects: Vec<DamageRect>,
    pixels: Vec<u8>,
}

const SHARED_FRAME_MAGIC: u32 = 0x574C_534D;
const SHARED_FRAME_VERSION: u32 = 1;
const SHARED_FRAME_SLOTS: usize = 3;
const SHARED_FRAME_MAX_DAMAGE: usize = 64;

#[repr(C)]
#[derive(Clone, Copy)]
struct SharedFrameHeader {
    magic: u32,
    version: u32,
    header_size: u32,
    width: u32,
    height: u32,
    stride: u32,
    pixel_format: u32,
    slot_count: u32,
    current_slot: u32,
    damage_count: u32,
    reserved0: u64,
    frame_generation: u64,
    layout_generation: u64,
    slot_size: u64,
    slot_offsets: [u64; SHARED_FRAME_SLOTS],
    damage_rects: [SharedFrameDamageRect; SHARED_FRAME_MAX_DAMAGE],
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
struct SharedFrameDamageRect {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
}

struct SharedFrameBuffer {
    shm_name: String,
    ptr: usize,
    mapped_size: usize,
    slot_size: usize,
    generation: u64,
    layout_generation: u64,
    next_slot: usize,
}

impl SharedFrameBuffer {
    unsafe fn unmap_and_unlink(&self) {
        let _ = libc::munmap(self.ptr as *mut c_void, self.mapped_size);
        if let Ok(name) = CString::new(self.shm_name.clone()) {
            let _ = libc::shm_unlink(name.as_ptr());
        }
    }
}

static SHARED_FRAME_BUFFERS: OnceLock<Mutex<HashMap<String, SharedFrameBuffer>>> = OnceLock::new();

fn shared_frame_buffers() -> &'static Mutex<HashMap<String, SharedFrameBuffer>> {
    SHARED_FRAME_BUFFERS.get_or_init(|| Mutex::new(HashMap::new()))
}

fn cleanup_shared_frames() {
    if let Ok(mut buffers) = shared_frame_buffers().lock() {
        for (_, buffer) in buffers.drain() {
            unsafe { buffer.unmap_and_unlink() };
        }
    }
}

fn write_shared_frame(frame: &ExtractedShmFrame) -> Result<SharedFramePayload, String> {
    if frame.width <= 0 || frame.height <= 0 || frame.stride <= 0 {
        return Err("invalid shared frame geometry".to_string());
    }
    let required_slot_size = (frame.stride as usize)
        .checked_mul(frame.height as usize)
        .ok_or_else(|| "shared frame size overflow".to_string())?;
    if frame.pixels.len() < required_slot_size {
        return Err("shared frame payload too small".to_string());
    }

    let mut buffers = shared_frame_buffers()
        .lock()
        .map_err(|_| "shared frame lock poisoned".to_string())?;
    let recreate = buffers
        .get(&frame.session_id)
        .map(|buffer| buffer.slot_size < required_slot_size)
        .unwrap_or(true);
    if recreate {
        let layout_generation = buffers
            .get(&frame.session_id)
            .map(|buffer| buffer.layout_generation.saturating_add(1))
            .unwrap_or(1);
        if let Some(old) = buffers.remove(&frame.session_id) {
            unsafe { old.unmap_and_unlink() };
        }
        let buffer = create_shared_frame_buffer(&frame.session_id, required_slot_size, layout_generation)?;
        buffers.insert(frame.session_id.clone(), buffer);
    }

    let buffer = buffers
        .get_mut(&frame.session_id)
        .ok_or_else(|| "shared frame buffer missing after create".to_string())?;
    let slot = buffer.next_slot % SHARED_FRAME_SLOTS;
    buffer.next_slot = (slot + 1) % SHARED_FRAME_SLOTS;
    buffer.generation = buffer.generation.saturating_add(1);
    let generation = buffer.generation;
    let header_size = std::mem::size_of::<SharedFrameHeader>();
    let slot_offset = header_size + (slot * buffer.slot_size);
    unsafe {
        let slot_ptr = (buffer.ptr as *mut u8).add(slot_offset);
        ptr::copy_nonoverlapping(frame.pixels.as_ptr(), slot_ptr, required_slot_size);

        let header = &mut *(buffer.ptr as *mut SharedFrameHeader);
        header.magic = SHARED_FRAME_MAGIC;
        header.version = SHARED_FRAME_VERSION;
        header.header_size = header_size as u32;
        header.width = frame.width as u32;
        header.height = frame.height as u32;
        header.stride = frame.stride as u32;
        header.pixel_format = 1;
        header.slot_count = SHARED_FRAME_SLOTS as u32;
        header.current_slot = slot as u32;
        header.slot_size = buffer.slot_size as u64;
        header.layout_generation = buffer.layout_generation;
        for index in 0..SHARED_FRAME_SLOTS {
            header.slot_offsets[index] = (header_size + (index * buffer.slot_size)) as u64;
        }
        header.damage_rects = [SharedFrameDamageRect::default(); SHARED_FRAME_MAX_DAMAGE];
        let damage_count = frame.damage_rects.len().min(SHARED_FRAME_MAX_DAMAGE);
        header.damage_count = damage_count as u32;
        for (index, rect) in frame.damage_rects.iter().take(SHARED_FRAME_MAX_DAMAGE).enumerate() {
            header.damage_rects[index] = SharedFrameDamageRect {
                x: rect.x,
                y: rect.y,
                width: rect.width,
                height: rect.height,
            };
        }
        std::sync::atomic::fence(std::sync::atomic::Ordering::Release);
        ptr::write_volatile(&mut header.frame_generation, generation);
    }

    Ok(SharedFramePayload {
        session_id: frame.session_id.clone(),
        shm_name: buffer.shm_name.clone(),
        width: frame.width,
        height: frame.height,
        stride: frame.stride,
        pixel_format: frame.pixel_format.as_str(),
        damage_rects: frame.damage_rects.clone(),
        slot: slot as u32,
        slot_offset,
        slot_size: buffer.slot_size,
        mapped_size: buffer.mapped_size,
        generation,
        layout_generation: buffer.layout_generation,
        epoch_ms: epoch_ms(),
    })
}

fn create_shared_frame_buffer(
    session_id: &str,
    slot_size: usize,
    layout_generation: u64,
) -> Result<SharedFrameBuffer, String> {
    let header_size = std::mem::size_of::<SharedFrameHeader>();
    let mapped_size = header_size
        .checked_add(
            slot_size
                .checked_mul(SHARED_FRAME_SLOTS)
                .ok_or_else(|| "shared frame mapped size overflow".to_string())?,
        )
        .ok_or_else(|| "shared frame mapped size overflow".to_string())?;
    let shm_name = shared_frame_name(session_id);
    let c_name = CString::new(shm_name.clone()).map_err(|_| "invalid shm name".to_string())?;
    unsafe {
        let _ = libc::shm_unlink(c_name.as_ptr());
        let fd = libc::shm_open(c_name.as_ptr(), libc::O_CREAT | libc::O_RDWR, 0o600);
        if fd < 0 {
            return Err(format!("shm_open failed errno={}", errno()));
        }
        if libc::ftruncate(fd, mapped_size as libc::off_t) != 0 {
            let error = format!("ftruncate failed errno={}", errno());
            let _ = libc::close(fd);
            let _ = libc::shm_unlink(c_name.as_ptr());
            return Err(error);
        }
        let ptr = libc::mmap(
            ptr::null_mut(),
            mapped_size,
            libc::PROT_READ | libc::PROT_WRITE,
            libc::MAP_SHARED,
            fd,
            0,
        );
        let _ = libc::close(fd);
        if ptr == libc::MAP_FAILED {
            let error = format!("mmap failed errno={}", errno());
            let _ = libc::shm_unlink(c_name.as_ptr());
            return Err(error);
        }
        ptr::write_bytes(ptr as *mut u8, 0, mapped_size);
        let header = &mut *(ptr as *mut SharedFrameHeader);
        header.magic = SHARED_FRAME_MAGIC;
        header.version = SHARED_FRAME_VERSION;
        header.header_size = header_size as u32;
        header.slot_count = SHARED_FRAME_SLOTS as u32;
        header.slot_size = slot_size as u64;
        header.layout_generation = layout_generation;
        for index in 0..SHARED_FRAME_SLOTS {
            header.slot_offsets[index] = (header_size + (index * slot_size)) as u64;
        }
        Ok(SharedFrameBuffer {
            shm_name,
            ptr: ptr as usize,
            mapped_size,
            slot_size,
            generation: 0,
            layout_generation,
            next_slot: 0,
        })
    }
}

fn shared_frame_name(session_id: &str) -> String {
    let mut hasher = DefaultHasher::new();
    session_id.hash(&mut hasher);
    format!("/msl-wl-{}-{:016x}", unsafe { libc::getuid() }, hasher.finish())
}

fn errno() -> i32 {
    std::io::Error::last_os_error().raw_os_error().unwrap_or(0)
}

#[derive(Deserialize)]
#[serde(tag = "type")]
enum DisplayTransportMessage {
    #[serde(rename = "waylandBytes")]
    WaylandBytes {
        #[serde(rename = "dataBase64")]
        data_base64: String,
    },
    #[serde(rename = "shmPoolCreate")]
    ShmPoolCreate {
        #[serde(rename = "poolId")]
        pool_id: u32,
        size: usize,
        #[serde(rename = "dataBase64")]
        data_base64: String,
    },
    #[serde(rename = "shmPoolResize")]
    ShmPoolResize {
        #[serde(rename = "poolId")]
        pool_id: u32,
        size: usize,
        #[serde(rename = "dataBase64")]
        data_base64: String,
    },
    #[serde(rename = "shmFrame")]
    ShmFrame {
        #[serde(rename = "sessionId")]
        session_id: String,
        width: i32,
        height: i32,
        stride: i32,
        format: String,
        #[serde(rename = "damageRects")]
        damage_rects: Vec<TransportDamageRect>,
        #[serde(rename = "dataBase64")]
        data_base64: String,
    },
}

#[derive(Clone, Copy, Debug, Deserialize)]
struct TransportDamageRect {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
}

struct SessionState {
    width: i32,
    height: i32,
    display: Option<DisplayEndpoint>,
}

#[derive(Clone)]
struct DisplayEndpoint {
    stream: Arc<Mutex<std::fs::File>>,
    state: Arc<Mutex<MiniWaylandState>>,
}

#[derive(Default)]
struct MiniWaylandState {
    session_id: String,
    registry_ids: Vec<u32>,
    globals: Vec<WaylandGlobal>,
    objects: HashMap<u32, String>,
    object_versions: HashMap<u32, u32>,
    shm_pools: HashMap<u32, ShmPool>,
    shm_buffers: HashMap<u32, ShmBuffer>,
    surfaces: HashMap<u32, SurfaceState>,
    xdg_surfaces: HashMap<u32, u32>,
    xdg_toplevels: HashMap<u32, u32>,
    xdg_popups: HashMap<u32, u32>,
    subsurfaces: HashMap<u32, u32>,
    xdg_positioners: HashMap<u32, PositionerState>,
    text_inputs: HashMap<u32, TextInputState>,
    surface_frames: HashMap<u32, SurfaceFrame>,
    active_toplevel: Option<u32>,
    active_surface: Option<u32>,
    pointer_object: Option<u32>,
    keyboard_object: Option<u32>,
    pointer_entered_surface: Option<u32>,
    keyboard_focused_surface: Option<u32>,
    keyboard_modifiers: u32,
    desired_keyboard_focus: bool,
    last_keyboard_trace_id: Option<String>,
    last_key_serial: Option<u32>,
    last_keycode: Option<u32>,
    last_keyboard_drop_reason: Option<String>,
    pointer_x: f64,
    pointer_y: f64,
    cursor_surface: Option<u32>,
    cursor_hotspot_x: i32,
    cursor_hotspot_y: i32,
    closed_sessions: HashMap<String, &'static str>,
    serial: u32,
    raw_buffer: Vec<u8>,
}

#[derive(Clone, Debug, Default)]
struct TextInputState {
    seat_id: u32,
    enabled: bool,
    entered_surface: Option<u32>,
    surrounding_text: String,
    cursor_utf8_offset: i32,
    anchor_utf8_offset: i32,
    change_cause: u32,
    content_hint: u32,
    content_purpose: u32,
    cursor_rect: (i32, i32, i32, i32),
}

#[derive(Debug, Deserialize)]
struct TextInputEnvelope {
    #[serde(rename = "imeState")]
    ime_state: TextInputPayload,
}

#[derive(Debug, Deserialize)]
struct TextInputPayload {
    #[serde(rename = "sessionId")]
    session_id: String,
    #[serde(default)]
    enabled: bool,
    #[serde(rename = "surroundingText")]
    surrounding_text: String,
    #[serde(rename = "cursorUTF16Offset")]
    cursor_utf16_offset: usize,
    #[serde(rename = "anchorUTF16Offset")]
    anchor_utf16_offset: usize,
    preedit: Option<String>,
    committed: Option<String>,
    #[serde(rename = "deleteLeftUTF16Count", default)]
    delete_left_utf16_count: usize,
    #[serde(rename = "deleteRightUTF16Count", default)]
    delete_right_utf16_count: usize,
    #[serde(rename = "preeditCursorBeginUTF16", default)]
    preedit_cursor_begin_utf16: Option<usize>,
    #[serde(rename = "preeditCursorEndUTF16", default)]
    preedit_cursor_end_utf16: Option<usize>,
}

struct WaylandGlobal {
    name: u32,
    interface: &'static str,
    version: u32,
}

struct ShmPool {
    size: usize,
    data: Vec<u8>,
}

#[derive(Clone, Copy)]
struct ShmBuffer {
    pool_id: u32,
    offset: usize,
    width: i32,
    height: i32,
    stride: i32,
    format: ShmPixelFormat,
}

#[derive(Clone, Copy, Debug, Default)]
struct PositionerState {
    width: i32,
    height: i32,
    anchor_x: i32,
    anchor_y: i32,
    anchor_width: i32,
    anchor_height: i32,
    offset_x: i32,
    offset_y: i32,
}

#[derive(Clone, Debug)]
struct SurfaceFrame {
    width: i32,
    height: i32,
    stride: i32,
    format: ShmPixelFormat,
    pixels: Vec<u8>,
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
enum SurfaceRole {
    #[default]
    None,
    Root,
    Popup { parent_surface: u32, x: i32, y: i32 },
    Subsurface { parent_surface: u32, x: i32, y: i32 },
    Transient { parent_surface: u32 },
}

#[derive(Default)]
struct SurfaceState {
    attached_buffer: Option<u32>,
    pending_attach: PendingAttach,
    pending_damage: Vec<DamageRect>,
    pending_frame_callbacks: Vec<u32>,
    xdg_surface: Option<u32>,
    xdg_toplevel: Option<u32>,
    role: SurfaceRole,
    initial_configure_sent: bool,
    window_geometry: Option<WindowGeometry>,
}

#[derive(Clone, Copy, Debug)]
struct WindowGeometry {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
enum PendingAttach {
    #[default]
    Unchanged,
    Attach(Option<u32>),
}

enum Command {
    Start,
    Stop,
    Attach(String),
    AttachDisplay(String, i32),
    Detach(String),
    Geometry(String, i32, i32),
    Pointer(String, PointerCommand),
    Keyboard(String, KeyboardCommand),
    Focus(String, bool),
    Close(String),
    TextInput(String, Vec<u8>),
}

#[derive(Clone, Copy)]
struct PointerCommand {
    kind: i32,
    x: f64,
    y: f64,
    button: u32,
    axis_x: f64,
    axis_y: f64,
    modifiers: u32,
    timestamp_ms: u32,
}

#[derive(Clone)]
struct KeyboardCommand {
    kind: i32,
    keycode: u32,
    modifiers: u32,
    timestamp_ms: u32,
    trace_id: String,
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
    with_handle(handle, |handle| {
        let session_count = handle
            .sessions
            .lock()
            .map(|sessions| sessions.len())
            .unwrap_or_default();
        handle
            .sink
            .log(&format!("core_start_requested sessions={}", session_count));
        handle.tx.send(Command::Start).is_ok()
    })
    .unwrap_or(false)
}

#[no_mangle]
pub extern "C" fn core_stop(handle: *mut MSLWaylandCoreHandle) {
    let _ = with_handle(handle, |handle| {
        let session_count = handle
            .sessions
            .lock()
            .map(|sessions| sessions.len())
            .unwrap_or_default();
        handle
            .sink
            .log(&format!("core_stop_requested sessions={}", session_count));
        let _ = handle.tx.send(Command::Stop);
    });
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
pub extern "C" fn core_attach_session(
    handle: *mut MSLWaylandCoreHandle,
    session_id: *const c_char,
) -> bool {
    with_handle(handle, |handle| {
        c_str(session_id)
            .map(|session_id| handle.tx.send(Command::Attach(session_id)).is_ok())
            .unwrap_or(false)
    })
    .unwrap_or(false)
}

#[no_mangle]
pub extern "C" fn core_detach_session(
    handle: *mut MSLWaylandCoreHandle,
    session_id: *const c_char,
) {
    let _ = with_handle(handle, |handle| {
        if let Some(session_id) = c_str(session_id) {
            let _ = handle.tx.send(Command::Detach(session_id));
        }
    });
}

#[no_mangle]
pub extern "C" fn core_attach_display_fd(
    handle: *mut MSLWaylandCoreHandle,
    session_id: *const c_char,
    fd: i32,
) -> bool {
    with_handle(handle, |handle| {
        if fd < 0 {
            return false;
        }
        c_str(session_id)
            .map(|session_id| {
                handle
                    .tx
                    .send(Command::AttachDisplay(session_id, fd))
                    .is_ok()
            })
            .unwrap_or(false)
    })
    .unwrap_or(false)
}

#[no_mangle]
pub extern "C" fn core_send_text_input_state(
    handle: *mut MSLWaylandCoreHandle,
    session_id: *const c_char,
    bytes: *const u8,
    count: usize,
) {
    let _ = with_handle(handle, |handle| {
        if bytes.is_null() || count == 0 {
            return;
        }
        if let Some(session_id) = c_str(session_id) {
            let payload = unsafe { std::slice::from_raw_parts(bytes, count) }.to_vec();
            let _ = handle.tx.send(Command::TextInput(session_id, payload));
        }
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

#[no_mangle]
pub extern "C" fn core_send_pointer(
    handle: *mut MSLWaylandCoreHandle,
    session_id: *const c_char,
    kind: i32,
    x: f64,
    y: f64,
    button: u32,
    axis_x: f64,
    axis_y: f64,
    modifiers: u32,
    timestamp_ms: u32,
) {
    let _ = with_handle(handle, |handle| {
        if let Some(session_id) = c_str(session_id) {
            let _ = handle.tx.send(Command::Pointer(session_id.clone(), PointerCommand {
                kind,
                x,
                y,
                button,
                axis_x,
                axis_y,
                modifiers,
                timestamp_ms,
            }));
            handle
                .sink
                .log(&format!("core_send_pointer_requested session={}", session_id));
        }
    });
}

#[no_mangle]
pub extern "C" fn core_send_keyboard(
    handle: *mut MSLWaylandCoreHandle,
    session_id: *const c_char,
    kind: i32,
    keycode: u32,
    modifiers: u32,
    timestamp_ms: u32,
) {
    core_send_keyboard_trace(
        handle,
        session_id,
        kind,
        keycode,
        modifiers,
        timestamp_ms,
        ptr::null(),
    );
}

#[no_mangle]
pub extern "C" fn core_send_keyboard_trace(
    handle: *mut MSLWaylandCoreHandle,
    session_id: *const c_char,
    kind: i32,
    keycode: u32,
    modifiers: u32,
    timestamp_ms: u32,
    trace_id: *const c_char,
) {
    let _ = with_handle(handle, |handle| {
        if let Some(session_id) = c_str(session_id) {
            let trace_id = c_str(trace_id)
                .filter(|value| !value.is_empty())
                .unwrap_or_else(|| format!("host-key-{}-{}", timestamp_ms, keycode));
            let _ = handle.tx.send(Command::Keyboard(session_id.clone(), KeyboardCommand {
                kind,
                keycode,
                modifiers,
                timestamp_ms,
                trace_id: trace_id.clone(),
            }));
            handle
                .sink
                .log(&format!(
                    "core_send_keyboard_requested session={} trace_id={} kind={} keycode={} modifiers={} time={}",
                    session_id, trace_id, kind, keycode, modifiers, timestamp_ms
                ));
        }
    });
}

#[no_mangle]
pub extern "C" fn core_keyboard_debug_snapshot(
    handle: *mut MSLWaylandCoreHandle,
    session_id: *const c_char,
    buffer: *mut u8,
    buffer_len: usize,
) -> usize {
    if buffer.is_null() || buffer_len == 0 {
        return 0;
    }
    let mut json = String::from("{\"error\":\"unavailable\"}");
    let _ = with_handle(handle, |handle| {
        if let Some(session_id) = c_str(session_id) {
            let display = handle
                .sessions
                .lock()
                .ok()
                .and_then(|sessions| sessions.get(&session_id).and_then(|s| s.display.clone()));
            json = if let Some(display) = display {
                match display.state.lock() {
                    Ok(state) => format!(
                        "{{\"sessionId\":\"{}\",\"activeSurface\":\"{}\",\"keyboardObject\":\"{}\",\"keyboardFocusedSurface\":\"{}\",\"desiredKeyboardFocus\":\"{}\",\"lastKeyboardTraceId\":\"{}\",\"lastKeySerial\":\"{}\",\"lastKeycode\":\"{}\",\"lastKeyboardDropReason\":\"{}\"}}",
                        session_id,
                        state.active_surface.map(|value| value.to_string()).unwrap_or_default(),
                        state.keyboard_object.map(|value| value.to_string()).unwrap_or_default(),
                        state.keyboard_focused_surface.map(|value| value.to_string()).unwrap_or_default(),
                        state.desired_keyboard_focus,
                        state.last_keyboard_trace_id.clone().unwrap_or_default(),
                        state.last_key_serial.map(|value| value.to_string()).unwrap_or_default(),
                        state.last_keycode.map(|value| value.to_string()).unwrap_or_default(),
                        state.last_keyboard_drop_reason.clone().unwrap_or_default(),
                    ),
                    Err(_) => "{\"error\":\"state lock poisoned\"}".to_string(),
                }
            } else {
                format!("{{\"sessionId\":\"{}\",\"error\":\"no_display\"}}", session_id)
            };
        }
    });
    let bytes = json.as_bytes();
    let write_len = bytes.len().min(buffer_len.saturating_sub(1));
    unsafe {
        ptr::copy_nonoverlapping(bytes.as_ptr(), buffer, write_len);
        *buffer.add(write_len) = 0;
    }
    write_len
}

#[no_mangle]
pub extern "C" fn core_send_focus(
    handle: *mut MSLWaylandCoreHandle,
    session_id: *const c_char,
    focused: bool,
) {
    let _ = with_handle(handle, |handle| {
        if let Some(session_id) = c_str(session_id) {
            let _ = handle.tx.send(Command::Focus(session_id, focused));
        }
    });
}

#[no_mangle]
pub extern "C" fn core_request_toplevel_close(
    handle: *mut MSLWaylandCoreHandle,
    session_id: *const c_char,
) {
    let _ = with_handle(handle, |handle| {
        if let Some(session_id) = c_str(session_id) {
            let _ = handle.tx.send(Command::Close(session_id));
        }
    });
}

fn worker_main(
    sink: CallbackSink,
    sessions: Arc<Mutex<HashMap<String, SessionState>>>,
    rx: Receiver<Command>,
) {
    sink.log("msl-wayland-core thread started");
    sink.log("wayland_core_build_marker=fd-aware-keymap");
    while let Ok(command) = rx.recv() {
        match command {
            Command::Start => sink.log("core_start"),
            Command::Stop => {
                sink.log("core_stop");
                cleanup_shared_frames();
                break;
            }
            Command::Attach(session_id) => {
                if let Ok(mut sessions) = sessions.lock() {
                    sessions.entry(session_id.clone()).or_insert(SessionState {
                        width: 1280,
                        height: 800,
                        display: None,
                    });
                }
                sink.log(&format!("attach_session {}", session_id));
                sink.log("synthetic_frame_disabled reason=attach_session");
            }
            Command::AttachDisplay(session_id, fd) => {
                sink.log(&format!(
                    "attach_display_fd session={} fd={}",
                    session_id, fd
                ));
                let display_sink = sink.clone();
                let file = unsafe { std::fs::File::from_raw_fd(fd) };
                let stream = match file.try_clone() {
                    Ok(reader) => {
                        let stream = Arc::new(Mutex::new(file));
                        let mut state = MiniWaylandState::new();
                        state.session_id = session_id.clone();
                        let state = Arc::new(Mutex::new(state));
                        if let Ok(mut sessions) = sessions.lock() {
                            let session = sessions
                                .entry(session_id.clone())
                                .or_insert(SessionState {
                                    width: 1280,
                                    height: 800,
                                    display: None,
                                });
                            session.display = Some(DisplayEndpoint {
                                stream: stream.clone(),
                                state: state.clone(),
                            });
                        }
                        Some((reader, stream, state))
                    }
                    Err(error) => {
                        sink.log(&format!(
                            "attach_display_fd_clone_failed session={} error={}",
                            session_id, error
                        ));
                        None
                    }
                };
                let Some((reader, stream, state)) = stream else {
                    continue;
                };
                let _ = thread::Builder::new()
                    .name(format!("msl-wayland-display-{}", session_id))
                    .spawn(move || read_display_stream(display_sink, session_id, reader, stream, state));
            }
            Command::Detach(session_id) => {
                if let Ok(mut sessions) = sessions.lock() {
                    sessions.remove(&session_id);
                }
                sink.log(&format!("detach_session {}", session_id));
            }
            Command::Geometry(session_id, width, height) => {
                if let Ok(mut sessions) = sessions.lock() {
                    let session = sessions
                        .entry(session_id.clone())
                        .or_insert(SessionState {
                            width,
                            height,
                            display: None,
                        });
                    session.width = width.max(1);
                    session.height = height.max(1);
                    if let Some(display) = session.display.clone() {
                        let _ = send_configure_to_display(
                            &sink,
                            &display,
                            session.width,
                            session.height,
                        );
                    }
                }
                sink.log(&format!(
                    "geometry_updated session={} width={} height={} synthetic_frame_disabled=true",
                    session_id,
                    width.max(1),
                    height.max(1)
                ));
            }
            Command::Pointer(session_id, command) => {
                let display = sessions
                    .lock()
                    .ok()
                    .and_then(|sessions| sessions.get(&session_id).and_then(|s| s.display.clone()));
                if let Some(display) = display {
                    let _ = send_pointer_to_display(&sink, &display, command);
                } else {
                    sink.log(&format!("wayland_pointer_event_dropped session={} reason=no_display", session_id));
                }
            }
            Command::Keyboard(session_id, command) => {
                let display = sessions
                    .lock()
                    .ok()
                    .and_then(|sessions| sessions.get(&session_id).and_then(|s| s.display.clone()));
                if let Some(display) = display {
                    let _ = send_keyboard_to_display(&sink, &display, command);
                } else {
                    sink.log(&format!("wayland_keyboard_event_dropped session={} reason=no_display", session_id));
                }
            }
            Command::Focus(session_id, focused) => {
                let display = sessions
                    .lock()
                    .ok()
                    .and_then(|sessions| sessions.get(&session_id).and_then(|s| s.display.clone()));
                if let Some(display) = display {
                    let _ = send_focus_to_display(&sink, &display, focused);
                }
            }
            Command::Close(session_id) => {
                let display = sessions
                    .lock()
                    .ok()
                    .and_then(|sessions| sessions.get(&session_id).and_then(|s| s.display.clone()));
                if let Some(display) = display {
                    let _ = send_toplevel_close_to_display(&sink, &display);
                } else {
                    sink.log(&format!("wayland_toplevel_close_dropped session={} reason=no_display", session_id));
                }
            }
            Command::TextInput(session_id, payload) => {
                let display = sessions
                    .lock()
                    .ok()
                    .and_then(|sessions| sessions.get(&session_id).and_then(|s| s.display.clone()));
                if let Some(display) = display {
                    let _ = send_text_input_to_display(&sink, &display, &payload);
                } else {
                    sink.log(&format!("wayland_text_input_dropped session={} reason=no_display", session_id));
                }
            }
        }
    }
    sink.exit(0);
}

fn read_display_stream(
    sink: CallbackSink,
    session_id: String,
    mut reader: std::fs::File,
    stream: Arc<Mutex<std::fs::File>>,
    state: Arc<Mutex<MiniWaylandState>>,
) {
    let mut total = 0_u64;
    let mut buffer = [0_u8; 16 * 1024];
    let mut pending = Vec::<u8>::new();
    let mut first_byte_logged = false;
    sink.log(&format!("display_attached session={}", session_id));
    loop {
        match reader.read(&mut buffer) {
            Ok(0) => {
                sink.log(&format!(
                    "display_stream_closed session={} bytes={}",
                    session_id, total
                ));
                break;
            }
            Ok(count) => {
                if !first_byte_logged {
                    first_byte_logged = true;
                    sink.log(&format!(
                        "display_stream_first_bytes session={} count={}",
                        session_id, count
                    ));
                }
                total += count as u64;
                pending.extend_from_slice(&buffer[..count]);
                let parse_result = {
                    let mut wayland = state
                        .lock()
                        .map_err(|_| "wayland state lock poisoned".to_string());
                    let mut stream = stream
                        .lock()
                        .map_err(|_| "display stream lock poisoned".to_string());
                    match (&mut wayland, &mut stream) {
                        (Ok(wayland), Ok(stream)) => {
                            if looks_like_display_transport(&pending)
                                || looks_like_incomplete_display_transport(&pending)
                            {
                                drain_display_transport_messages(
                                    &sink,
                                    &session_id,
                                    stream,
                                    wayland,
                                    &mut pending,
                                )
                            } else {
                                drain_wayland_wire_messages(&sink, stream, wayland, &mut pending)
                            }
                        }
                        (Err(error), _) | (_, Err(error)) => Err(error.clone()),
                    }
                };
                match parse_result {
                    Ok(parsed) if parsed > 0 => {
                        sink.log(&format!(
                            "display_stream_messages session={} parsed={}",
                            session_id, parsed
                        ));
                    }
                    Ok(_) => {}
                    Err(err) => {
                        sink.log(&format!(
                            "display_stream_parse_error session={} err={}",
                            session_id, err
                        ));
                        pending.clear();
                        break;
                    }
                }
                sink.log(&format!(
                    "display_stream_bytes session={} count={} total={}",
                    session_id, count, total
                ));
            }
            Err(err) => {
                sink.log(&format!(
                    "display_stream_error session={} err={}",
                    session_id, err
                ));
                break;
            }
        }
    }
    if let Ok(mut wayland) = state.lock() {
        if wayland.active_surface.is_some() || !wayland.closed_sessions.contains_key(&session_id) {
            emit_window_event(&sink, &mut wayland, "closed", None, None);
            wayland.active_surface = None;
            wayland.active_toplevel = None;
        }
    }
}

fn drain_display_transport_messages(
    sink: &CallbackSink,
    fallback_session_id: &str,
    stream: &mut std::fs::File,
    wayland: &mut MiniWaylandState,
    pending: &mut Vec<u8>,
) -> Result<usize, String> {
    let mut parsed = 0;
    loop {
        if pending.len() < 4 {
            return Ok(parsed);
        }
        let frame_len =
            u32::from_le_bytes([pending[0], pending[1], pending[2], pending[3]]) as usize;
        if frame_len == 0 {
            pending.drain(..4);
            continue;
        }
        if frame_len > 64 * 1024 * 1024 {
            return Err(format!("display transport frame too large: {}", frame_len));
        }
        if pending.len() < 4 + frame_len {
            return Ok(parsed);
        }
        let payload = pending[4..4 + frame_len].to_vec();
        pending.drain(..4 + frame_len);
        let message = serde_json::from_slice::<DisplayTransportMessage>(&payload)
            .map_err(|e| format!("decode display transport json failed: {}", e))?;
        match message {
            DisplayTransportMessage::WaylandBytes { data_base64 } => {
                let mut bytes = base64_decode(&data_base64)?;
                sink.log(&format!("wayland_bytes_transport size={}", bytes.len()));
                wayland.raw_buffer.append(&mut bytes);
                let mut empty = Vec::new();
                let parsed = drain_wayland_wire_messages(sink, stream, wayland, &mut empty)?;
                if parsed > 0 {
                    sink.log(&format!("wayland_bytes_parsed count={}", parsed));
                }
            }
            DisplayTransportMessage::ShmPoolCreate {
                pool_id,
                size,
                data_base64,
            } => {
                let mut data = base64_decode(&data_base64)?;
                if data.len() > size {
                    data.truncate(size);
                }
                if data.len() < size {
                    return Err(format!(
                        "shmPoolCreate payload too small pool={} got={} expected={}",
                        pool_id,
                        data.len(),
                        size
                    ));
                }
                wayland.shm_pools.insert(pool_id, ShmPool { size, data });
                sink.log(&format!("shmPoolCreate pool={} size={}", pool_id, size));
            }
            DisplayTransportMessage::ShmPoolResize {
                pool_id,
                size,
                data_base64,
            } => {
                let mut data = base64_decode(&data_base64)?;
                if data.len() > size {
                    data.truncate(size);
                }
                if data.len() < size {
                    return Err(format!(
                        "shmPoolResize payload too small pool={} got={} expected={}",
                        pool_id,
                        data.len(),
                        size
                    ));
                }
                wayland.shm_pools.insert(pool_id, ShmPool { size, data });
                sink.log(&format!("shmPoolResize pool={} size={}", pool_id, size));
            }
            DisplayTransportMessage::ShmFrame {
                session_id,
                width,
                height,
                stride,
                format,
                damage_rects,
                data_base64,
            } => {
                let session_id = if session_id.is_empty() {
                    fallback_session_id.to_string()
                } else {
                    session_id
                };
                let frame = extract_shm_frame(
                    session_id,
                    width,
                    height,
                    stride,
                    &format,
                    damage_rects,
                    &data_base64,
                )?;
                sink.emit_shm_frame(frame);
            }
        }
        parsed += 1;
    }
}

fn looks_like_display_transport(pending: &[u8]) -> bool {
    if pending.len() < 5 {
        return false;
    }
    let frame_len = u32::from_le_bytes([pending[0], pending[1], pending[2], pending[3]]) as usize;
    frame_len > 0
        && frame_len <= 64 * 1024 * 1024
        && pending.len() >= 4 + frame_len
        && pending[4] == b'{'
}

fn looks_like_incomplete_display_transport(pending: &[u8]) -> bool {
    if pending.len() < 4 {
        return false;
    }
    let frame_len = u32::from_le_bytes([pending[0], pending[1], pending[2], pending[3]]) as usize;
    frame_len >= 8 && frame_len <= 64 * 1024 * 1024 && pending.len() < 4 + frame_len
}

impl MiniWaylandState {
    fn new() -> Self {
        let mut objects = HashMap::new();
        objects.insert(1, "wl_display".to_string());
        Self {
            session_id: "default-wayland-0".to_string(),
            registry_ids: Vec::new(),
            globals: vec![
                WaylandGlobal {
                    name: 1,
                    interface: "wl_compositor",
                    version: 4,
                },
                WaylandGlobal {
                    name: 2,
                    interface: "wl_subcompositor",
                    version: 1,
                },
                WaylandGlobal {
                    name: 3,
                    interface: "wl_shm",
                    version: 1,
                },
                WaylandGlobal {
                    name: 4,
                    interface: "xdg_wm_base",
                    version: 6,
                },
                WaylandGlobal {
                    name: 5,
                    interface: "wl_seat",
                    version: 7,
                },
                WaylandGlobal {
                    name: 6,
                    interface: "wl_data_device_manager",
                    version: 3,
                },
                WaylandGlobal {
                    name: 7,
                    interface: "zwp_text_input_manager_v3",
                    version: 1,
                },
            ],
            objects,
            object_versions: HashMap::new(),
            shm_pools: HashMap::new(),
            shm_buffers: HashMap::new(),
            surfaces: HashMap::new(),
            xdg_surfaces: HashMap::new(),
            xdg_toplevels: HashMap::new(),
            xdg_popups: HashMap::new(),
            subsurfaces: HashMap::new(),
            xdg_positioners: HashMap::new(),
            text_inputs: HashMap::new(),
            surface_frames: HashMap::new(),
            active_toplevel: None,
            active_surface: None,
            pointer_object: None,
            keyboard_object: None,
            pointer_entered_surface: None,
            keyboard_focused_surface: None,
            keyboard_modifiers: 0,
            desired_keyboard_focus: false,
            last_keyboard_trace_id: None,
            last_key_serial: None,
            last_keycode: None,
            last_keyboard_drop_reason: None,
            pointer_x: 0.0,
            pointer_y: 0.0,
            cursor_surface: None,
            cursor_hotspot_x: 0,
            cursor_hotspot_y: 0,
            closed_sessions: HashMap::new(),
            serial: 1,
            raw_buffer: Vec::new(),
        }
    }

    fn next_serial(&mut self) -> u32 {
        let serial = self.serial;
        self.serial = self.serial.wrapping_add(1).max(1);
        serial
    }
}

fn drain_wayland_wire_messages(
    sink: &CallbackSink,
    stream: &mut std::fs::File,
    state: &mut MiniWaylandState,
    pending: &mut Vec<u8>,
) -> Result<usize, String> {
    state.raw_buffer.append(pending);
    let mut parsed = 0;
    loop {
        if state.raw_buffer.len() < 8 {
            break;
        }
        let object_id = read_u32(&state.raw_buffer, 0)?;
        let word = read_u32(&state.raw_buffer, 4)?;
        let opcode = (word & 0xffff) as u16;
        let size = (word >> 16) as usize;
        if size < 8 {
            return Err(format!("invalid wayland message size {}", size));
        }
        if state.raw_buffer.len() < size {
            break;
        }
        let body = state.raw_buffer[8..size].to_vec();
        state.raw_buffer.drain(..size);
        handle_wayland_request(sink, stream, state, object_id, opcode, &body)?;
        parsed += 1;
    }
    Ok(parsed)
}

fn handle_wayland_request(
    sink: &CallbackSink,
    stream: &mut std::fs::File,
    state: &mut MiniWaylandState,
    object_id: u32,
    opcode: u16,
    body: &[u8],
) -> Result<(), String> {
    let interface = state
        .objects
        .get(&object_id)
        .cloned()
        .unwrap_or_else(|| "unknown".to_string());
    sink.log(&format!(
        "wayland_request_received object={} interface={} opcode={} size={}",
        object_id,
        interface,
        opcode,
        body.len() + 8
    ));
    match (interface.as_str(), opcode) {
        ("wl_display", 0) => {
            let callback_id = read_u32(body, 0)?;
            state.objects.insert(callback_id, "wl_callback".to_string());
            sink.log(&format!("client_requested_sync callback={}", callback_id));
            send_wl_callback_done(sink, stream, callback_id, state.next_serial())?;
        }
        ("wl_display", 1) => {
            let registry_id = read_u32(body, 0)?;
            state.objects.insert(registry_id, "wl_registry".to_string());
            state.registry_ids.push(registry_id);
            sink.log(&format!(
                "client_requested_registry registry={}",
                registry_id
            ));
            for global in &state.globals {
                sink.log(&format!(
                    "registry_global_advertised name={} interface={} version={}",
                    global.name, global.interface, global.version
                ));
                send_registry_global(sink, stream, registry_id, global)?;
            }
        }
        ("wl_registry", 0) => {
            let name = read_u32(body, 0)?;
            let (interface_name, next) = read_wayland_string(body, 4)?;
            let version = read_u32(body, next)?;
            let new_id = read_u32(body, next + 4)?;
            state.objects.insert(new_id, interface_name.clone());
            state.object_versions.insert(new_id, version);
            sink.log(&format!(
                "client_bound_global name={} interface={} version={} object={}",
                name, interface_name, version, new_id
            ));
            if interface_name == "wl_shm" {
                send_wl_shm_format(sink, stream, new_id, 0)?;
                send_wl_shm_format(sink, stream, new_id, 1)?;
            } else if interface_name == "wl_seat" {
                sink.log(&format!("seat_bound object={} version={}", new_id, version));
                send_wl_seat_capabilities(sink, stream, new_id, 0x3)?;
                if version >= 2 {
                    send_wl_seat_name(sink, stream, new_id, "msl-seat")?;
                }
            }
        }
        ("zwp_text_input_manager_v3", 0) => {
            state.objects.remove(&object_id);
            state.object_versions.remove(&object_id);
            sink.log(&format!("text_input_manager_destroyed object={}", object_id));
        }
        ("zwp_text_input_manager_v3", 1) => {
            let text_input_id = read_u32(body, 0)?;
            let seat_id = read_u32(body, 4)?;
            state.objects.insert(text_input_id, "zwp_text_input_v3".to_string());
            let entered_surface = state.keyboard_focused_surface;
            state.text_inputs.insert(text_input_id, TextInputState {
                seat_id,
                entered_surface,
                ..TextInputState::default()
            });
            if let Some(surface_id) = entered_surface {
                send_text_input_enter(sink, stream, text_input_id, surface_id)?;
            }
            sink.log(&format!(
                "text_input_created object={} seat={}",
                text_input_id, seat_id
            ));
        }
        ("zwp_text_input_v3", 0) => {
            state.objects.remove(&object_id);
            state.object_versions.remove(&object_id);
            state.text_inputs.remove(&object_id);
            sink.log(&format!("text_input_destroyed object={}", object_id));
        }
        ("zwp_text_input_v3", 1) => {
            let mut entered_surface = None;
            if let Some(text_input) = state.text_inputs.get_mut(&object_id) {
                text_input.enabled = true;
                if text_input.entered_surface.is_none() {
                    text_input.entered_surface = state.keyboard_focused_surface.or(state.active_surface);
                    entered_surface = text_input.entered_surface;
                }
            }
            if let Some(surface_id) = entered_surface {
                send_text_input_enter(sink, stream, object_id, surface_id)?;
            }
            emit_text_input_state(sink, state);
            sink.log(&format!("text_input_enabled object={}", object_id));
        }
        ("zwp_text_input_v3", 2) => {
            if let Some(text_input) = state.text_inputs.get_mut(&object_id) {
                text_input.enabled = false;
            }
            emit_text_input_state(sink, state);
            sink.log(&format!("text_input_disabled object={}", object_id));
        }
        ("zwp_text_input_v3", 3) => {
            let (text, next) = read_wayland_string(body, 0)?;
            let cursor = read_i32(body, next)?;
            let anchor = read_i32(body, next + 4)?;
            if let Some(text_input) = state.text_inputs.get_mut(&object_id) {
                text_input.surrounding_text = text;
                text_input.cursor_utf8_offset = cursor;
                text_input.anchor_utf8_offset = anchor;
            }
            sink.log(&format!(
                "text_input_surrounding_text object={} cursor={} anchor={}",
                object_id, cursor, anchor
            ));
        }
        ("zwp_text_input_v3", 4) => {
            if let Some(text_input) = state.text_inputs.get_mut(&object_id) {
                text_input.change_cause = read_u32(body, 0)?;
            }
        }
        ("zwp_text_input_v3", 5) => {
            if let Some(text_input) = state.text_inputs.get_mut(&object_id) {
                text_input.content_hint = read_u32(body, 0)?;
                text_input.content_purpose = read_u32(body, 4)?;
            }
        }
        ("zwp_text_input_v3", 6) => {
            if let Some(text_input) = state.text_inputs.get_mut(&object_id) {
                text_input.cursor_rect = (
                    read_i32(body, 0)?,
                    read_i32(body, 4)?,
                    read_i32(body, 8)?,
                    read_i32(body, 12)?,
                );
            }
        }
        ("zwp_text_input_v3", 7) => {
            emit_text_input_state(sink, state);
            sink.log(&format!("text_input_commit object={}", object_id));
        }
        ("wl_compositor", 0) => {
            let surface_id = read_u32(body, 0)?;
            state.objects.insert(surface_id, "wl_surface".to_string());
            state.surfaces.insert(surface_id, SurfaceState::default());
            sink.log(&format!("surface_created object={}", surface_id));
        }
        ("wl_compositor", 1) => {
            let region_id = read_u32(body, 0)?;
            state.objects.insert(region_id, "wl_region".to_string());
            sink.log(&format!("region_created object={}", region_id));
        }
        ("wl_subcompositor", 0) => {
            state.objects.remove(&object_id);
            sink.log(&format!("wl_subcompositor_destroyed object={}", object_id));
        }
        ("wl_subcompositor", 1) => {
            let subsurface_id = read_u32(body, 0)?;
            let surface_id = read_u32(body, 4)?;
            let parent_id = read_u32(body, 8)?;
            state
                .objects
                .insert(subsurface_id, "wl_subsurface".to_string());
            state.subsurfaces.insert(subsurface_id, surface_id);
            state.surfaces.entry(surface_id).or_default().role = SurfaceRole::Subsurface {
                parent_surface: parent_id,
                x: 0,
                y: 0,
            };
            sink.log(&format!(
                "wl_subsurface_created object={} surface={} parent={}",
                subsurface_id, surface_id, parent_id
            ));
        }
        ("xdg_wm_base", 1) => {
            let surface_id = read_u32(body, 0)?;
            state
                .objects
                .insert(surface_id, "xdg_positioner".to_string());
            state
                .xdg_positioners
                .insert(surface_id, PositionerState::default());
            sink.log(&format!("xdg_positioner_created object={}", surface_id));
        }
        ("xdg_wm_base", 2) => {
            let xdg_surface_id = read_u32(body, 0)?;
            let wl_surface_id = read_u32(body, 4)?;
            state
                .objects
                .insert(xdg_surface_id, "xdg_surface".to_string());
            state.xdg_surfaces.insert(xdg_surface_id, wl_surface_id);
            state
                .surfaces
                .entry(wl_surface_id)
                .or_default()
                .xdg_surface = Some(xdg_surface_id);
            sink.log(&format!(
                "xdg_surface_created object={} wl_surface={}",
                xdg_surface_id, wl_surface_id
            ));
        }
        ("xdg_wm_base", 3) => {
            let serial = read_u32(body, 0)?;
            sink.log(&format!("xdg_wm_base_pong serial={}", serial));
        }
        ("xdg_surface", 1) => {
            let toplevel_id = read_u32(body, 0)?;
            state
                .objects
                .insert(toplevel_id, "xdg_toplevel".to_string());
            state.xdg_toplevels.insert(toplevel_id, object_id);
            if let Some(wl_surface_id) = state.xdg_surfaces.get(&object_id).copied() {
                let surface = state.surfaces.entry(wl_surface_id).or_default();
                surface.xdg_surface = Some(object_id);
                surface.xdg_toplevel = Some(toplevel_id);
            }
            if state.active_toplevel.is_none() {
                state.active_toplevel = Some(toplevel_id);
                state.active_surface = state.xdg_surfaces.get(&object_id).copied();
                if let Some(wl_surface_id) = state.active_surface {
                    state.surfaces.entry(wl_surface_id).or_default().role = SurfaceRole::Root;
                }
                sink.log(&format!("xdg_toplevel_created object={}", toplevel_id));
                ensure_keyboard_focus(sink, stream, state)?;
            } else {
                sink.log(&format!("xdg_toplevel_inactive object={}", toplevel_id));
            }
            sink.log(&format!(
                "xdg_initial_configure_deferred xdg_surface={} toplevel={}",
                object_id, toplevel_id
            ));
        }
        ("xdg_surface", 2) => {
            let popup_id = read_u32(body, 0)?;
            let parent_id = read_u32(body, 4).unwrap_or_default();
            let positioner_id = read_u32(body, 8).unwrap_or_default();
            state.objects.insert(popup_id, "xdg_popup".to_string());
            state.xdg_popups.insert(popup_id, object_id);
            let popup_surface = state.xdg_surfaces.get(&object_id).copied();
            let parent_surface = state
                .xdg_surfaces
                .get(&parent_id)
                .copied()
                .or(state.active_surface);
            let positioner = state
                .xdg_positioners
                .get(&positioner_id)
                .copied()
                .unwrap_or_default();
            let popup_x = positioner.anchor_x + positioner.offset_x;
            let popup_y = positioner.anchor_y + positioner.anchor_height + positioner.offset_y;
            if let (Some(popup_surface), Some(parent_surface)) = (popup_surface, parent_surface) {
                state.surfaces.entry(popup_surface).or_default().role = SurfaceRole::Popup {
                    parent_surface,
                    x: popup_x,
                    y: popup_y,
                };
                send_xdg_popup_configure(
                    sink,
                    stream,
                    popup_id,
                    popup_x,
                    popup_y,
                    positioner.width.max(1),
                    positioner.height.max(1),
                )?;
                let serial = state.next_serial();
                send_xdg_surface_configure(sink, stream, object_id, serial)?;
                sink.log(&format!(
                    "popup_configured popup={} xdg_surface={} wl_surface={} parent_surface={} x={} y={} width={} height={} serial={}",
                    popup_id,
                    object_id,
                    popup_surface,
                    parent_surface,
                    popup_x,
                    popup_y,
                    positioner.width.max(1),
                    positioner.height.max(1),
                    serial
                ));
            }
            sink.log(&format!(
                "popup_created object={} xdg_surface={} parent={} positioner={}",
                popup_id, object_id, parent_id, positioner_id
            ));
        }
        ("xdg_surface", 0) => {
            state.objects.remove(&object_id);
            state.object_versions.remove(&object_id);
            if let Some(wl_surface_id) = state.xdg_surfaces.remove(&object_id) {
                if state.active_surface != Some(wl_surface_id) {
                    remove_child_surface(sink, state, wl_surface_id, "xdg_surface_child_removed");
                }
                if let Some(surface) = state.surfaces.get_mut(&wl_surface_id) {
                    surface.xdg_surface = None;
                    surface.xdg_toplevel = None;
                    surface.role = SurfaceRole::None;
                    surface.initial_configure_sent = false;
                }
                if state.active_surface == Some(wl_surface_id) {
                    emit_window_event(sink, state, "closed", None, None);
                    state.active_surface = None;
                    state.active_toplevel = None;
                }
            }
            sink.log(&format!("xdg_surface_destroyed object={}", object_id));
        }
        ("xdg_surface", 3) => {
            let x = read_i32(body, 0)?;
            let y = read_i32(body, 4)?;
            let width = read_i32(body, 8)?;
            let height = read_i32(body, 12)?;
            if let Some(wl_surface_id) = state.xdg_surfaces.get(&object_id).copied() {
                if let Some(surface) = state.surfaces.get_mut(&wl_surface_id) {
                    surface.window_geometry = Some(WindowGeometry { x, y, width, height });
                }
            }
            sink.log(&format!(
                "xdg_surface_set_window_geometry object={} x={} y={} width={} height={}",
                object_id, x, y, width, height
            ));
        }
        ("xdg_surface", 4) => {
            let serial = read_u32(body, 0)?;
            sink.log(&format!(
                "xdg_surface_ack_configure object={} serial={}",
                object_id, serial
            ));
        }
        ("xdg_positioner", _) => {
            match opcode {
                0 => {
                    state.objects.remove(&object_id);
                    state.object_versions.remove(&object_id);
                    state.xdg_positioners.remove(&object_id);
                }
                1 => {
                    let width = read_i32(body, 0)?;
                    let height = read_i32(body, 4)?;
                    let positioner = state.xdg_positioners.entry(object_id).or_default();
                    positioner.width = width;
                    positioner.height = height;
                }
                2 => {
                    let x = read_i32(body, 0)?;
                    let y = read_i32(body, 4)?;
                    let width = read_i32(body, 8)?;
                    let height = read_i32(body, 12)?;
                    let positioner = state.xdg_positioners.entry(object_id).or_default();
                    positioner.anchor_x = x;
                    positioner.anchor_y = y;
                    positioner.anchor_width = width;
                    positioner.anchor_height = height;
                }
                6 => {
                    let offset_x = read_i32(body, 0)?;
                    let offset_y = read_i32(body, 4)?;
                    let positioner = state.xdg_positioners.entry(object_id).or_default();
                    positioner.offset_x = offset_x;
                    positioner.offset_y = offset_y;
                }
                _ => {}
            }
            sink.log(&format!(
                "xdg_positioner_request object={} opcode={}",
                object_id, opcode
            ));
        }
        ("wl_shm", 0) => {
            let pool_id = read_u32(body, 0)?;
            let size = read_i32(body, 4)?.max(0) as usize;
            state.objects.insert(pool_id, "wl_shm_pool".to_string());
            sink.log(&format!(
                "shm_pool_requested pool={} size={}",
                pool_id, size
            ));
        }
        ("wl_shm_pool", 0) => {
            let buffer_id = read_u32(body, 0)?;
            let offset = read_i32(body, 4)?.max(0) as usize;
            let width = read_i32(body, 8)?;
            let height = read_i32(body, 12)?;
            let stride = read_i32(body, 16)?;
            let format = read_u32(body, 20)?;
            let pool = state
                .shm_pools
                .get(&object_id)
                .ok_or_else(|| protocol_error(sink, &format!("missing shm pool {}", object_id)))?;
            let pixel_format = shm_format_from_wayland(format).ok_or_else(|| {
                protocol_error(sink, &format!("unsupported shm format {}", format))
            })?;
            validate_shm_buffer_bounds(pool, offset, width, height, stride)?;
            state.objects.insert(buffer_id, "wl_buffer".to_string());
            state.shm_buffers.insert(
                buffer_id,
                ShmBuffer {
                    pool_id: object_id,
                    offset,
                    width,
                    height,
                    stride,
                    format: pixel_format,
                },
            );
            sink.log(&format!(
                "shm_buffer_created object={} pool={} offset={} width={} height={} stride={} format={}",
                buffer_id, object_id, offset, width, height, stride, format
            ));
        }
        ("wl_shm_pool", 1) => {
            state.objects.remove(&object_id);
            state.shm_pools.remove(&object_id);
            sink.log(&format!("shm_pool_destroyed pool={}", object_id));
        }
        ("wl_shm_pool", 2) => {
            let size = read_i32(body, 0)?.max(0) as usize;
            sink.log(&format!(
                "shm_pool_resize_requested pool={} size={}",
                object_id, size
            ));
        }
        ("wl_buffer", 0) => {
            state.objects.remove(&object_id);
            state.shm_buffers.remove(&object_id);
            for surface in state.surfaces.values_mut() {
                if surface.attached_buffer == Some(object_id) {
                    surface.attached_buffer = None;
                }
                if surface.pending_attach == PendingAttach::Attach(Some(object_id)) {
                    surface.pending_attach = PendingAttach::Unchanged;
                }
            }
            sink.log(&format!("wl_buffer_destroyed object={}", object_id));
        }
        ("wl_seat", 0) => {
            let pointer_id = read_u32(body, 0)?;
            let seat_version = state.object_versions.get(&object_id).copied().unwrap_or(1);
            state.objects.insert(pointer_id, "wl_pointer".to_string());
            state.object_versions.insert(pointer_id, seat_version);
            state.pointer_object = Some(pointer_id);
            sink.log(&format!(
                "pointer_requested seat={} object={} seat_version={}",
                object_id, pointer_id, seat_version
            ));
            sink.log(&format!(
                "wl_pointer_created object={} seat={}",
                pointer_id, object_id
            ));
            send_wl_seat_capabilities(sink, stream, object_id, 0x3)?;
        }
        ("wl_seat", 1) => {
            let keyboard_id = read_u32(body, 0)?;
            let seat_version = state.object_versions.get(&object_id).copied().unwrap_or(1);
            state.objects.insert(keyboard_id, "wl_keyboard".to_string());
            state.object_versions.insert(keyboard_id, seat_version);
            state.keyboard_object = Some(keyboard_id);
            sink.log(&format!(
                "keyboard_requested seat={} object={} seat_version={}",
                object_id, keyboard_id, seat_version
            ));
            sink.log(&format!(
                "wl_keyboard_created object={} seat={}",
                keyboard_id, object_id
            ));
            send_wl_seat_capabilities(sink, stream, object_id, 0x3)?;
            send_keyboard_keymap_control(sink, stream, keyboard_id)?;
            sink.log(&format!("keyboard_keymap_sent object={}", keyboard_id));
            if seat_version >= 4 {
                send_wl_keyboard_repeat_info(sink, stream, keyboard_id, 25, 600)?;
                sink.log(&format!(
                    "keyboard_repeat_info_sent object={} rate=25 delay=600",
                    keyboard_id
                ));
            }
            ensure_keyboard_focus(sink, stream, state)?;
        }
        ("wl_seat", 2) => {
            let touch_id = read_u32(body, 0)?;
            state.objects.insert(touch_id, "wl_touch".to_string());
            sink.log(&format!(
                "wl_touch_created object={} seat={}",
                touch_id, object_id
            ));
        }
        ("wl_seat", 3) => {
            state.objects.remove(&object_id);
            state.object_versions.remove(&object_id);
            sink.log(&format!("wl_seat_released object={}", object_id));
        }
        ("wl_pointer", 0) => {
            let serial = read_u32(body, 0).unwrap_or_default();
            let surface = read_u32(body, 4).unwrap_or_default();
            let hotspot_x = read_i32(body, 8).unwrap_or_default();
            let hotspot_y = read_i32(body, 12).unwrap_or_default();
            if surface == 0 {
                state.cursor_surface = None;
            } else {
                state.cursor_surface = Some(surface);
                state.cursor_hotspot_x = hotspot_x;
                state.cursor_hotspot_y = hotspot_y;
            }
            sink.log(&format!(
                "wl_pointer_set_cursor object={} serial={} surface={} hotspot_x={} hotspot_y={}",
                object_id, serial, surface, hotspot_x, hotspot_y
            ));
        }
        ("wl_pointer", 1) => {
            state.objects.remove(&object_id);
            state.object_versions.remove(&object_id);
            if state.pointer_object == Some(object_id) {
                state.pointer_object = None;
                state.pointer_entered_surface = None;
            }
            sink.log(&format!(
                "input_object_released object={} interface={}",
                object_id, interface
            ));
        }
        ("wl_keyboard", 0) | ("wl_touch", 0) => {
            state.objects.remove(&object_id);
            state.object_versions.remove(&object_id);
            if state.keyboard_object == Some(object_id) {
                state.keyboard_object = None;
                state.keyboard_focused_surface = None;
            }
            sink.log(&format!(
                "input_object_released object={} interface={}",
                object_id, interface
            ));
        }
        ("wl_data_device_manager", 0) => {
            let data_source_id = read_u32(body, 0)?;
            state
                .objects
                .insert(data_source_id, "wl_data_source".to_string());
            sink.log(&format!("wl_data_source_created object={}", data_source_id));
        }
        ("wl_data_device_manager", 1) => {
            let data_device_id = read_u32(body, 0)?;
            let seat_id = read_u32(body, 4)?;
            state
                .objects
                .insert(data_device_id, "wl_data_device".to_string());
            sink.log(&format!(
                "wl_data_device_created object={} seat={}",
                data_device_id, seat_id
            ));
        }
        ("wl_data_source", 0) => {
            let (mime_type, _) = read_wayland_string(body, 0)?;
            sink.log(&format!(
                "wl_data_source_offer object={} mime={}",
                object_id, mime_type
            ));
        }
        ("wl_data_source", 1) | ("wl_data_source", 2) | ("wl_data_source", 3) => {
            sink.log(&format!(
                "wl_data_source_request object={} opcode={}",
                object_id, opcode
            ));
        }
        ("wl_data_source", 4) | ("wl_data_device", 2) => {
            state.objects.remove(&object_id);
            state.object_versions.remove(&object_id);
            sink.log(&format!(
                "data_object_destroyed object={} interface={}",
                object_id, interface
            ));
        }
        ("wl_data_device", 0) | ("wl_data_device", 1) => {
            sink.log(&format!(
                "wl_data_device_request object={} opcode={}",
                object_id, opcode
            ));
        }
        ("xdg_toplevel", 0) => {
            state.objects.remove(&object_id);
            state.object_versions.remove(&object_id);
            let was_active = state.active_toplevel == Some(object_id);
            if let Some(xdg_surface_id) = state.xdg_toplevels.remove(&object_id) {
                if let Some(wl_surface_id) = state.xdg_surfaces.get(&xdg_surface_id).copied() {
                    if let Some(surface) = state.surfaces.get_mut(&wl_surface_id) {
                        surface.xdg_toplevel = None;
                    }
                    if !was_active {
                        remove_child_surface(sink, state, wl_surface_id, "transient_toplevel_removed");
                    }
                }
            }
            if state.active_toplevel == Some(object_id) {
                state.active_toplevel = None;
                state.active_surface = None;
            }
            if was_active {
                emit_window_event(sink, state, "closed", None, None);
            }
            sink.log(&format!("xdg_toplevel_destroyed object={}", object_id));
        }
        ("xdg_toplevel", 1) => {
            let parent_id = read_u32(body, 0).unwrap_or_default();
            if parent_id != 0 {
                if let Some(xdg_surface_id) = state.xdg_toplevels.get(&object_id).copied() {
                    if let Some(wl_surface_id) = state.xdg_surfaces.get(&xdg_surface_id).copied() {
                        if let Some(parent_surface) = state.active_surface {
                            state.surfaces.entry(wl_surface_id).or_default().role =
                                SurfaceRole::Transient { parent_surface };
                            sink.log(&format!(
                                "transient_toplevel_created object={} surface={} parent_toplevel={} parent_surface={}",
                                object_id, wl_surface_id, parent_id, parent_surface
                            ));
                        }
                    }
                }
            }
            sink.log(&format!(
                "xdg_toplevel_set_parent object={} parent={}",
                object_id, parent_id
            ));
        }
        ("xdg_toplevel", 2) => {
            let (title, _) = read_wayland_string(body, 0)?;
            if state.active_toplevel == Some(object_id) {
                emit_window_event(sink, state, "title", Some(title.clone()), None);
            }
            sink.log(&format!(
                "xdg_toplevel_title object={} title={}",
                object_id, title
            ));
        }
        ("xdg_toplevel", 3) => {
            let (app_id, _) = read_wayland_string(body, 0)?;
            if state.active_toplevel == Some(object_id) {
                emit_window_event(sink, state, "appId", None, Some(app_id.clone()));
            }
            sink.log(&format!(
                "xdg_toplevel_app_id object={} app_id={}",
                object_id, app_id
            ));
        }
        ("xdg_toplevel", 4) => {
            let seat = read_u32(body, 0).unwrap_or_default();
            let serial = read_u32(body, 4).unwrap_or_default();
            let x = read_i32(body, 8).unwrap_or_default();
            let y = read_i32(body, 12).unwrap_or_default();
            sink.log(&format!(
                "xdg_toplevel_show_window_menu_requested object={} seat={} serial={} x={} y={}",
                object_id, seat, serial, x, y
            ));
        }
        ("xdg_toplevel", 5) => {
            let seat = read_u32(body, 0).unwrap_or_default();
            let serial = read_u32(body, 4).unwrap_or_default();
            if state.active_toplevel == Some(object_id) {
                emit_window_event_with_details(
                    sink,
                    state,
                    "moveRequested",
                    None,
                    None,
                    Some(serial),
                    Some(seat),
                    None,
                );
            }
            sink.log(&format!(
                "xdg_toplevel_move_requested object={} seat={} serial={}",
                object_id, seat, serial
            ));
        }
        ("xdg_toplevel", 6) => {
            let seat = read_u32(body, 0).unwrap_or_default();
            let serial = read_u32(body, 4).unwrap_or_default();
            let edge = read_u32(body, 8).unwrap_or_default();
            if state.active_toplevel == Some(object_id) {
                emit_window_event_with_details(
                    sink,
                    state,
                    "resizeRequested",
                    None,
                    None,
                    Some(serial),
                    Some(seat),
                    Some(edge),
                );
            }
            sink.log(&format!(
                "xdg_toplevel_resize_requested object={} seat={} serial={} edge={}",
                object_id, seat, serial, edge
            ));
        }
        ("xdg_toplevel", 9)
        | ("xdg_toplevel", 10)
        | ("xdg_toplevel", 11)
        | ("xdg_toplevel", 12)
        | ("xdg_toplevel", 13) => {
            sink.log(&format!(
                "xdg_toplevel_state_request object={} opcode={}",
                object_id, opcode
            ));
        }
        ("xdg_toplevel", 7) => {
            sink.log(&format!(
                "xdg_toplevel_set_max_size object={} width={} height={}",
                object_id,
                read_i32(body, 0)?,
                read_i32(body, 4)?
            ));
        }
        ("xdg_toplevel", 8) => {
            sink.log(&format!(
                "xdg_toplevel_set_min_size object={} width={} height={}",
                object_id,
                read_i32(body, 0)?,
                read_i32(body, 4)?
            ));
        }
        ("wl_surface", 0) => {
            let was_active = state.active_surface == Some(object_id);
            if !was_active {
                remove_child_surface(sink, state, object_id, "wl_surface_child_removed");
            }
            state.objects.remove(&object_id);
            state.object_versions.remove(&object_id);
            state.surfaces.remove(&object_id);
            if state.cursor_surface == Some(object_id) {
                state.cursor_surface = None;
            }
            if was_active {
                emit_window_event(sink, state, "closed", None, None);
                state.active_surface = None;
                state.active_toplevel = None;
            }
            sink.log(&format!("wl_surface_destroyed object={}", object_id));
        }
        ("wl_surface", 1) => {
            let buffer_id = read_u32(body, 0)?;
            let buffer_id = if buffer_id == 0 {
                None
            } else {
                Some(buffer_id)
            };
            let surface = state.surfaces.entry(object_id).or_default();
            surface.pending_attach = PendingAttach::Attach(buffer_id);
            sink.log(&format!(
                "wl_surface_attach object={} buffer={}",
                object_id,
                buffer_id.unwrap_or(0)
            ));
        }
        ("wl_surface", 2) | ("wl_surface", 9) => {
            let rect = TransportDamageRect {
                x: read_i32(body, 0)?,
                y: read_i32(body, 4)?,
                width: read_i32(body, 8)?,
                height: read_i32(body, 12)?,
            };
            let surface = state.surfaces.entry(object_id).or_default();
            surface.pending_damage.push(DamageRect {
                x: rect.x,
                y: rect.y,
                width: rect.width,
                height: rect.height,
            });
            sink.log(&format!(
                "wl_surface_damage object={} x={} y={} width={} height={} opcode={}",
                object_id, rect.x, rect.y, rect.width, rect.height, opcode
            ));
        }
        ("wl_surface", 3) => {
            let callback_id = read_u32(body, 0)?;
            let surface = state.surfaces.entry(object_id).or_default();
            surface.pending_frame_callbacks.push(callback_id);
            state.objects.insert(callback_id, "wl_callback".to_string());
            sink.log(&format!(
                "wl_surface_frame object={} callback={}",
                object_id, callback_id
            ));
        }
        ("wl_surface", 4) => {
            sink.log(&format!(
                "wl_surface_set_opaque_region object={} region={}",
                object_id,
                read_u32(body, 0).unwrap_or_default()
            ));
        }
        ("wl_surface", 5) => {
            sink.log(&format!(
                "wl_surface_set_input_region object={} region={}",
                object_id,
                read_u32(body, 0).unwrap_or_default()
            ));
        }
        ("wl_surface", 6) => {
            sink.log(&format!("wl_surface_commit object={}", object_id));
            if let Some((xdg_surface_id, toplevel_id)) = state
                .surfaces
                .get(&object_id)
                .and_then(|surface| {
                    if surface.initial_configure_sent {
                        None
                    } else {
                        Some((surface.xdg_surface?, surface.xdg_toplevel?))
                    }
                })
            {
                send_xdg_toplevel_configure(sink, stream, toplevel_id, 0, 0)?;
                let serial = state.next_serial();
                send_xdg_surface_configure(sink, stream, xdg_surface_id, serial)?;
                if let Some(surface) = state.surfaces.get_mut(&object_id) {
                    surface.initial_configure_sent = true;
                }
                sink.log(&format!(
                    "xdg_initial_configure_sent wl_surface={} xdg_surface={} toplevel={} serial={}",
                    object_id, xdg_surface_id, toplevel_id, serial
                ));
            }
            emit_surface_commit_frame(sink, stream, state, object_id)?;
        }
        ("wl_surface", 8) => {
            sink.log(&format!(
                "wl_surface_set_buffer_scale object={} scale={}",
                object_id,
                read_i32(body, 0)?
            ));
        }
        ("wl_surface", 10) => {
            sink.log(&format!(
                "wl_surface_offset object={} x={} y={}",
                object_id,
                read_i32(body, 0)?,
                read_i32(body, 4)?
            ));
        }
        ("wl_region", 0) => {
            state.objects.remove(&object_id);
            sink.log(&format!("wl_region_destroy object={}", object_id));
        }
        ("wl_region", 1) | ("wl_region", 2) => {
            sink.log(&format!(
                "wl_region_{} object={} x={} y={} width={} height={}",
                if opcode == 1 { "add" } else { "subtract" },
                object_id,
                read_i32(body, 0)?,
                read_i32(body, 4)?,
                read_i32(body, 8)?,
                read_i32(body, 12)?
            ));
        }
        ("wl_subsurface", 0) => {
            state.objects.remove(&object_id);
            if let Some(surface_id) = state.subsurfaces.remove(&object_id) {
                remove_child_surface(sink, state, surface_id, "subsurface_removed");
            }
            sink.log(&format!("wl_subsurface_destroyed object={}", object_id));
        }
        ("wl_subsurface", 1) => {
            let x = read_i32(body, 0)?;
            let y = read_i32(body, 4)?;
            for surface in state.surfaces.values_mut() {
                if let SurfaceRole::Subsurface {
                    parent_surface,
                    x: ref mut surface_x,
                    y: ref mut surface_y,
                } = surface.role
                {
                    let parent = parent_surface;
                    *surface_x = x;
                    *surface_y = y;
                    sink.log(&format!(
                        "wl_subsurface_position_updated parent={} x={} y={}",
                        parent, x, y
                    ));
                }
            }
            sink.log(&format!(
                "wl_subsurface_set_position object={} x={} y={}",
                object_id,
                x,
                y
            ));
        }
        ("wl_subsurface", 2) | ("wl_subsurface", 3) | ("wl_subsurface", 4)
        | ("wl_subsurface", 5) | ("wl_subsurface", 6) => {
            sink.log(&format!(
                "wl_subsurface_request object={} opcode={}",
                object_id, opcode
            ));
        }
        ("xdg_popup", 0) => {
            state.objects.remove(&object_id);
            if let Some(xdg_surface_id) = state.xdg_popups.remove(&object_id) {
                if let Some(wl_surface_id) = state.xdg_surfaces.get(&xdg_surface_id).copied() {
                    remove_child_surface(sink, state, wl_surface_id, "popup_removed");
                }
            }
            sink.log(&format!("xdg_popup_destroyed object={}", object_id));
        }
        ("xdg_popup", 1) | ("xdg_popup", 2) => {
            sink.log(&format!(
                "xdg_popup_request object={} opcode={}",
                object_id, opcode
            ));
        }
        _ => {
            sink.log(&format!(
                "wayland_request_unhandled object={} interface={} opcode={} size={}",
                object_id,
                interface,
                opcode,
                body.len() + 8
            ));
        }
    }
    Ok(())
}

fn read_u32(bytes: &[u8], offset: usize) -> Result<u32, String> {
    let slice = bytes
        .get(offset..offset + 4)
        .ok_or_else(|| format!("short wayland u32 at offset {}", offset))?;
    Ok(u32::from_ne_bytes([slice[0], slice[1], slice[2], slice[3]]))
}

fn read_i32(bytes: &[u8], offset: usize) -> Result<i32, String> {
    let slice = bytes
        .get(offset..offset + 4)
        .ok_or_else(|| format!("short wayland i32 at offset {}", offset))?;
    Ok(i32::from_ne_bytes([slice[0], slice[1], slice[2], slice[3]]))
}

fn protocol_error(sink: &CallbackSink, message: &str) -> String {
    sink.log(&format!("protocol_error {}", message));
    message.to_string()
}

fn emit_window_event(
    sink: &CallbackSink,
    state: &mut MiniWaylandState,
    event_type: &'static str,
    title: Option<String>,
    app_id: Option<String>,
) {
    emit_window_event_with_details(sink, state, event_type, title, app_id, None, None, None);
}

fn emit_window_event_with_details(
    sink: &CallbackSink,
    state: &mut MiniWaylandState,
    event_type: &'static str,
    title: Option<String>,
    app_id: Option<String>,
    serial: Option<u32>,
    seat: Option<u32>,
    edge: Option<u32>,
) {
    if matches!(event_type, "closed" | "unmapped") {
        state
            .closed_sessions
            .insert(state.session_id.clone(), event_type);
    }
    sink.emit_window_event(WindowEventPayload {
        session_id: state.session_id.clone(),
        event_type,
        title,
        app_id,
        serial,
        seat,
        edge,
        pointer_x: Some(state.pointer_x),
        pointer_y: Some(state.pointer_y),
        epoch_ms: epoch_ms(),
    });
    sink.log(&format!(
        "wayland_window_event session={} event={}",
        state.session_id, event_type
    ));
}

fn remove_child_surface(
    sink: &CallbackSink,
    state: &mut MiniWaylandState,
    surface_id: u32,
    reason: &'static str,
) {
    let Some(surface) = state.surfaces.get_mut(&surface_id) else {
        return;
    };
    if matches!(surface.role, SurfaceRole::Root | SurfaceRole::None) {
        return;
    }
    surface.role = SurfaceRole::None;
    state.surface_frames.remove(&surface_id);
    sink.log(&format!(
        "surface_tree_child_removed surface={} reason={}",
        surface_id, reason
    ));
    emit_composed_frame(sink, state, surface_id, Vec::new());
}

fn shm_format_from_wayland(format: u32) -> Option<ShmPixelFormat> {
    match format {
        0 => Some(ShmPixelFormat::Argb8888),
        1 => Some(ShmPixelFormat::Xrgb8888),
        _ => None,
    }
}

fn validate_shm_buffer_bounds(
    pool: &ShmPool,
    offset: usize,
    width: i32,
    height: i32,
    stride: i32,
) -> Result<(), String> {
    if width <= 0 || height <= 0 {
        return Err("invalid shm buffer geometry".to_string());
    }
    let minimum_stride = width
        .checked_mul(4)
        .ok_or_else(|| "shm buffer stride overflow".to_string())?;
    if stride < minimum_stride {
        return Err(format!("invalid shm buffer stride {}", stride));
    }
    let byte_len = (stride as usize)
        .checked_mul(height as usize)
        .ok_or_else(|| "shm buffer byte size overflow".to_string())?;
    let end = offset
        .checked_add(byte_len)
        .ok_or_else(|| "shm buffer bounds overflow".to_string())?;
    if end > pool.size || end > pool.data.len() {
        return Err(format!(
            "shm buffer out of bounds offset={} len={} pool_size={} data_len={}",
            offset,
            byte_len,
            pool.size,
            pool.data.len()
        ));
    }
    Ok(())
}

fn extract_surface_frame(
    sink: &CallbackSink,
    state: &MiniWaylandState,
    buffer_id: u32,
) -> Result<SurfaceFrame, String> {
    let buffer = *state
        .shm_buffers
        .get(&buffer_id)
        .ok_or_else(|| protocol_error(sink, &format!("missing shm buffer {}", buffer_id)))?;
    let pool = state
        .shm_pools
        .get(&buffer.pool_id)
        .ok_or_else(|| protocol_error(sink, &format!("missing shm pool {}", buffer.pool_id)))?;
    validate_shm_buffer_bounds(
        pool,
        buffer.offset,
        buffer.width,
        buffer.height,
        buffer.stride,
    )
    .map_err(|e| protocol_error(sink, &e))?;

    let expected_len = (buffer.stride as usize)
        .checked_mul(buffer.height as usize)
        .ok_or_else(|| protocol_error(sink, "frame byte size overflow"))?;
    let mut pixels = vec![0_u8; expected_len];
    for y in 0..buffer.height as usize {
        let src = buffer.offset + y * buffer.stride as usize;
        let dst = y * buffer.stride as usize;
        let row_len = buffer.stride as usize;
        pixels[dst..dst + row_len].copy_from_slice(&pool.data[src..src + row_len]);
    }
    for pixel in pixels.chunks_exact_mut(4) {
        if buffer.format == ShmPixelFormat::Xrgb8888 {
            pixel[3] = 0xff;
        }
    }
    Ok(SurfaceFrame {
        width: buffer.width,
        height: buffer.height,
        stride: buffer.stride,
        format: buffer.format,
        pixels,
    })
}

fn alpha_blend_bgra(dst: &mut [u8], src: &[u8]) {
    let alpha = src[3] as u32;
    if alpha == 255 {
        dst.copy_from_slice(src);
        return;
    }
    if alpha == 0 {
        return;
    }
    let inv = 255 - alpha;
    dst[0] = ((src[0] as u32 * alpha + dst[0] as u32 * inv) / 255) as u8;
    dst[1] = ((src[1] as u32 * alpha + dst[1] as u32 * inv) / 255) as u8;
    dst[2] = ((src[2] as u32 * alpha + dst[2] as u32 * inv) / 255) as u8;
    dst[3] = (alpha + (dst[3] as u32 * inv) / 255).min(255) as u8;
}

fn composite_surface_onto(base: &mut SurfaceFrame, child: &SurfaceFrame, x: i32, y: i32) {
    let start_x = x.max(0);
    let start_y = y.max(0);
    let end_x = (x + child.width).min(base.width);
    let end_y = (y + child.height).min(base.height);
    if end_x <= start_x || end_y <= start_y {
        return;
    }
    for dst_y in start_y..end_y {
        let src_y = dst_y - y;
        for dst_x in start_x..end_x {
            let src_x = dst_x - x;
            let dst_index = dst_y as usize * base.stride as usize + dst_x as usize * 4;
            let src_index = src_y as usize * child.stride as usize + src_x as usize * 4;
            alpha_blend_bgra(
                &mut base.pixels[dst_index..dst_index + 4],
                &child.pixels[src_index..src_index + 4],
            );
        }
    }
}

fn surface_offset_to_root(
    state: &MiniWaylandState,
    surface_id: u32,
    depth: usize,
) -> Option<(i32, i32)> {
    if depth > 16 {
        return None;
    }
    if state.active_surface == Some(surface_id) {
        return Some((0, 0));
    }
    let surface = state.surfaces.get(&surface_id)?;
    match surface.role {
        SurfaceRole::Popup {
            parent_surface,
            x,
            y,
        }
        | SurfaceRole::Subsurface {
            parent_surface,
            x,
            y,
        } => {
            let (parent_x, parent_y) = surface_offset_to_root(state, parent_surface, depth + 1)?;
            Some((parent_x + x, parent_y + y))
        }
        SurfaceRole::Transient { parent_surface } => {
            let _ = surface_offset_to_root(state, parent_surface, depth + 1)?;
            Some((32, 32))
        }
        SurfaceRole::Root | SurfaceRole::None => None,
    }
}

fn compose_frame_for_root(
    sink: &CallbackSink,
    state: &MiniWaylandState,
    root_surface_id: u32,
    damage_rects: Vec<DamageRect>,
) -> Option<ExtractedShmFrame> {
    let mut composed = state.surface_frames.get(&root_surface_id)?.clone();
    let mut children = state
        .surface_frames
        .iter()
        .filter_map(|(surface_id, frame)| {
            if *surface_id == root_surface_id || state.cursor_surface == Some(*surface_id) {
                return None;
            }
            surface_offset_to_root(state, *surface_id, 0).map(|(x, y)| (*surface_id, x, y, frame.clone()))
        })
        .collect::<Vec<_>>();
    children.sort_by_key(|(_, _, y, _)| *y);
    for (surface_id, x, y, frame) in children {
        composite_surface_onto(&mut composed, &frame, x, y);
        sink.log(&format!(
            "surface_composited surface={} x={} y={} width={} height={}",
            surface_id, x, y, frame.width, frame.height
        ));
    }
    let mut damage_rects = damage_rects
        .into_iter()
        .filter_map(|rect| {
            clip_damage_rect(
                TransportDamageRect {
                    x: rect.x,
                    y: rect.y,
                    width: rect.width,
                    height: rect.height,
                },
                composed.width,
                composed.height,
            )
        })
        .collect::<Vec<_>>();
    if damage_rects.is_empty() {
        damage_rects.push(DamageRect {
            x: 0,
            y: 0,
            width: composed.width,
            height: composed.height,
        });
    }
    Some(ExtractedShmFrame {
        session_id: state.session_id.clone(),
        width: composed.width,
        height: composed.height,
        stride: composed.stride,
        pixel_format: composed.format,
        damage_rects,
        pixels: composed.pixels,
    })
}

fn emit_composed_frame(
    sink: &CallbackSink,
    state: &MiniWaylandState,
    reason_surface_id: u32,
    damage_rects: Vec<DamageRect>,
) {
    let Some(root_surface_id) = state.active_surface else {
        sink.log(&format!(
            "composed_frame_skipped reason=no_active_surface surface={}",
            reason_surface_id
        ));
        return;
    };
    if let Some(frame) = compose_frame_for_root(sink, state, root_surface_id, damage_rects) {
        let width = frame.width;
        let height = frame.height;
        sink.emit_shm_frame(frame);
        sink.log(&format!(
            "composed_frame_emitted root={} reason_surface={} width={} height={}",
            root_surface_id, reason_surface_id, width, height
        ));
    } else {
        sink.log(&format!(
            "composed_frame_skipped reason=missing_root_frame root={} surface={}",
            root_surface_id, reason_surface_id
        ));
    }
}

fn emit_surface_commit_frame(
    sink: &CallbackSink,
    stream: &mut std::fs::File,
    state: &mut MiniWaylandState,
    surface_id: u32,
) -> Result<(), String> {
    let (buffer_id, release_after_commit, detached_on_commit, damage, frame_callbacks) = {
        let surface = state.surfaces.entry(surface_id).or_default();
        let mut detached_on_commit = false;
        let release_after_commit =
            match std::mem::replace(&mut surface.pending_attach, PendingAttach::Unchanged) {
                PendingAttach::Unchanged => None,
                PendingAttach::Attach(next_buffer) => {
                    detached_on_commit = next_buffer.is_none();
                    let previous = surface.attached_buffer;
                    surface.attached_buffer = next_buffer;
                    if previous != next_buffer {
                        previous
                    } else {
                        None
                    }
                }
        };
        let damage = std::mem::take(&mut surface.pending_damage);
        let frame_callbacks = std::mem::take(&mut surface.pending_frame_callbacks);
        (
            surface.attached_buffer,
            release_after_commit,
            detached_on_commit,
            damage,
            frame_callbacks,
        )
    };
    let Some(buffer_id) = buffer_id else {
        sink.log(&format!("frame_skipped_no_buffer surface={}", surface_id));
        if detached_on_commit {
            if state.active_surface != Some(surface_id) {
                remove_child_surface(sink, state, surface_id, "child_detached");
            } else {
                state.surface_frames.remove(&surface_id);
            }
        }
        if detached_on_commit && state.active_surface == Some(surface_id) {
            emit_window_event(sink, state, "unmapped", None, None);
            state.active_surface = None;
            state.active_toplevel = None;
        }
        send_frame_callbacks(sink, stream, state, frame_callbacks)?;
        if let Some(release_buffer_id) = release_after_commit {
            send_wl_buffer_release(sink, stream, release_buffer_id)?;
        }
        return Ok(());
    };
    let frame = extract_surface_frame(sink, state, buffer_id)?;
    state.surface_frames.insert(surface_id, frame.clone());

    if state.cursor_surface == Some(surface_id) {
        sink.emit_cursor(CursorPayload {
            session_id: state.session_id.clone(),
            width: frame.width,
            height: frame.height,
            stride: frame.stride,
            hotspot_x: state.cursor_hotspot_x,
            hotspot_y: state.cursor_hotspot_y,
            pixel_format: frame.format.as_str(),
            data_base64: base64_encode(&frame.pixels),
            epoch_ms: epoch_ms(),
        });
        sink.log(&format!(
            "wayland_cursor_updated surface={} buffer={} width={} height={} hotspot_x={} hotspot_y={}",
            surface_id, buffer_id, frame.width, frame.height, state.cursor_hotspot_x, state.cursor_hotspot_y
        ));
        send_frame_callbacks(sink, stream, state, frame_callbacks)?;
        if let Some(release_buffer_id) = release_after_commit {
            send_wl_buffer_release(sink, stream, release_buffer_id)?;
        }
        return Ok(());
    }

    if state.active_surface != Some(surface_id) {
        let role = state
            .surfaces
            .get(&surface_id)
            .map(|surface| format!("{:?}", surface.role))
            .unwrap_or_else(|| "missing".to_string());
        if matches!(state.surfaces.get(&surface_id).map(|s| &s.role), Some(SurfaceRole::Popup { .. })) {
            sink.log(&format!("popup_committed surface={} role={}", surface_id, role));
            emit_composed_frame(sink, state, surface_id, Vec::new());
        } else if matches!(state.surfaces.get(&surface_id).map(|s| &s.role), Some(SurfaceRole::Subsurface { .. })) {
            sink.log(&format!("subsurface_committed surface={} role={}", surface_id, role));
            emit_composed_frame(sink, state, surface_id, Vec::new());
        } else if matches!(state.surfaces.get(&surface_id).map(|s| &s.role), Some(SurfaceRole::Transient { .. })) {
            sink.log(&format!("transient_toplevel_committed surface={} role={}", surface_id, role));
            emit_composed_frame(sink, state, surface_id, Vec::new());
        } else {
            sink.log(&format!(
                "frame_skipped_non_root_surface surface={} active_surface={} role={}",
                surface_id,
                state.active_surface.unwrap_or_default(),
                role
            ));
        }
        send_frame_callbacks(sink, stream, state, frame_callbacks)?;
        if let Some(release_buffer_id) = release_after_commit {
            send_wl_buffer_release(sink, stream, release_buffer_id)?;
        }
        return Ok(());
    }
    ensure_keyboard_focus(sink, stream, state)?;

    let mut damage_rects = damage
        .into_iter()
        .filter_map(|rect| {
            clip_damage_rect(
                TransportDamageRect {
                    x: rect.x,
                    y: rect.y,
                    width: rect.width,
                    height: rect.height,
                },
                frame.width,
                frame.height,
            )
        })
        .collect::<Vec<_>>();
    if damage_rects.is_empty() {
        damage_rects.push(DamageRect {
            x: 0,
            y: 0,
            width: frame.width,
            height: frame.height,
        });
    }

    emit_composed_frame(sink, state, surface_id, damage_rects);
    sink.log(&format!(
        "real_shm_frame_emitted surface={} buffer={} width={} height={}",
        surface_id, buffer_id, frame.width, frame.height
    ));
    send_frame_callbacks(sink, stream, state, frame_callbacks)?;
    if let Some(release_buffer_id) = release_after_commit {
        send_wl_buffer_release(sink, stream, release_buffer_id)?;
    }
    Ok(())
}

fn send_frame_callbacks(
    sink: &CallbackSink,
    stream: &mut std::fs::File,
    state: &mut MiniWaylandState,
    frame_callbacks: Vec<u32>,
) -> Result<(), String> {
    let callback_data = (epoch_ms() & 0xffff_ffff) as u32;
    for callback_id in frame_callbacks {
        send_wl_callback_done(sink, stream, callback_id, callback_data)?;
        state.objects.remove(&callback_id);
        sink.log(&format!(
            "wl_surface_frame_done callback={} data={}",
            callback_id, callback_data
        ));
    }
    Ok(())
}

fn read_wayland_string(bytes: &[u8], offset: usize) -> Result<(String, usize), String> {
    let len = read_u32(bytes, offset)? as usize;
    let start = offset + 4;
    let end = start + len;
    let raw = bytes
        .get(start..end)
        .ok_or_else(|| "short wayland string".to_string())?;
    let value = if raw.last() == Some(&0) {
        &raw[..raw.len() - 1]
    } else {
        raw
    };
    let next = align4(end);
    Ok((String::from_utf8_lossy(value).into_owned(), next))
}

fn align4(value: usize) -> usize {
    (value + 3) & !3
}

fn send_event(
    sink: &CallbackSink,
    stream: &mut std::fs::File,
    object_id: u32,
    opcode: u16,
    body: &[u8],
) -> Result<(), String> {
    let size = 8 + body.len();
    let mut bytes = Vec::with_capacity(size);
    bytes.extend_from_slice(&object_id.to_ne_bytes());
    bytes.extend_from_slice(&(((size as u32) << 16) | opcode as u32).to_ne_bytes());
    bytes.extend_from_slice(body);
    sink.log(&format!(
        "wayland_event_sent object={} opcode={} size={}",
        object_id, opcode, size
    ));
    stream
        .write_all(&bytes)
        .map_err(|e| format!("wayland write failed: {}", e))?;
    stream
        .flush()
        .map_err(|e| format!("wayland flush failed: {}", e))
}

fn send_msl_control_frame(
    sink: &CallbackSink,
    stream: &mut std::fs::File,
    json: &[u8],
) -> Result<(), String> {
    sink.log(&format!("wayland_control_frame_sent size={}", json.len()));
    stream
        .write_all(b"MSLW")
        .map_err(|e| format!("control frame magic write failed: {}", e))?;
    stream
        .write_all(&(json.len() as u32).to_le_bytes())
        .map_err(|e| format!("control frame length write failed: {}", e))?;
    stream
        .write_all(json)
        .map_err(|e| format!("control frame body write failed: {}", e))?;
    stream
        .flush()
        .map_err(|e| format!("control frame flush failed: {}", e))
}

fn send_keyboard_keymap_control(
    sink: &CallbackSink,
    stream: &mut std::fs::File,
    keyboard_id: u32,
) -> Result<(), String> {
    #[derive(Serialize)]
    struct KeyboardKeymap<'a> {
        #[serde(rename = "type")]
        message_type: &'static str,
        #[serde(rename = "keyboardId")]
        keyboard_id: u32,
        format: u32,
        size: usize,
        #[serde(rename = "dataBase64")]
        data_base64: String,
        #[serde(skip)]
        _marker: std::marker::PhantomData<&'a ()>,
    }
    let keymap = default_xkb_keymap();
    let message = KeyboardKeymap {
        message_type: "keyboardKeymap",
        keyboard_id,
        format: 1,
        size: keymap.len(),
        data_base64: base64_encode(keymap.as_bytes()),
        _marker: std::marker::PhantomData,
    };
    let json = serde_json::to_vec(&message)
        .map_err(|e| format!("encode keyboard keymap failed: {}", e))?;
    send_msl_control_frame(sink, stream, &json)
}

fn default_xkb_keymap() -> &'static str {
    r#"xkb_keymap {
xkb_keycodes "evdev+aliases(qwerty)" {
    minimum = 8;
    maximum = 255;
    <ESC> = 9;
    <AE01> = 10;
    <AE02> = 11;
    <AE03> = 12;
    <AE04> = 13;
    <AE05> = 14;
    <AE06> = 15;
    <AE07> = 16;
    <AE08> = 17;
    <AE09> = 18;
    <AE10> = 19;
    <AE11> = 20;
    <AE12> = 21;
    <BKSP> = 22;
    <TAB> = 23;
    <AD01> = 24;
    <AD02> = 25;
    <AD03> = 26;
    <AD04> = 27;
    <AD05> = 28;
    <AD06> = 29;
    <AD07> = 30;
    <AD08> = 31;
    <AD09> = 32;
    <AD10> = 33;
    <AD11> = 34;
    <AD12> = 35;
    <RTRN> = 36;
    <LCTL> = 37;
    <AC01> = 38;
    <AC02> = 39;
    <AC03> = 40;
    <AC04> = 41;
    <AC05> = 42;
    <AC06> = 43;
    <AC07> = 44;
    <AC08> = 45;
    <AC09> = 46;
    <AC10> = 47;
    <AC11> = 48;
    <LFSH> = 50;
    <AB01> = 52;
    <AB02> = 53;
    <AB03> = 54;
    <AB04> = 55;
    <AB05> = 56;
    <AB06> = 57;
    <AB07> = 58;
    <AB08> = 59;
    <AB09> = 60;
    <AB10> = 61;
    <RTSH> = 62;
    <LALT> = 64;
    <SPCE> = 65;
    <CAPS> = 66;
    <FK01> = 67;
    <FK02> = 68;
    <FK03> = 69;
    <FK04> = 70;
    <FK05> = 71;
    <FK06> = 72;
    <FK07> = 73;
    <FK08> = 74;
    <FK09> = 75;
    <FK10> = 76;
    <FK11> = 95;
    <FK12> = 96;
    <RCTL> = 105;
    <RALT> = 108;
    <LEFT> = 113;
    <RGHT> = 114;
    <END> = 115;
    <HOME> = 110;
    <UP> = 111;
    <DOWN> = 116;
    <PGUP> = 112;
    <PGDN> = 117;
};
xkb_types "complete" { include "complete" };
xkb_compatibility "complete" { include "complete" };
xkb_symbols "pc+us" { include "pc+us" };
xkb_geometry "pc(pc105)" { include "pc(pc105)" };
};
"#
}

fn push_u32(bytes: &mut Vec<u8>, value: u32) {
    bytes.extend_from_slice(&value.to_ne_bytes());
}

fn push_wayland_string(bytes: &mut Vec<u8>, value: &str) {
    let len = value.len() + 1;
    push_u32(bytes, len as u32);
    bytes.extend_from_slice(value.as_bytes());
    bytes.push(0);
    while bytes.len() % 4 != 0 {
        bytes.push(0);
    }
}

fn send_registry_global(
    sink: &CallbackSink,
    stream: &mut std::fs::File,
    registry_id: u32,
    global: &WaylandGlobal,
) -> Result<(), String> {
    let mut body = Vec::new();
    push_u32(&mut body, global.name);
    push_wayland_string(&mut body, global.interface);
    push_u32(&mut body, global.version);
    send_event(sink, stream, registry_id, 0, &body)
}

fn send_wl_callback_done(
    sink: &CallbackSink,
    stream: &mut std::fs::File,
    callback_id: u32,
    serial: u32,
) -> Result<(), String> {
    let mut body = Vec::new();
    push_u32(&mut body, serial);
    send_event(sink, stream, callback_id, 0, &body)
}

fn send_xdg_toplevel_configure(
    sink: &CallbackSink,
    stream: &mut std::fs::File,
    toplevel_id: u32,
    width: i32,
    height: i32,
) -> Result<(), String> {
    let mut body = Vec::new();
    push_u32(&mut body, width as u32);
    push_u32(&mut body, height as u32);
    push_u32(&mut body, 0);
    send_event(sink, stream, toplevel_id, 0, &body)
}

fn send_xdg_surface_configure(
    sink: &CallbackSink,
    stream: &mut std::fs::File,
    xdg_surface_id: u32,
    serial: u32,
) -> Result<(), String> {
    let mut body = Vec::new();
    push_u32(&mut body, serial);
    send_event(sink, stream, xdg_surface_id, 0, &body)
}

fn send_xdg_popup_configure(
    sink: &CallbackSink,
    stream: &mut std::fs::File,
    popup_id: u32,
    x: i32,
    y: i32,
    width: i32,
    height: i32,
) -> Result<(), String> {
    let mut body = Vec::new();
    push_u32(&mut body, x as u32);
    push_u32(&mut body, y as u32);
    push_u32(&mut body, width.max(1) as u32);
    push_u32(&mut body, height.max(1) as u32);
    send_event(sink, stream, popup_id, 0, &body)
}

fn send_wl_shm_format(
    sink: &CallbackSink,
    stream: &mut std::fs::File,
    shm_id: u32,
    format: u32,
) -> Result<(), String> {
    let mut body = Vec::new();
    push_u32(&mut body, format);
    send_event(sink, stream, shm_id, 0, &body)
}

fn send_wl_seat_capabilities(
    sink: &CallbackSink,
    stream: &mut std::fs::File,
    seat_id: u32,
    capabilities: u32,
) -> Result<(), String> {
    let mut body = Vec::new();
    push_u32(&mut body, capabilities);
    send_event(sink, stream, seat_id, 0, &body)
}

fn send_wl_seat_name(
    sink: &CallbackSink,
    stream: &mut std::fs::File,
    seat_id: u32,
    name: &str,
) -> Result<(), String> {
    let mut body = Vec::new();
    push_wayland_string(&mut body, name);
    send_event(sink, stream, seat_id, 1, &body)
}

fn send_wl_keyboard_repeat_info(
    sink: &CallbackSink,
    stream: &mut std::fs::File,
    keyboard_id: u32,
    rate: i32,
    delay: i32,
) -> Result<(), String> {
    let mut body = Vec::new();
    push_u32(&mut body, rate as u32);
    push_u32(&mut body, delay as u32);
    send_event(sink, stream, keyboard_id, 5, &body)
}

fn send_wl_buffer_release(
    sink: &CallbackSink,
    stream: &mut std::fs::File,
    buffer_id: u32,
) -> Result<(), String> {
    send_event(sink, stream, buffer_id, 0, &[])
}

fn fixed_from_f64(value: f64) -> u32 {
    ((value * 256.0).round() as i32) as u32
}

fn send_wl_pointer_enter(
    sink: &CallbackSink,
    stream: &mut std::fs::File,
    pointer_id: u32,
    serial: u32,
    surface_id: u32,
    x: f64,
    y: f64,
) -> Result<(), String> {
    let mut body = Vec::new();
    push_u32(&mut body, serial);
    push_u32(&mut body, surface_id);
    push_u32(&mut body, fixed_from_f64(x));
    push_u32(&mut body, fixed_from_f64(y));
    send_event(sink, stream, pointer_id, 0, &body)
}

fn send_wl_pointer_leave(
    sink: &CallbackSink,
    stream: &mut std::fs::File,
    pointer_id: u32,
    serial: u32,
    surface_id: u32,
) -> Result<(), String> {
    let mut body = Vec::new();
    push_u32(&mut body, serial);
    push_u32(&mut body, surface_id);
    send_event(sink, stream, pointer_id, 1, &body)
}

fn send_wl_pointer_motion(
    sink: &CallbackSink,
    stream: &mut std::fs::File,
    pointer_id: u32,
    timestamp_ms: u32,
    x: f64,
    y: f64,
) -> Result<(), String> {
    let mut body = Vec::new();
    push_u32(&mut body, timestamp_ms);
    push_u32(&mut body, fixed_from_f64(x));
    push_u32(&mut body, fixed_from_f64(y));
    send_event(sink, stream, pointer_id, 2, &body)
}

fn send_wl_pointer_button(
    sink: &CallbackSink,
    stream: &mut std::fs::File,
    pointer_id: u32,
    serial: u32,
    timestamp_ms: u32,
    button: u32,
    state: u32,
) -> Result<(), String> {
    let mut body = Vec::new();
    push_u32(&mut body, serial);
    push_u32(&mut body, timestamp_ms);
    push_u32(&mut body, button);
    push_u32(&mut body, state);
    send_event(sink, stream, pointer_id, 3, &body)
}

fn send_wl_pointer_axis(
    sink: &CallbackSink,
    stream: &mut std::fs::File,
    pointer_id: u32,
    timestamp_ms: u32,
    axis: u32,
    value: f64,
) -> Result<(), String> {
    let mut body = Vec::new();
    push_u32(&mut body, timestamp_ms);
    push_u32(&mut body, axis);
    push_u32(&mut body, fixed_from_f64(value));
    send_event(sink, stream, pointer_id, 4, &body)
}

fn send_wl_pointer_frame(
    sink: &CallbackSink,
    stream: &mut std::fs::File,
    pointer_id: u32,
) -> Result<(), String> {
    send_event(sink, stream, pointer_id, 5, &[])
}

fn send_wl_keyboard_enter(
    sink: &CallbackSink,
    stream: &mut std::fs::File,
    keyboard_id: u32,
    serial: u32,
    surface_id: u32,
) -> Result<(), String> {
    let mut body = Vec::new();
    push_u32(&mut body, serial);
    push_u32(&mut body, surface_id);
    push_u32(&mut body, 0);
    sink.log(&format!(
        "wl_keyboard_enter_sent keyboard={} surface={} serial={}",
        keyboard_id, surface_id, serial
    ));
    send_event(sink, stream, keyboard_id, 1, &body)
}

fn send_wl_keyboard_leave(
    sink: &CallbackSink,
    stream: &mut std::fs::File,
    keyboard_id: u32,
    serial: u32,
    surface_id: u32,
) -> Result<(), String> {
    let mut body = Vec::new();
    push_u32(&mut body, serial);
    push_u32(&mut body, surface_id);
    send_event(sink, stream, keyboard_id, 2, &body)
}

fn send_wl_keyboard_key(
    sink: &CallbackSink,
    stream: &mut std::fs::File,
    keyboard_id: u32,
    serial: u32,
    timestamp_ms: u32,
    keycode: u32,
    state: u32,
) -> Result<(), String> {
    let mut body = Vec::new();
    push_u32(&mut body, serial);
    push_u32(&mut body, timestamp_ms);
    push_u32(&mut body, keycode);
    push_u32(&mut body, state);
    sink.log(&format!(
        "wl_keyboard_key_sent keyboard={} keycode={} state={} serial={} time={}",
        keyboard_id, keycode, state, serial, timestamp_ms
    ));
    send_event(sink, stream, keyboard_id, 3, &body)
}

fn send_wl_keyboard_modifiers(
    sink: &CallbackSink,
    stream: &mut std::fs::File,
    keyboard_id: u32,
    serial: u32,
    depressed: u32,
) -> Result<(), String> {
    let mut body = Vec::new();
    push_u32(&mut body, serial);
    push_u32(&mut body, depressed);
    push_u32(&mut body, 0);
    push_u32(&mut body, 0);
    push_u32(&mut body, 0);
    sink.log(&format!(
        "wl_keyboard_modifiers_sent keyboard={} depressed={} serial={}",
        keyboard_id, depressed, serial
    ));
    send_event(sink, stream, keyboard_id, 4, &body)
}

fn send_text_input_enter(
    sink: &CallbackSink,
    stream: &mut std::fs::File,
    text_input_id: u32,
    surface_id: u32,
) -> Result<(), String> {
    let mut body = Vec::new();
    push_u32(&mut body, surface_id);
    send_event(sink, stream, text_input_id, 0, &body)
}

fn send_text_input_leave(
    sink: &CallbackSink,
    stream: &mut std::fs::File,
    text_input_id: u32,
    surface_id: u32,
) -> Result<(), String> {
    let mut body = Vec::new();
    push_u32(&mut body, surface_id);
    send_event(sink, stream, text_input_id, 1, &body)
}

fn send_text_input_preedit_string(
    sink: &CallbackSink,
    stream: &mut std::fs::File,
    text_input_id: u32,
    text: &str,
    cursor_begin: i32,
    cursor_end: i32,
) -> Result<(), String> {
    let mut body = Vec::new();
    push_wayland_string(&mut body, text);
    push_u32(&mut body, cursor_begin as u32);
    push_u32(&mut body, cursor_end as u32);
    send_event(sink, stream, text_input_id, 2, &body)
}

fn send_text_input_commit_string(
    sink: &CallbackSink,
    stream: &mut std::fs::File,
    text_input_id: u32,
    text: &str,
) -> Result<(), String> {
    let mut body = Vec::new();
    push_wayland_string(&mut body, text);
    send_event(sink, stream, text_input_id, 3, &body)
}

fn send_text_input_delete_surrounding_text(
    sink: &CallbackSink,
    stream: &mut std::fs::File,
    text_input_id: u32,
    before_length: u32,
    after_length: u32,
) -> Result<(), String> {
    let mut body = Vec::new();
    push_u32(&mut body, before_length);
    push_u32(&mut body, after_length);
    send_event(sink, stream, text_input_id, 4, &body)
}

fn send_text_input_done(
    sink: &CallbackSink,
    stream: &mut std::fs::File,
    text_input_id: u32,
    serial: u32,
) -> Result<(), String> {
    let mut body = Vec::new();
    push_u32(&mut body, serial);
    send_event(sink, stream, text_input_id, 5, &body)
}

fn ensure_keyboard_focus(
    sink: &CallbackSink,
    stream: &mut std::fs::File,
    state: &mut MiniWaylandState,
) -> Result<(), String> {
    if !state.desired_keyboard_focus {
        return Ok(());
    }
    let Some(keyboard_id) = state.keyboard_object else {
        sink.log("wayland_focus_deferred reason=no_keyboard_object");
        return Ok(());
    };
    let Some(surface_id) = state.active_surface else {
        sink.log("wayland_focus_deferred reason=no_active_surface");
        return Ok(());
    };
    if state.keyboard_focused_surface == Some(surface_id) {
        return Ok(());
    }
    let serial = state.next_serial();
    send_wl_keyboard_enter(sink, stream, keyboard_id, serial, surface_id)?;
    let modifier_serial = state.next_serial();
    send_wl_keyboard_modifiers(
        sink,
        stream,
        keyboard_id,
        modifier_serial,
        state.keyboard_modifiers,
    )?;
    state.keyboard_focused_surface = Some(surface_id);
    for (text_input_id, text_input) in state.text_inputs.iter_mut() {
        text_input.entered_surface = Some(surface_id);
        send_text_input_enter(sink, stream, *text_input_id, surface_id)?;
    }
    sink.log(&format!(
        "wayland_keyboard_focus_sent surface={} keyboard={} serial={}",
        surface_id, keyboard_id, serial
    ));
    Ok(())
}

#[derive(Serialize)]
struct IMEEnvelope<'a> {
    kind: &'static str,
    #[serde(rename = "imeState")]
    ime_state: IMEPayload<'a>,
}

#[derive(Serialize)]
struct IMEPayload<'a> {
    #[serde(rename = "sessionId")]
    session_id: &'a str,
    enabled: bool,
    #[serde(rename = "surroundingText")]
    surrounding_text: &'a str,
    #[serde(rename = "cursorUTF16Offset")]
    cursor_utf16_offset: usize,
    #[serde(rename = "anchorUTF16Offset")]
    anchor_utf16_offset: usize,
    preedit: Option<&'a str>,
    committed: Option<&'a str>,
    #[serde(rename = "deleteLeftUTF16Count")]
    delete_left_utf16_count: usize,
    #[serde(rename = "deleteRightUTF16Count")]
    delete_right_utf16_count: usize,
    #[serde(rename = "cursorRect")]
    cursor_rect: IMECursorRect,
}

#[derive(Serialize)]
struct IMECursorRect {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
}

fn utf8_offset_to_utf16(text: &str, offset: i32) -> usize {
    let offset = offset.max(0) as usize;
    let boundary = offset.min(text.len());
    let boundary = text
        .char_indices()
        .map(|(index, _)| index)
        .take_while(|index| *index <= boundary)
        .last()
        .unwrap_or(0);
    text[..boundary].encode_utf16().count()
}

fn utf16_offset_to_utf8(text: &str, offset: usize) -> usize {
    let mut consumed = 0;
    for (index, ch) in text.char_indices() {
        if consumed >= offset {
            return index;
        }
        consumed += ch.len_utf16();
    }
    text.len()
}

fn active_text_input(state: &MiniWaylandState) -> Option<(u32, &TextInputState)> {
    state
        .text_inputs
        .iter()
        .find(|(_, text_input)| text_input.enabled)
        .map(|(id, text_input)| (*id, text_input))
}

fn emit_text_input_state(sink: &CallbackSink, state: &MiniWaylandState) {
    let Some((_, text_input)) = active_text_input(state) else {
        let envelope = IMEEnvelope {
            kind: "imeState",
            ime_state: IMEPayload {
                session_id: &state.session_id,
                enabled: false,
                surrounding_text: "",
                cursor_utf16_offset: 0,
                anchor_utf16_offset: 0,
                preedit: None,
                committed: None,
                delete_left_utf16_count: 0,
                delete_right_utf16_count: 0,
                cursor_rect: IMECursorRect {
                    x: 0,
                    y: 0,
                    width: 0,
                    height: 0,
                },
            },
        };
        if let Ok(payload) = serde_json::to_vec(&envelope) {
            sink.emit_ime_state(&payload);
        }
        return;
    };
    let envelope = IMEEnvelope {
        kind: "imeState",
        ime_state: IMEPayload {
            session_id: &state.session_id,
            enabled: text_input.enabled,
            surrounding_text: &text_input.surrounding_text,
            cursor_utf16_offset: utf8_offset_to_utf16(
                &text_input.surrounding_text,
                text_input.cursor_utf8_offset,
            ),
            anchor_utf16_offset: utf8_offset_to_utf16(
                &text_input.surrounding_text,
                text_input.anchor_utf8_offset,
            ),
            preedit: None,
            committed: None,
            delete_left_utf16_count: 0,
            delete_right_utf16_count: 0,
            cursor_rect: IMECursorRect {
                x: text_input.cursor_rect.0,
                y: text_input.cursor_rect.1,
                width: text_input.cursor_rect.2,
                height: text_input.cursor_rect.3,
            },
        },
    };
    if let Ok(payload) = serde_json::to_vec(&envelope) {
        sink.emit_ime_state(&payload);
    }
}

fn send_text_input_to_display(
    sink: &CallbackSink,
    display: &DisplayEndpoint,
    payload: &[u8],
) -> Result<(), String> {
    let envelope: TextInputEnvelope = serde_json::from_slice(payload)
        .map_err(|error| format!("decode text input payload failed: {error}"))?;
    let mut state = display
        .state
        .lock()
        .map_err(|_| "wayland state lock poisoned".to_string())?;
    let Some((text_input_id, text_input)) = active_text_input(&state) else {
        sink.log(&format!(
            "wayland_text_input_dropped session={} reason=no_enabled_text_input",
            envelope.ime_state.session_id
        ));
        return Ok(());
    };
    let text_input_id = text_input_id;
    let surrounding_text = text_input.surrounding_text.clone();
    let seat_id = text_input.seat_id;
    let mut stream = display
        .stream
        .lock()
        .map_err(|_| "display stream lock poisoned".to_string())?;
    if envelope.ime_state.delete_left_utf16_count > 0 || envelope.ime_state.delete_right_utf16_count > 0 {
        let cursor_utf16 = utf8_offset_to_utf16(&surrounding_text, text_input.cursor_utf8_offset);
        let before = delete_before_utf16_to_utf8_bytes(
            &surrounding_text,
            cursor_utf16,
            envelope.ime_state.delete_left_utf16_count,
        );
        let after = delete_after_utf16_to_utf8_bytes(
            &surrounding_text,
            cursor_utf16,
            envelope.ime_state.delete_right_utf16_count,
        );
        send_text_input_delete_surrounding_text(
            sink,
            &mut stream,
            text_input_id,
            before as u32,
            after as u32,
        )?;
    }
    if let Some(preedit) = envelope.ime_state.preedit.as_deref() {
        let begin = utf16_offset_to_utf8(
            preedit,
            envelope
                .ime_state
                .preedit_cursor_begin_utf16
                .unwrap_or_else(|| preedit.encode_utf16().count()),
        ) as i32;
        let end = utf16_offset_to_utf8(
            preedit,
            envelope
                .ime_state
                .preedit_cursor_end_utf16
                .unwrap_or_else(|| preedit.encode_utf16().count()),
        ) as i32;
        send_text_input_preedit_string(sink, &mut stream, text_input_id, preedit, begin, end)?;
    }
    if let Some(committed) = envelope.ime_state.committed.as_deref() {
        if !committed.is_empty() {
            send_text_input_commit_string(sink, &mut stream, text_input_id, committed)?;
        }
    }
    let serial = state.next_serial();
    send_text_input_done(sink, &mut stream, text_input_id, serial)?;
    if let Some(text_input) = state.text_inputs.get_mut(&text_input_id) {
        text_input.surrounding_text = envelope.ime_state.surrounding_text;
        text_input.cursor_utf8_offset =
            utf16_offset_to_utf8(&text_input.surrounding_text, envelope.ime_state.cursor_utf16_offset) as i32;
        text_input.anchor_utf8_offset =
            utf16_offset_to_utf8(&text_input.surrounding_text, envelope.ime_state.anchor_utf16_offset) as i32;
    }
    sink.log(&format!(
        "wayland_text_input_sent object={} seat={} serial={} enabled={} preedit={} committed={} surrounding_bytes={}",
        text_input_id,
        seat_id,
        serial,
        envelope.ime_state.enabled,
        envelope.ime_state.preedit.as_deref().unwrap_or("").len(),
        envelope.ime_state.committed.as_deref().unwrap_or("").len(),
        surrounding_text.len()
    ));
    Ok(())
}

fn delete_before_utf16_to_utf8_bytes(text: &str, cursor_utf16: usize, count_utf16: usize) -> usize {
    let cursor = utf16_offset_to_utf8(text, cursor_utf16);
    let start = utf16_offset_to_utf8(text, cursor_utf16.saturating_sub(count_utf16));
    cursor.saturating_sub(start)
}

fn delete_after_utf16_to_utf8_bytes(text: &str, cursor_utf16: usize, count_utf16: usize) -> usize {
    let cursor = utf16_offset_to_utf8(text, cursor_utf16);
    let end = utf16_offset_to_utf8(text, cursor_utf16.saturating_add(count_utf16));
    end.saturating_sub(cursor)
}

fn xkb_modifiers_from_appkit_bits(modifiers: u32) -> u32 {
    let mut xkb = 0;
    if modifiers & (1 << 0) != 0 {
        xkb |= 1 << 0; // Shift
    }
    if modifiers & (1 << 1) != 0 {
        xkb |= 1 << 2; // Control
    }
    if modifiers & (1 << 2) != 0 {
        xkb |= 1 << 3; // Alt/Mod1
    }
    if modifiers & (1 << 3) != 0 {
        xkb |= 1 << 6; // Super
    }
    xkb
}

fn send_xdg_toplevel_close(
    sink: &CallbackSink,
    stream: &mut std::fs::File,
    toplevel_id: u32,
) -> Result<(), String> {
    send_event(sink, stream, toplevel_id, 2, &[])
}

fn send_configure_to_display(
    sink: &CallbackSink,
    display: &DisplayEndpoint,
    width: i32,
    height: i32,
) -> Result<(), String> {
    let mut state = display
        .state
        .lock()
        .map_err(|_| "wayland state lock poisoned".to_string())?;
    let Some(toplevel_id) = state.active_toplevel else {
        sink.log("wayland_configure_dropped reason=no_active_toplevel");
        return Ok(());
    };
    let Some(xdg_surface_id) = state.xdg_toplevels.get(&toplevel_id).copied() else {
        sink.log("wayland_configure_dropped reason=no_xdg_surface");
        return Ok(());
    };
    let (client_width, client_height) = configured_client_size(&state, width.max(1), height.max(1));
    let serial = state.next_serial();
    let mut stream = display
        .stream
        .lock()
        .map_err(|_| "display stream lock poisoned".to_string())?;
    send_xdg_toplevel_configure(sink, &mut stream, toplevel_id, client_width, client_height)?;
    send_xdg_surface_configure(sink, &mut stream, xdg_surface_id, serial)?;
    sink.log(&format!(
        "wayland_configure_sent toplevel={} xdg_surface={} width={} height={} host_width={} host_height={} serial={}",
        toplevel_id,
        xdg_surface_id,
        client_width,
        client_height,
        width.max(1),
        height.max(1),
        serial
    ));
    Ok(())
}

fn configured_client_size(state: &MiniWaylandState, host_width: i32, host_height: i32) -> (i32, i32) {
    let Some(surface_id) = state.active_surface else {
        return (host_width, host_height);
    };
    let Some(surface) = state.surfaces.get(&surface_id) else {
        return (host_width, host_height);
    };
    let Some(geometry) = surface.window_geometry else {
        return (host_width, host_height);
    };
    let Some(frame) = state.surface_frames.get(&surface_id) else {
        return (host_width, host_height);
    };
    let right = (frame.width - geometry.x - geometry.width).max(0);
    let bottom = (frame.height - geometry.y - geometry.height).max(0);
    (
        (host_width - geometry.x.max(0) - right).max(1),
        (host_height - geometry.y.max(0) - bottom).max(1),
    )
}

fn send_pointer_to_display(
    sink: &CallbackSink,
    display: &DisplayEndpoint,
    command: PointerCommand,
) -> Result<(), String> {
    let mut state = display
        .state
        .lock()
        .map_err(|_| "wayland state lock poisoned".to_string())?;
    let Some(pointer_id) = state.pointer_object else {
        sink.log("wayland_pointer_event_dropped reason=no_pointer_object");
        return Ok(());
    };
    let Some(surface_id) = state.active_surface else {
        sink.log("wayland_pointer_event_dropped reason=no_active_surface");
        return Ok(());
    };
    let mut stream = display
        .stream
        .lock()
        .map_err(|_| "display stream lock poisoned".to_string())?;
    state.pointer_x = command.x;
    state.pointer_y = command.y;
    match command.kind {
        0 => {
            if state.pointer_entered_surface != Some(surface_id) {
                let serial = state.next_serial();
                send_wl_pointer_enter(
                    sink,
                    &mut stream,
                    pointer_id,
                    serial,
                    surface_id,
                    command.x,
                    command.y,
                )?;
                state.pointer_entered_surface = Some(surface_id);
            }
            send_wl_pointer_motion(
                sink,
                &mut stream,
                pointer_id,
                command.timestamp_ms,
                command.x,
                command.y,
            )?;
            send_wl_pointer_frame(sink, &mut stream, pointer_id)?;
        }
        1 | 2 => {
            if state.pointer_entered_surface != Some(surface_id) {
                let serial = state.next_serial();
                send_wl_pointer_enter(
                    sink,
                    &mut stream,
                    pointer_id,
                    serial,
                    surface_id,
                    command.x,
                    command.y,
                )?;
                state.pointer_entered_surface = Some(surface_id);
            }
            let serial = state.next_serial();
            send_wl_pointer_button(
                sink,
                &mut stream,
                pointer_id,
                serial,
                command.timestamp_ms,
                command.button,
                if command.kind == 1 { 1 } else { 0 },
            )?;
            send_wl_pointer_frame(sink, &mut stream, pointer_id)?;
        }
        3 => {
            if command.axis_x != 0.0 {
                send_wl_pointer_axis(sink, &mut stream, pointer_id, command.timestamp_ms, 0, command.axis_x)?;
            }
            if command.axis_y != 0.0 {
                send_wl_pointer_axis(sink, &mut stream, pointer_id, command.timestamp_ms, 1, command.axis_y)?;
            }
            send_wl_pointer_frame(sink, &mut stream, pointer_id)?;
        }
        4 => {
            if state.pointer_entered_surface == Some(surface_id) {
                let serial = state.next_serial();
                send_wl_pointer_leave(sink, &mut stream, pointer_id, serial, surface_id)?;
                state.pointer_entered_surface = None;
            }
        }
        _ => sink.log(&format!("wayland_pointer_event_dropped reason=unknown_kind kind={}", command.kind)),
    }
    sink.log(&format!(
        "wayland_pointer_event_sent kind={} surface={} pointer={} x={} y={} button={} modifiers={}",
        command.kind, surface_id, pointer_id, command.x, command.y, command.button, command.modifiers
    ));
    Ok(())
}

fn send_keyboard_to_display(
    sink: &CallbackSink,
    display: &DisplayEndpoint,
    command: KeyboardCommand,
) -> Result<(), String> {
    let mut state = display
        .state
        .lock()
        .map_err(|_| "wayland state lock poisoned".to_string())?;
    state.last_keyboard_trace_id = Some(command.trace_id.clone());
    let Some(keyboard_id) = state.keyboard_object else {
        state.last_keyboard_drop_reason = Some("no_keyboard_object".to_string());
        sink.log(&format!(
            "wayland_keyboard_event_dropped trace_id={} reason=no_keyboard_object",
            command.trace_id
        ));
        return Ok(());
    };
    let Some(surface_id) = state.active_surface else {
        state.last_keyboard_drop_reason = Some("no_active_surface".to_string());
        sink.log(&format!(
            "wayland_keyboard_event_dropped trace_id={} reason=no_active_surface",
            command.trace_id
        ));
        return Ok(());
    };
    let mut stream = display
        .stream
        .lock()
        .map_err(|_| "display stream lock poisoned".to_string())?;
    state.desired_keyboard_focus = true;
    ensure_keyboard_focus(sink, &mut stream, &mut state)?;
    let next_modifiers = xkb_modifiers_from_appkit_bits(command.modifiers);
    if state.keyboard_modifiers != next_modifiers {
        state.keyboard_modifiers = next_modifiers;
        send_wl_keyboard_modifiers(
            sink,
            &mut stream,
            keyboard_id,
            state.next_serial(),
            next_modifiers,
        )?;
    }
    if command.kind == 2 {
        state.last_keyboard_drop_reason = None;
        sink.log(&format!(
            "wayland_keyboard_modifiers_sent trace_id={} surface={} keyboard={} modifiers={} xkb_modifiers={}",
            command.trace_id, surface_id, keyboard_id, command.modifiers, state.keyboard_modifiers
        ));
        return Ok(());
    }
    let serial = state.next_serial();
    state.last_key_serial = Some(serial);
    state.last_keycode = Some(command.keycode);
    state.last_keyboard_drop_reason = None;
    send_wl_keyboard_key(
        sink,
        &mut stream,
        keyboard_id,
        serial,
        command.timestamp_ms,
        command.keycode,
        if command.kind == 1 { 1 } else { 0 },
    )?;
    sink.log(&format!(
        "wayland_keyboard_event_sent trace_id={} kind={} surface={} keyboard={} keycode={} serial={} modifiers={} xkb_modifiers={}",
        command.trace_id, command.kind, surface_id, keyboard_id, command.keycode, serial, command.modifiers, state.keyboard_modifiers
    ));
    Ok(())
}

fn send_focus_to_display(
    sink: &CallbackSink,
    display: &DisplayEndpoint,
    focused: bool,
) -> Result<(), String> {
    let mut state = display
        .state
        .lock()
        .map_err(|_| "wayland state lock poisoned".to_string())?;
    state.desired_keyboard_focus = focused;
    let Some(keyboard_id) = state.keyboard_object else {
        sink.log("wayland_focus_deferred reason=no_keyboard_object");
        return Ok(());
    };
    let Some(surface_id) = state.active_surface else {
        sink.log("wayland_focus_deferred reason=no_active_surface");
        return Ok(());
    };
    let mut stream = display
        .stream
        .lock()
        .map_err(|_| "display stream lock poisoned".to_string())?;
    if focused && state.keyboard_focused_surface != Some(surface_id) {
        ensure_keyboard_focus(sink, &mut stream, &mut state)?;
    } else if !focused && state.keyboard_focused_surface == Some(surface_id) {
        let serial = state.next_serial();
        send_wl_keyboard_leave(sink, &mut stream, keyboard_id, serial, surface_id)?;
        for (text_input_id, text_input) in state.text_inputs.iter_mut() {
            if text_input.entered_surface == Some(surface_id) {
                send_text_input_leave(sink, &mut stream, *text_input_id, surface_id)?;
                text_input.entered_surface = None;
            }
        }
        state.keyboard_focused_surface = None;
    }
    sink.log(&format!(
        "wayland_focus_event_sent focused={} surface={} keyboard={}",
        focused, surface_id, keyboard_id
    ));
    Ok(())
}

fn send_toplevel_close_to_display(
    sink: &CallbackSink,
    display: &DisplayEndpoint,
) -> Result<(), String> {
    let state = display
        .state
        .lock()
        .map_err(|_| "wayland state lock poisoned".to_string())?;
    let Some(toplevel_id) = state.active_toplevel else {
        sink.log("wayland_toplevel_close_dropped reason=no_active_toplevel");
        return Ok(());
    };
    let mut stream = display
        .stream
        .lock()
        .map_err(|_| "display stream lock poisoned".to_string())?;
    send_xdg_toplevel_close(sink, &mut stream, toplevel_id)?;
    sink.log(&format!("wayland_toplevel_close_sent toplevel={}", toplevel_id));
    Ok(())
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
    unsafe { CStr::from_ptr(value) }
        .to_str()
        .ok()
        .map(ToOwned::to_owned)
}

fn epoch_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|value| value.as_millis() as i64)
        .unwrap_or_default()
}

fn extract_shm_frame(
    session_id: String,
    width: i32,
    height: i32,
    stride: i32,
    format: &str,
    damage_rects: Vec<TransportDamageRect>,
    data_base64: &str,
) -> Result<ExtractedShmFrame, String> {
    if width <= 0 || height <= 0 {
        return Err("invalid shm frame geometry".to_string());
    }
    let minimum_stride = width
        .checked_mul(4)
        .ok_or_else(|| "shm frame stride overflow".to_string())?;
    if stride < minimum_stride {
        return Err(format!("invalid shm stride {} for width {}", stride, width));
    }
    let expected_len = (stride as usize)
        .checked_mul(height as usize)
        .ok_or_else(|| "shm frame byte size overflow".to_string())?;
    let pixel_format = match format {
        "argb8888" | "ARGB8888" => ShmPixelFormat::Argb8888,
        "xrgb8888" | "XRGB8888" => ShmPixelFormat::Xrgb8888,
        other => return Err(format!("unsupported shm format {}", other)),
    };
    let mut pixels = base64_decode(data_base64)?;
    if pixels.len() < expected_len {
        return Err(format!(
            "shm payload too small: got {} expected {}",
            pixels.len(),
            expected_len
        ));
    }
    pixels.truncate(expected_len);
    if pixel_format == ShmPixelFormat::Xrgb8888 {
        for pixel in pixels.chunks_exact_mut(4) {
            pixel[3] = 0xff;
        }
    }

    let mut rects = damage_rects
        .into_iter()
        .filter_map(|rect| clip_damage_rect(rect, width, height))
        .collect::<Vec<_>>();
    if rects.is_empty() {
        rects.push(DamageRect {
            x: 0,
            y: 0,
            width,
            height,
        });
    }

    Ok(ExtractedShmFrame {
        session_id,
        width,
        height,
        stride,
        pixel_format,
        damage_rects: rects,
        pixels,
    })
}

fn clip_damage_rect(rect: TransportDamageRect, width: i32, height: i32) -> Option<DamageRect> {
    let start_x = rect.x.max(0).min(width);
    let start_y = rect.y.max(0).min(height);
    let end_x = rect.x.saturating_add(rect.width).max(start_x).min(width);
    let end_y = rect.y.saturating_add(rect.height).max(start_y).min(height);
    if start_x >= end_x || start_y >= end_y {
        return None;
    }
    Some(DamageRect {
        x: start_x,
        y: start_y,
        width: end_x - start_x,
        height: end_y - start_y,
    })
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

fn base64_decode(value: &str) -> Result<Vec<u8>, String> {
    let mut out = Vec::with_capacity(value.len() / 4 * 3);
    let mut quartet = [0_u8; 4];
    let mut quartet_len = 0;
    for byte in value.bytes().filter(|byte| !byte.is_ascii_whitespace()) {
        let decoded = match byte {
            b'A'..=b'Z' => byte - b'A',
            b'a'..=b'z' => byte - b'a' + 26,
            b'0'..=b'9' => byte - b'0' + 52,
            b'+' => 62,
            b'/' => 63,
            b'=' => 64,
            _ => return Err("invalid base64 character".to_string()),
        };
        quartet[quartet_len] = decoded;
        quartet_len += 1;
        if quartet_len == 4 {
            if quartet[0] == 64 || quartet[1] == 64 {
                return Err("invalid base64 padding".to_string());
            }
            let n = ((quartet[0] as u32) << 18)
                | ((quartet[1] as u32) << 12)
                | ((quartet[2].min(63) as u32) << 6)
                | (quartet[3].min(63) as u32);
            out.push(((n >> 16) & 0xff) as u8);
            if quartet[2] != 64 {
                out.push(((n >> 8) & 0xff) as u8);
            }
            if quartet[3] != 64 {
                out.push((n & 0xff) as u8);
            }
            quartet_len = 0;
        }
    }
    if quartet_len != 0 {
        return Err("truncated base64 input".to_string());
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::fd::IntoRawFd;
    use std::os::unix::net::UnixStream;
    use std::sync::Mutex;
    use std::time::Duration;

    static TEST_SHARED_FRAME_LOCK: OnceLock<Mutex<()>> = OnceLock::new();

    fn shared_frame_test_guard() -> std::sync::MutexGuard<'static, ()> {
        TEST_SHARED_FRAME_LOCK
            .get_or_init(|| Mutex::new(()))
            .lock()
            .unwrap()
    }

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
        let message = unsafe { CStr::from_ptr(message) }
            .to_string_lossy()
            .into_owned();
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
        assert_eq!(base64_decode("Zm9v").unwrap(), b"foo");
    }

    #[test]
    fn extract_shm_frame_accepts_xrgb_and_clips_damage() {
        let pixels = vec![1, 2, 3, 0, 4, 5, 6, 0, 7, 8, 9, 0, 10, 11, 12, 0];
        let frame = extract_shm_frame(
            "session-a".to_string(),
            2,
            2,
            8,
            "xrgb8888",
            vec![TransportDamageRect {
                x: -1,
                y: 0,
                width: 2,
                height: 4,
            }],
            &base64_encode(&pixels),
        )
        .unwrap();

        assert_eq!(frame.session_id, "session-a");
        assert_eq!(frame.pixel_format, ShmPixelFormat::Xrgb8888);
        assert_eq!(frame.damage_rects.len(), 1);
        assert_eq!(frame.damage_rects[0].x, 0);
        assert_eq!(frame.damage_rects[0].y, 0);
        assert_eq!(frame.damage_rects[0].width, 1);
        assert_eq!(frame.damage_rects[0].height, 2);
        assert_eq!(frame.pixels[3], 0xff);
        assert_eq!(frame.pixels[7], 0xff);
    }

    #[test]
    fn display_transport_shm_frame_emits_swift_frame_envelope() {
        let recorder = Box::new(CallbackRecorder::default());
        let recorder_ptr = Box::into_raw(recorder);
        let callbacks = Arc::new(WaylandCoreCallbacks {
            on_frame: Some(on_frame),
            on_frame_shared: None,
            on_ime_state: Some(on_ime_state),
            on_log: Some(on_log),
            on_exit: Some(on_exit),
            on_cursor: None,
            on_window_event: None,
        });
        let sink = CallbackSink {
            callbacks,
            user_data: recorder_ptr as usize,
        };
        let message = serde_json::json!({
            "type": "shmFrame",
            "sessionId": "session-a",
            "width": 1,
            "height": 1,
            "stride": 4,
            "format": "argb8888",
            "damageRects": [{"x": 0, "y": 0, "width": 1, "height": 1}],
            "dataBase64": base64_encode(&[1, 2, 3, 4])
        });
        let payload = serde_json::to_vec(&message).unwrap();
        let mut pending = Vec::new();
        pending.extend_from_slice(&(payload.len() as u32).to_le_bytes());
        pending.extend_from_slice(&payload);
        let (_client, server) = UnixStream::pair().unwrap();
        let mut server_file = unsafe { std::fs::File::from_raw_fd(server.into_raw_fd()) };
        let mut wayland = MiniWaylandState::new();

        assert_eq!(
            drain_display_transport_messages(
                &sink,
                "fallback-session",
                &mut server_file,
                &mut wayland,
                &mut pending
            )
            .unwrap(),
            1
        );
        assert!(pending.is_empty());

        let recorder = unsafe { Box::from_raw(recorder_ptr) };
        let frames = recorder.frames.lock().unwrap();
        assert_eq!(frames.len(), 1);
        assert!(frames[0].contains("\"kind\":\"frame\""));
        assert!(frames[0].contains("\"sessionId\":\"session-a\""));
        assert!(frames[0].contains("\"pixelFormat\":\"bgra8888\""));
        assert!(frames[0].contains("\"dataBase64\":\"AQIDBA==\""));
    }

    #[test]
    fn shared_frame_writer_publishes_posix_shm_metadata_and_pixels() {
        let _guard = shared_frame_test_guard();
        cleanup_shared_frames();
        let frame = ExtractedShmFrame {
            session_id: "shared-session".to_string(),
            width: 1,
            height: 1,
            stride: 4,
            pixel_format: ShmPixelFormat::Argb8888,
            damage_rects: vec![DamageRect {
                x: 0,
                y: 0,
                width: 1,
                height: 1,
            }],
            pixels: vec![1, 2, 3, 4],
        };

        let shared = write_shared_frame(&frame).unwrap();
        assert_eq!(shared.width, 1);
        assert_eq!(shared.height, 1);
        assert_eq!(shared.pixel_format, "bgra8888");
        assert_eq!(shared.generation, 1);
        assert_eq!(shared.layout_generation, 1);
        assert!(shared.shm_name.starts_with("/msl-wl-"));

        let c_name = CString::new(shared.shm_name.clone()).unwrap();
        unsafe {
            let fd = libc::shm_open(c_name.as_ptr(), libc::O_RDONLY, 0);
            assert!(fd >= 0);
            let ptr = libc::mmap(
                std::ptr::null_mut(),
                shared.mapped_size,
                libc::PROT_READ,
                libc::MAP_SHARED,
                fd,
                0,
            );
            let _ = libc::close(fd);
            assert_ne!(ptr, libc::MAP_FAILED);
            let header = &*(ptr as *const SharedFrameHeader);
            assert_eq!(header.magic, SHARED_FRAME_MAGIC);
            assert_eq!(header.frame_generation, 1);
            assert_eq!(header.current_slot, shared.slot);
            let pixel_ptr = (ptr as *const u8).add(shared.slot_offset);
            assert_eq!(std::slice::from_raw_parts(pixel_ptr, 4), &[1, 2, 3, 4]);
            let _ = libc::munmap(ptr, shared.mapped_size);
        }
        cleanup_shared_frames();
    }

    #[test]
    fn wayland_shm_surface_commit_emits_frame() {
        let recorder = Box::new(CallbackRecorder::default());
        let recorder_ptr = Box::into_raw(recorder);
        let callbacks = Arc::new(WaylandCoreCallbacks {
            on_frame: Some(on_frame),
            on_frame_shared: None,
            on_ime_state: Some(on_ime_state),
            on_log: Some(on_log),
            on_exit: Some(on_exit),
            on_cursor: None,
            on_window_event: None,
        });
        let sink = CallbackSink {
            callbacks,
            user_data: recorder_ptr as usize,
        };
        let (_client, server) = UnixStream::pair().unwrap();
        let mut server_file = unsafe { std::fs::File::from_raw_fd(server.into_raw_fd()) };
        let mut state = MiniWaylandState::new();
        state.session_id = "session-frame".to_string();
        state.active_surface = Some(11);
        state.objects.insert(4, "wl_compositor".to_string());
        state.objects.insert(6, "wl_shm".to_string());
        let mut pending = Vec::new();
        append_transport_json(
            &mut pending,
            serde_json::json!({
                "type": "shmPoolCreate",
                "poolId": 9,
                "size": 4,
                "dataBase64": base64_encode(&[1, 2, 3, 4])
            }),
        );
        append_transport_json(
            &mut pending,
            serde_json::json!({
                "type": "waylandBytes",
                "dataBase64": base64_encode(&wayland_request(6, 0, &[9, 0, 0, 0, 4, 0, 0, 0]))
            }),
        );
        let mut create_buffer = Vec::new();
        create_buffer.extend_from_slice(&10_u32.to_ne_bytes());
        create_buffer.extend_from_slice(&0_i32.to_ne_bytes());
        create_buffer.extend_from_slice(&1_i32.to_ne_bytes());
        create_buffer.extend_from_slice(&1_i32.to_ne_bytes());
        create_buffer.extend_from_slice(&4_i32.to_ne_bytes());
        create_buffer.extend_from_slice(&0_u32.to_ne_bytes());
        append_transport_json(
            &mut pending,
            serde_json::json!({
                "type": "waylandBytes",
                "dataBase64": base64_encode(&wayland_request(9, 0, &create_buffer))
            }),
        );
        append_transport_json(
            &mut pending,
            serde_json::json!({
                "type": "waylandBytes",
                "dataBase64": base64_encode(&wayland_request(4, 0, &[11, 0, 0, 0]))
            }),
        );
        let mut attach = Vec::new();
        attach.extend_from_slice(&10_u32.to_ne_bytes());
        attach.extend_from_slice(&0_i32.to_ne_bytes());
        attach.extend_from_slice(&0_i32.to_ne_bytes());
        append_transport_json(
            &mut pending,
            serde_json::json!({
                "type": "waylandBytes",
                "dataBase64": base64_encode(&wayland_request(11, 1, &attach))
            }),
        );
        let mut damage = Vec::new();
        damage.extend_from_slice(&0_i32.to_ne_bytes());
        damage.extend_from_slice(&0_i32.to_ne_bytes());
        damage.extend_from_slice(&1_i32.to_ne_bytes());
        damage.extend_from_slice(&1_i32.to_ne_bytes());
        append_transport_json(
            &mut pending,
            serde_json::json!({
                "type": "waylandBytes",
                "dataBase64": base64_encode(&wayland_request(11, 2, &damage))
            }),
        );
        append_transport_json(
            &mut pending,
            serde_json::json!({
                "type": "waylandBytes",
                "dataBase64": base64_encode(&wayland_request(11, 6, &[]))
            }),
        );

        assert_eq!(
            drain_display_transport_messages(
                &sink,
                "fallback-session",
                &mut server_file,
                &mut state,
                &mut pending
            )
            .unwrap(),
            7
        );

        let recorder = unsafe { Box::from_raw(recorder_ptr) };
        let frames = recorder.frames.lock().unwrap();
        assert_eq!(frames.len(), 1);
        assert!(frames[0].contains("\"sessionId\":\"session-frame\""));
        assert!(frames[0].contains("\"width\":1"));
        assert!(frames[0].contains("\"height\":1"));
        assert!(frames[0].contains("\"dataBase64\":\"AQIDBA==\""));
    }

    #[test]
    fn surface_commit_releases_previous_buffer_not_current_buffer() {
        let recorder = Box::new(CallbackRecorder::default());
        let recorder_ptr = Box::into_raw(recorder);
        let callbacks = Arc::new(WaylandCoreCallbacks {
            on_frame: Some(on_frame),
            on_frame_shared: None,
            on_ime_state: Some(on_ime_state),
            on_log: Some(on_log),
            on_exit: Some(on_exit),
            on_cursor: None,
            on_window_event: None,
        });
        let sink = CallbackSink {
            callbacks,
            user_data: recorder_ptr as usize,
        };
        let (client, server) = UnixStream::pair().unwrap();
        client.set_nonblocking(true).unwrap();
        let mut server_file = unsafe { std::fs::File::from_raw_fd(server.into_raw_fd()) };
        let mut state = MiniWaylandState::new();
        state.session_id = "release-session".to_string();
        state.active_surface = Some(20);
        state.shm_pools.insert(
            1,
            ShmPool {
                size: 8,
                data: vec![1, 2, 3, 4, 5, 6, 7, 8],
            },
        );
        state.shm_buffers.insert(
            10,
            ShmBuffer {
                pool_id: 1,
                offset: 0,
                width: 1,
                height: 1,
                stride: 4,
                format: ShmPixelFormat::Argb8888,
            },
        );
        state.shm_buffers.insert(
            11,
            ShmBuffer {
                pool_id: 1,
                offset: 4,
                width: 1,
                height: 1,
                stride: 4,
                format: ShmPixelFormat::Argb8888,
            },
        );
        state.surfaces.insert(
            20,
            SurfaceState {
                pending_attach: PendingAttach::Attach(Some(10)),
                pending_damage: vec![DamageRect {
                    x: 0,
                    y: 0,
                    width: 1,
                    height: 1,
                }],
                ..SurfaceState::default()
            },
        );

        emit_surface_commit_frame(&sink, &mut server_file, &mut state, 20).unwrap();
        let mut bytes = [0_u8; 32];
        assert!(matches!(
            (&client).read(&mut bytes),
            Err(error) if error.kind() == std::io::ErrorKind::WouldBlock
        ));

        state.surfaces.get_mut(&20).unwrap().pending_attach = PendingAttach::Attach(Some(11));
        emit_surface_commit_frame(&sink, &mut server_file, &mut state, 20).unwrap();
        let count = (&client).read(&mut bytes).unwrap();
        assert_eq!(count, 8);
        assert_eq!(u32::from_ne_bytes(bytes[0..4].try_into().unwrap()), 10);
        assert_eq!(u16::from_ne_bytes(bytes[4..6].try_into().unwrap()), 0);

        let recorder = unsafe { Box::from_raw(recorder_ptr) };
        let frames = recorder.frames.lock().unwrap();
        assert_eq!(frames.len(), 2);
    }

    #[test]
    fn initial_no_buffer_commit_does_not_close_active_surface() {
        let recorder = Box::new(CallbackRecorder::default());
        let recorder_ptr = Box::into_raw(recorder);
        let callbacks = Arc::new(WaylandCoreCallbacks {
            on_frame: Some(on_frame),
            on_frame_shared: None,
            on_ime_state: Some(on_ime_state),
            on_log: Some(on_log),
            on_exit: Some(on_exit),
            on_cursor: None,
            on_window_event: None,
        });
        let sink = CallbackSink {
            callbacks,
            user_data: recorder_ptr as usize,
        };
        let (_client, server) = UnixStream::pair().unwrap();
        let mut server_file = unsafe { std::fs::File::from_raw_fd(server.into_raw_fd()) };
        let mut state = MiniWaylandState::new();
        state.session_id = "initial-commit-session".to_string();
        state.active_surface = Some(20);
        state.active_toplevel = Some(25);
        state.surfaces.insert(20, SurfaceState::default());

        emit_surface_commit_frame(&sink, &mut server_file, &mut state, 20).unwrap();

        assert_eq!(state.active_surface, Some(20));
        assert_eq!(state.active_toplevel, Some(25));
        let recorder = unsafe { Box::from_raw(recorder_ptr) };
        let logs = recorder.logs.lock().unwrap();
        assert!(logs
            .iter()
            .any(|line| line.contains("frame_skipped_no_buffer surface=20")));
        assert!(!logs
            .iter()
            .any(|line| line.contains("wayland_window_event")));
    }

    #[test]
    fn surface_attach_null_detaches_and_releases_current_buffer() {
        let recorder = Box::new(CallbackRecorder::default());
        let recorder_ptr = Box::into_raw(recorder);
        let callbacks = Arc::new(WaylandCoreCallbacks {
            on_frame: Some(on_frame),
            on_frame_shared: None,
            on_ime_state: Some(on_ime_state),
            on_log: Some(on_log),
            on_exit: Some(on_exit),
            on_cursor: None,
            on_window_event: None,
        });
        let sink = CallbackSink {
            callbacks,
            user_data: recorder_ptr as usize,
        };
        let (client, server) = UnixStream::pair().unwrap();
        client.set_nonblocking(true).unwrap();
        let mut server_file = unsafe { std::fs::File::from_raw_fd(server.into_raw_fd()) };
        let mut state = MiniWaylandState::new();
        state.session_id = "detach-session".to_string();
        state.active_surface = Some(20);
        state.active_toplevel = Some(25);
        state.shm_pools.insert(
            1,
            ShmPool {
                size: 4,
                data: vec![1, 2, 3, 4],
            },
        );
        state.shm_buffers.insert(
            10,
            ShmBuffer {
                pool_id: 1,
                offset: 0,
                width: 1,
                height: 1,
                stride: 4,
                format: ShmPixelFormat::Argb8888,
            },
        );
        state.surfaces.insert(
            20,
            SurfaceState {
                attached_buffer: Some(10),
                pending_attach: PendingAttach::Attach(None),
                ..SurfaceState::default()
            },
        );

        emit_surface_commit_frame(&sink, &mut server_file, &mut state, 20).unwrap();

        let mut bytes = [0_u8; 8];
        let count = (&client).read(&mut bytes).unwrap();
        assert_eq!(count, 8);
        assert_eq!(u32::from_ne_bytes(bytes[0..4].try_into().unwrap()), 10);
        assert_eq!(state.surfaces.get(&20).unwrap().attached_buffer, None);
        assert_eq!(state.active_surface, None);
        assert_eq!(state.active_toplevel, None);

        let recorder = unsafe { Box::from_raw(recorder_ptr) };
        let frames = recorder.frames.lock().unwrap();
        assert!(frames.is_empty());
        drop(frames);
        let logs = recorder.logs.lock().unwrap();
        assert!(logs
            .iter()
            .any(|line| line.contains("wayland_window_event session=detach-session event=unmapped")));
    }

    fn append_transport_json(pending: &mut Vec<u8>, value: serde_json::Value) {
        let payload = serde_json::to_vec(&value).unwrap();
        pending.extend_from_slice(&(payload.len() as u32).to_le_bytes());
        pending.extend_from_slice(&payload);
    }

    #[test]
    fn mini_wayland_registry_handshake_advertises_required_globals() {
        let recorder = Box::new(CallbackRecorder::default());
        let recorder_ptr = Box::into_raw(recorder);
        let callbacks = Arc::new(WaylandCoreCallbacks {
            on_frame: Some(on_frame),
            on_frame_shared: None,
            on_ime_state: Some(on_ime_state),
            on_log: Some(on_log),
            on_exit: Some(on_exit),
            on_cursor: None,
            on_window_event: None,
        });
        let sink = CallbackSink {
            callbacks,
            user_data: recorder_ptr as usize,
        };
        let (client, server) = UnixStream::pair().unwrap();
        client
            .set_read_timeout(Some(Duration::from_millis(250)))
            .unwrap();
        let mut server_file = unsafe { std::fs::File::from_raw_fd(server.into_raw_fd()) };
        let mut state = MiniWaylandState::new();
        let mut pending = wayland_request(1, 1, &[2, 0, 0, 0]);

        assert_eq!(
            drain_wayland_wire_messages(&sink, &mut server_file, &mut state, &mut pending).unwrap(),
            1
        );

        let mut response = [0_u8; 4096];
        let count = (&client).read(&mut response).unwrap();
        let text = String::from_utf8_lossy(&response[..count]);
        assert!(text.contains("wl_compositor"));
        assert!(text.contains("wl_shm"));
        assert!(text.contains("xdg_wm_base"));
        assert!(text.contains("wl_seat"));
        assert!(text.contains("wl_data_device_manager"));
        assert!(text.contains("zwp_text_input_manager_v3"));

        let recorder = unsafe { Box::from_raw(recorder_ptr) };
        let logs = recorder.logs.lock().unwrap();
        assert!(logs
            .iter()
            .any(|line| line.contains("client_requested_registry")));
        assert!(logs
            .iter()
            .any(|line| line.contains("registry_global_advertised")));
        assert!(logs
            .iter()
            .any(|line| line
                .contains("wayland_request_received object=1 interface=wl_display opcode=1")));
        assert!(logs
            .iter()
            .any(|line| line.contains("wayland_event_sent object=2 opcode=0")));
    }

    #[test]
    fn text_input_v3_emits_preedit_commit_and_done() {
        let recorder = Box::new(CallbackRecorder::default());
        let recorder_ptr = Box::into_raw(recorder);
        let callbacks = Arc::new(WaylandCoreCallbacks {
            on_frame: Some(on_frame),
            on_frame_shared: None,
            on_ime_state: Some(on_ime_state),
            on_log: Some(on_log),
            on_exit: Some(on_exit),
            on_cursor: None,
            on_window_event: None,
        });
        let sink = CallbackSink {
            callbacks,
            user_data: recorder_ptr as usize,
        };
        let (client, server) = UnixStream::pair().unwrap();
        client.set_read_timeout(Some(Duration::from_millis(250))).unwrap();
        let server_file = unsafe { std::fs::File::from_raw_fd(server.into_raw_fd()) };
        let mut state = MiniWaylandState::new();
        state.session_id = "ime-session".to_string();
        state.active_surface = Some(11);
        state.keyboard_focused_surface = Some(11);
        state.objects.insert(30, "zwp_text_input_v3".to_string());
        state.text_inputs.insert(30, TextInputState {
            enabled: true,
            entered_surface: Some(11),
            ..TextInputState::default()
        });
        let endpoint = DisplayEndpoint {
            stream: Arc::new(Mutex::new(server_file)),
            state: Arc::new(Mutex::new(state)),
        };
        let payload = serde_json::json!({
            "kind": "imeState",
            "imeState": {
                "sessionId": "ime-session",
                "enabled": true,
                "surroundingText": "あ",
                "cursorUTF16Offset": 1,
                "anchorUTF16Offset": 1,
                "preedit": "あ",
                "committed": "亜",
                "deleteLeftUTF16Count": 0,
                "deleteRightUTF16Count": 0
            }
        });
        send_text_input_to_display(&sink, &endpoint, &serde_json::to_vec(&payload).unwrap()).unwrap();

        let mut response = [0_u8; 256];
        let count = (&client).read(&mut response).unwrap();
        assert!(count > 0);
        let recorder = unsafe { Box::from_raw(recorder_ptr) };
        let logs = recorder.logs.lock().unwrap();
        assert!(logs.iter().any(|line| line.contains("wayland_text_input_sent object=30")));
    }

    #[test]
    fn utf16_delete_counts_convert_to_utf8_bytes() {
        assert_eq!(delete_before_utf16_to_utf8_bytes("aあ😀b", 4, 2), 4);
        assert_eq!(delete_after_utf16_to_utf8_bytes("aあ😀b", 1, 1), 3);
    }

    #[test]
    fn configure_size_subtracts_client_side_decoration_extents() {
        let mut state = MiniWaylandState::new();
        state.active_surface = Some(11);
        state.surfaces.insert(
            11,
            SurfaceState {
                window_geometry: Some(WindowGeometry {
                    x: 26,
                    y: 23,
                    width: 900,
                    height: 747,
                }),
                ..SurfaceState::default()
            },
        );
        state.surface_frames.insert(
            11,
            SurfaceFrame {
                width: 952,
                height: 799,
                stride: 952 * 4,
                format: ShmPixelFormat::Argb8888,
                pixels: vec![0; 952 * 799 * 4],
            },
        );

        assert_eq!(configured_client_size(&state, 1200, 900), (1148, 848));
    }

    fn wayland_request(object_id: u32, opcode: u16, body: &[u8]) -> Vec<u8> {
        let size = 8 + body.len();
        let mut bytes = Vec::new();
        bytes.extend_from_slice(&object_id.to_ne_bytes());
        bytes.extend_from_slice(&(((size as u32) << 16) | opcode as u32).to_ne_bytes());
        bytes.extend_from_slice(body);
        bytes
    }

    #[test]
    fn display_endpoint_sends_pointer_keyboard_and_close_events() {
        let recorder = Box::new(CallbackRecorder::default());
        let recorder_ptr = Box::into_raw(recorder);
        let callbacks = Arc::new(WaylandCoreCallbacks {
            on_frame: Some(on_frame),
            on_frame_shared: None,
            on_ime_state: Some(on_ime_state),
            on_log: Some(on_log),
            on_exit: Some(on_exit),
            on_cursor: None,
            on_window_event: None,
        });
        let sink = CallbackSink {
            callbacks,
            user_data: recorder_ptr as usize,
        };
        let (client, server) = UnixStream::pair().unwrap();
        client
            .set_read_timeout(Some(Duration::from_millis(250)))
            .unwrap();
        let server_file = unsafe { std::fs::File::from_raw_fd(server.into_raw_fd()) };
        let mut state = MiniWaylandState::new();
        state.session_id = "input-session".to_string();
        state.active_surface = Some(11);
        state.active_toplevel = Some(12);
        state.xdg_toplevels.insert(12, 13);
        state.pointer_object = Some(20);
        let endpoint = DisplayEndpoint {
            stream: Arc::new(Mutex::new(server_file)),
            state: Arc::new(Mutex::new(state)),
        };

        send_focus_to_display(&sink, &endpoint, true).unwrap();
        {
            let mut state = endpoint.state.lock().unwrap();
            state.keyboard_object = Some(21);
            let mut stream = endpoint.stream.lock().unwrap();
            ensure_keyboard_focus(&sink, &mut stream, &mut state).unwrap();
        }

        send_pointer_to_display(
            &sink,
            &endpoint,
            PointerCommand {
                kind: 1,
                x: 10.0,
                y: 20.0,
                button: 0x110,
                axis_x: 0.0,
                axis_y: 0.0,
                modifiers: 0,
                timestamp_ms: 123,
            },
        )
        .unwrap();
        send_keyboard_to_display(
            &sink,
            &endpoint,
            KeyboardCommand {
                kind: 1,
                keycode: 30,
                modifiers: 0,
                timestamp_ms: 124,
                trace_id: "test-key".to_string(),
            },
        )
        .unwrap();
        send_toplevel_close_to_display(&sink, &endpoint).unwrap();

        let mut response = [0_u8; 512];
        let count = (&client).read(&mut response).unwrap();
        assert!(count > 0);

        let recorder = unsafe { Box::from_raw(recorder_ptr) };
        let logs = recorder.logs.lock().unwrap();
        assert!(logs
            .iter()
            .any(|line| line.contains("wayland_pointer_event_sent kind=1")));
        assert!(logs
            .iter()
            .any(|line| line.contains("wayland_focus_deferred reason=no_keyboard_object")));
        assert!(logs
            .iter()
            .any(|line| line.contains("wayland_keyboard_focus_sent surface=11 keyboard=21")));
        assert!(logs
            .iter()
            .any(|line| line.contains("wayland_keyboard_event_sent trace_id=test-key kind=1")));
        assert!(logs
            .iter()
            .any(|line| line.contains("wayland_toplevel_close_sent toplevel=12")));
    }

    #[test]
    fn ffi_lifecycle_does_not_emit_synthetic_frame() {
        let _guard = shared_frame_test_guard();
        let recorder = Box::new(CallbackRecorder::default());
        let recorder_ptr = Box::into_raw(recorder);
        let callbacks = WaylandCoreCallbacks {
            on_frame: Some(on_frame),
            on_frame_shared: None,
            on_ime_state: Some(on_ime_state),
            on_log: Some(on_log),
            on_exit: Some(on_exit),
            on_cursor: None,
            on_window_event: None,
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

        assert!(frames.is_empty());
        assert!(ime_payloads.is_empty());
        assert!(logs
            .iter()
            .any(|line| line.contains("attach_session session-a")));
        assert!(logs
            .iter()
            .any(|line| line.contains("synthetic_frame_disabled reason=attach_session")));
        assert!(logs.iter().any(|line| {
            line.contains("geometry_updated session=session-a")
                && line.contains("synthetic_frame_disabled=true")
        }));
        assert_eq!(exits.as_slice(), &[0]);
    }
}
