//! Epkowa stub — x86_64 bridge to the proprietary `libesci-interpreter-*.so`.
//!
//! Not a daemon. The aarch64-native libsane-epkowa.so spawns us as a child
//! via socketpair+fork+exec. We inherit fd 3 (the stub end of the
//! socketpair), dlopen the interpreter, and serve requests until the parent
//! closes the socket (normal case) or dies (we notice via EOF or PDEATHSIG).
//!
//! USB is never done here — when the interpreter calls our USB callbacks, we
//! forward them over the same socket back to the proxy, which performs the
//! real USB transfer on native aarch64.
//!
//! See PROTOCOL.md for the wire format.

// The stub is single-threaded by design: one outer request at a time,
// callbacks run synchronously on the same thread. Globals are not racy.
#![allow(static_mut_refs)]

use std::io::{ErrorKind, Read, Write};
use std::os::unix::io::{FromRawFd, RawFd};
use std::os::unix::net::UnixStream;

use libloading::Library;

// ──────────────────────────────────────────────────────────────────────────
// Op codes (must match PROTOCOL.md and the proxy C side)

const OP_INT_INIT_WITH_CTRL: u8 = 0x01;
const OP_INT_FINI: u8 = 0x02;
const OP_INT_READ: u8 = 0x03;
const OP_INT_WRITE: u8 = 0x04;
const OP_INT_POWER_SAVING_MODE: u8 = 0x05;
const OP_FUNCTION_S_0: u8 = 0x06;
const OP_FUNCTION_S_1: u8 = 0x07;
const OP_OPEN_LIBRARY: u8 = 0x08;

const OP_INT_INIT_RESP: u8 = 0x81;
const OP_INT_FINI_RESP: u8 = 0x82;
const OP_INT_READ_RESP: u8 = 0x83;
const OP_INT_WRITE_RESP: u8 = 0x84;
const OP_INT_POWER_SAVING_MODE_RESP: u8 = 0x85;
const OP_FUNCTION_S_0_RESP: u8 = 0x86;
const OP_FUNCTION_S_1_RESP: u8 = 0x87;
const OP_OPEN_LIBRARY_RESP: u8 = 0x88;

const OP_CB_USB_READ: u8 = 0xC1;
const OP_CB_USB_WRITE: u8 = 0xC2;
const OP_CB_USB_CTRL: u8 = 0xC3;

const OP_CB_USB_READ_RESP: u8 = 0xD1;
const OP_CB_USB_WRITE_RESP: u8 = 0xD2;
const OP_CB_USB_CTRL_RESP: u8 = 0xD3;

/// Fd number the parent passes us for the IPC socket. Chosen to skip past
/// stdin/stdout/stderr.
const IPC_FD: RawFd = 3;

/// Tail-guard bytes we pad every plugin-exposed read/write buffer with so
/// a plugin overrun shows up as a canary-fill change rather than random
/// heap corruption detected minutes later.
const CANARY_SIZE: usize = 64;
const CANARY_BYTE: u8 = 0xA5;

/// Hex dump of a byte slice, capped at `cap` bytes of hex, with a "..."
/// suffix if truncated. Pair with a length field in the caller's log
/// line so capped dumps stay unambiguous.
fn hex_short(data: &[u8], cap: usize) -> String {
    let n = data.len().min(cap);
    let hex: Vec<String> = data[..n].iter().map(|b| format!("{:02x}", b)).collect();
    let suffix = if data.len() > cap { " ..." } else { "" };
    format!("{}{}", hex.join(" "), suffix)
}

fn check_canary(op: &str, buf: &[u8], requested: usize) {
    let tail = &buf[requested..];
    if let Some(off) = tail.iter().position(|&b| b != CANARY_BYTE) {
        let end = (off + 16).min(tail.len());
        eprintln!(
            "[stub] CANARY CORRUPT in {}: requested={}, first-bad-offset=+{}, tail[{}..{}]={:02x?}",
            op, requested, off, off, end, &tail[off..end]
        );
    }
}

// ──────────────────────────────────────────────────────────────────────────
// Interpreter ABI (from epkowa_ip_api.h — matches the proprietary .so)

type IoCallback = unsafe extern "C" fn(*mut libc::c_void, libc::size_t) -> libc::ssize_t;
type CtrlCallback = unsafe extern "C" fn(
    libc::size_t, libc::size_t, libc::size_t, libc::size_t,
    libc::size_t, *mut libc::c_void,
) -> libc::ssize_t;

type IscanBool = libc::c_int;

type FnIntInit = unsafe extern "C" fn(libc::c_int, IoCallback, IoCallback) -> IscanBool;
type FnIntInitWithCtrl = unsafe extern "C" fn(
    libc::c_int, IoCallback, IoCallback, CtrlCallback,
) -> IscanBool;
type FnIntFini = unsafe extern "C" fn();
type FnIntRead = unsafe extern "C" fn(*mut libc::c_void, libc::size_t) -> libc::c_int;
type FnIntWrite = unsafe extern "C" fn(*mut libc::c_void, libc::size_t) -> libc::c_int;
type FnIntPowerSavingMode = unsafe extern "C" fn();
type FnFunctionS0 = unsafe extern "C" fn(
    libc::c_uint, libc::c_uint, libc::c_uint, libc::c_uint, *mut f64,
) -> libc::c_int;
type FnFunctionS1 = unsafe extern "C" fn(
    *mut u8, *mut u8, libc::c_uint, IscanBool, *mut f64,
);

struct LoadedPlugin {
    _lib: Library,
    init: Option<FnIntInit>,
    init_with_ctrl: Option<FnIntInitWithCtrl>,
    fini: FnIntFini,
    read: FnIntRead,
    write: FnIntWrite,
    power_saving_mode: Option<FnIntPowerSavingMode>,
    function_s_0: FnFunctionS0,
    function_s_1: FnFunctionS1,
}

// Single-process lifetime state. No Mutex needed — the interpreter and our
// request loop share the only thread, and we don't accept overlapping
// requests.
static mut PLUGIN: Option<LoadedPlugin> = None;

/// Raw fd used by USB callbacks. We keep it as a raw fd rather than an
/// owning UnixStream so callbacks (which are `extern "C"`) can dup and wrap
/// it without worrying about move semantics.
static mut IPC_SOCK_FD: RawFd = -1;

fn cb_sock() -> UnixStream {
    let fd = unsafe { IPC_SOCK_FD };
    if fd < 0 {
        panic!("IPC fd not set before callback");
    }
    let duped = unsafe { libc::dup(fd) };
    if duped < 0 {
        panic!("dup() of callback socket failed");
    }
    unsafe { UnixStream::from_raw_fd(duped) }
}

// ──────────────────────────────────────────────────────────────────────────
// Wire helpers

fn read_exact(s: &mut UnixStream, n: usize) -> std::io::Result<Vec<u8>> {
    let mut v = vec![0u8; n];
    s.read_exact(&mut v)?;
    Ok(v)
}

fn read_u8(s: &mut UnixStream) -> std::io::Result<u8> {
    let b = read_exact(s, 1)?;
    Ok(b[0])
}

fn read_u32(s: &mut UnixStream) -> std::io::Result<u32> {
    let b = read_exact(s, 4)?;
    Ok(u32::from_le_bytes([b[0], b[1], b[2], b[3]]))
}

fn read_i64(s: &mut UnixStream) -> std::io::Result<i64> {
    let b = read_exact(s, 8)?;
    Ok(i64::from_le_bytes(b.try_into().unwrap()))
}

fn write_frame(s: &mut UnixStream, op: u8, payload: &[u8]) -> std::io::Result<()> {
    s.write_all(&[op])?;
    s.write_all(&(payload.len() as u32).to_le_bytes())?;
    s.write_all(payload)?;
    s.flush()
}

// ──────────────────────────────────────────────────────────────────────────
// Callbacks exposed to the proprietary plugin.
//
// The plugin calls these when it wants to talk to the scanner over USB. We
// translate each call into a CB_* IPC to the proxy, which performs the real
// USB operation on native aarch64, and return the result.
//
// Buffer handling is always copy-in/copy-out — we never retain a pointer
// across the call boundary and we never assume the plugin will do anything
// with our buffer after return. This is necessary because: (a) the plugin
// is across a process boundary so we can't share memory anyway; (b) cheaply
// safe regardless of what the plugin does with its input buffers.

unsafe extern "C" fn cb_usb_read(buffer: *mut libc::c_void, length: libc::size_t) -> libc::ssize_t {
    eprintln!("[stub]   cb_usb_read({} bytes)", length);
    let mut s = cb_sock();
    if write_frame(&mut s, OP_CB_USB_READ, &(length as u32).to_le_bytes()).is_err() {
        return -1;
    }
    let op = match read_u8(&mut s) { Ok(o) => o, Err(_) => return -1 };
    let _ = match read_u32(&mut s) { Ok(l) => l, Err(_) => return -1 };
    if op != OP_CB_USB_READ_RESP {
        return -1;
    }
    let ret = match read_i64(&mut s) { Ok(r) => r, Err(_) => return -1 };
    let data_len = match read_u32(&mut s) { Ok(l) => l, Err(_) => return -1 };
    if data_len > 0 {
        let data = match read_exact(&mut s, data_len as usize) { Ok(d) => d, Err(_) => return -1 };
        std::ptr::copy_nonoverlapping(data.as_ptr(), buffer as *mut u8, data.len());
    }
    ret as libc::ssize_t
}

unsafe extern "C" fn cb_usb_write(buffer: *mut libc::c_void, length: libc::size_t) -> libc::ssize_t {
    eprintln!("[stub]   cb_usb_write({} bytes)", length);
    let mut s = cb_sock();
    let data = std::slice::from_raw_parts(buffer as *const u8, length);
    let mut payload = Vec::with_capacity(4 + data.len());
    payload.extend_from_slice(&(length as u32).to_le_bytes());
    payload.extend_from_slice(data);
    if write_frame(&mut s, OP_CB_USB_WRITE, &payload).is_err() {
        return -1;
    }
    let op = match read_u8(&mut s) { Ok(o) => o, Err(_) => return -1 };
    let _ = match read_u32(&mut s) { Ok(l) => l, Err(_) => return -1 };
    if op != OP_CB_USB_WRITE_RESP {
        return -1;
    }
    match read_i64(&mut s) { Ok(r) => r as libc::ssize_t, Err(_) => -1 }
}

unsafe extern "C" fn cb_usb_ctrl(
    request_type: libc::size_t,
    request: libc::size_t,
    value: libc::size_t,
    index: libc::size_t,
    size: libc::size_t,
    buffer: *mut libc::c_void,
) -> libc::ssize_t {
    let mut s = cb_sock();
    let is_in = (request_type & 0x80) != 0;
    let data_len: u32 = if !is_in && size > 0 && !buffer.is_null() { size as u32 } else { 0 };

    let mut payload = Vec::with_capacity(24 + data_len as usize);
    payload.extend_from_slice(&(request_type as u32).to_le_bytes());
    payload.extend_from_slice(&(request as u32).to_le_bytes());
    payload.extend_from_slice(&(value as u32).to_le_bytes());
    payload.extend_from_slice(&(index as u32).to_le_bytes());
    payload.extend_from_slice(&(size as u32).to_le_bytes());
    payload.extend_from_slice(&data_len.to_le_bytes());
    if data_len > 0 {
        let data = std::slice::from_raw_parts(buffer as *const u8, data_len as usize);
        payload.extend_from_slice(data);
    }

    if write_frame(&mut s, OP_CB_USB_CTRL, &payload).is_err() {
        return -1;
    }
    let op = match read_u8(&mut s) { Ok(o) => o, Err(_) => return -1 };
    let _ = match read_u32(&mut s) { Ok(l) => l, Err(_) => return -1 };
    if op != OP_CB_USB_CTRL_RESP {
        return -1;
    }
    let ret = match read_i64(&mut s) { Ok(r) => r, Err(_) => return -1 };
    let resp_data_len = match read_u32(&mut s) { Ok(l) => l, Err(_) => return -1 };
    if resp_data_len > 0 {
        let data = match read_exact(&mut s, resp_data_len as usize) { Ok(d) => d, Err(_) => return -1 };
        if !buffer.is_null() {
            std::ptr::copy_nonoverlapping(data.as_ptr(), buffer as *mut u8, data.len());
        }
    }
    ret as libc::ssize_t
}

// ──────────────────────────────────────────────────────────────────────────
// Request handling

fn handle_open_library(sock: &mut UnixStream, payload: &[u8]) -> std::io::Result<()> {
    if payload.len() < 2 {
        return write_frame(sock, OP_OPEN_LIBRARY_RESP, &[0, 0]);
    }
    let name_len = u16::from_le_bytes([payload[0], payload[1]]) as usize;
    if payload.len() < 2 + name_len {
        return write_frame(sock, OP_OPEN_LIBRARY_RESP, &[0, 0]);
    }
    let name = match std::str::from_utf8(&payload[2..2 + name_len]) {
        Ok(n) => n,
        Err(_) => return write_frame(sock, OP_OPEN_LIBRARY_RESP, &[0, 0]),
    };

    // Mirror libtool's lt_dlopenext behaviour: if the caller passed a bare
    // library name (like "libesci-interpreter-perfection-v330"), try a few
    // common suffixes before giving up.
    let candidates: Vec<String> = if name.ends_with(".so")
        || name.contains(".so.")
        || name.ends_with(".la")
    {
        vec![name.to_string()]
    } else {
        vec![
            format!("{name}.so"),
            format!("{name}.so.0"),
            format!("{name}.la"),
            name.to_string(),
        ]
    };
    let lib = {
        let mut loaded: Option<Library> = None;
        let mut last_err: Option<String> = None;
        for cand in &candidates {
            match unsafe { Library::new(cand) } {
                Ok(l) => { loaded = Some(l); break; }
                Err(e) => last_err = Some(format!("{cand}: {e}")),
            }
        }
        match loaded {
            Some(l) => l,
            None => {
                eprintln!("[stub] dlopen of {:?} failed (tried {}): {}",
                    name, candidates.join(", "),
                    last_err.unwrap_or_else(|| "(no attempts)".into()));
                return write_frame(sock, OP_OPEN_LIBRARY_RESP, &[0, 0]);
            }
        }
    };

    macro_rules! sym {
        ($name:literal, $ty:ty) => {
            match unsafe { lib.get::<$ty>($name.as_bytes()) } {
                Ok(s) => Some(*s),
                Err(_) => None,
            }
        };
    }

    let init_with_ctrl = sym!("int_init_with_ctrl", FnIntInitWithCtrl);
    let init = if init_with_ctrl.is_some() { None } else { sym!("int_init", FnIntInit) };
    let has_ctrl = init_with_ctrl.is_some();

    let Some(fini) = sym!("int_fini", FnIntFini) else {
        return write_frame(sock, OP_OPEN_LIBRARY_RESP, &[0, 0]);
    };
    let Some(read) = sym!("int_read", FnIntRead) else {
        return write_frame(sock, OP_OPEN_LIBRARY_RESP, &[0, 0]);
    };
    let Some(write) = sym!("int_write", FnIntWrite) else {
        return write_frame(sock, OP_OPEN_LIBRARY_RESP, &[0, 0]);
    };
    let power_saving_mode = sym!("int_power_saving_mode", FnIntPowerSavingMode);
    let Some(function_s_0) = sym!("function_s_0", FnFunctionS0) else {
        return write_frame(sock, OP_OPEN_LIBRARY_RESP, &[0, 0]);
    };
    let Some(function_s_1) = sym!("function_s_1", FnFunctionS1) else {
        return write_frame(sock, OP_OPEN_LIBRARY_RESP, &[0, 0]);
    };

    unsafe {
        PLUGIN = Some(LoadedPlugin {
            _lib: lib, init, init_with_ctrl, fini, read, write,
            power_saving_mode, function_s_0, function_s_1,
        });
    }

    write_frame(sock, OP_OPEN_LIBRARY_RESP, &[1, has_ctrl as u8])
}

fn with_plugin<F, R>(default: R, f: F) -> R
where F: FnOnce(&LoadedPlugin) -> R {
    unsafe {
        match PLUGIN.as_ref() {
            Some(p) => f(p),
            None => default,
        }
    }
}

fn handle_int_init(sock: &mut UnixStream, payload: &[u8]) -> std::io::Result<()> {
    if payload.len() < 5 {
        return write_frame(sock, OP_INT_INIT_RESP, &[0]);
    }
    let fd = i32::from_le_bytes([payload[0], payload[1], payload[2], payload[3]]);
    let use_ctrl = payload[4] != 0;

    let ok = with_plugin(false, |p| unsafe {
        if use_ctrl {
            match p.init_with_ctrl {
                Some(f) => f(fd, cb_usb_read, cb_usb_write, cb_usb_ctrl) != 0,
                None => false,
            }
        } else {
            match p.init {
                Some(f) => f(fd, cb_usb_read, cb_usb_write) != 0,
                None => false,
            }
        }
    });
    write_frame(sock, OP_INT_INIT_RESP, &[ok as u8])
}

fn handle_int_fini(sock: &mut UnixStream) -> std::io::Result<()> {
    with_plugin((), |p| unsafe { (p.fini)() });
    write_frame(sock, OP_INT_FINI_RESP, &[])
}

fn handle_int_read(sock: &mut UnixStream, payload: &[u8]) -> std::io::Result<()> {
    if payload.len() < 4 {
        let mut resp = (-1i32).to_le_bytes().to_vec();
        resp.extend_from_slice(&0u32.to_le_bytes());
        return write_frame(sock, OP_INT_READ_RESP, &resp);
    }
    let length = u32::from_le_bytes([payload[0], payload[1], payload[2], payload[3]]) as usize;
    // Overallocate with a 0xA5 canary tail so we can detect the plugin
    // writing past the `length` byte window it was asked to fill. Cheap
    // in-band overrun check: if the canary tail changes after the call,
    // the plugin went past the end of our buffer.
    let mut buf = vec![CANARY_BYTE; length + CANARY_SIZE];
    buf[..length].fill(0);
    let ret = with_plugin(-1, |p| unsafe {
        (p.read)(buf.as_mut_ptr() as *mut libc::c_void, length)
    });
    check_canary("int_read", &buf, length);
    // Native iscan's _recv wrapper treats the plugin's int_read return as
    // a boolean success flag and uses the full `size` buffer regardless
    // (epkowa_ip.c:_recv). So the plugin fills up to `length` bytes and
    // returns 1 to mean "OK". Ship the whole caller-facing window back to
    // the proxy — picking subsets based on `ret` would hide real data
    // (e.g. this was truncating the 42-byte firmware-name reply to 1 byte).
    eprintln!(
        "[stub]    int_read len={} ret={}: {}",
        length, ret, hex_short(&buf[..length], 48)
    );
    let mut resp = Vec::with_capacity(4 + 4 + length);
    resp.extend_from_slice(&ret.to_le_bytes());
    resp.extend_from_slice(&(length as u32).to_le_bytes());
    resp.extend_from_slice(&buf[..length]);
    write_frame(sock, OP_INT_READ_RESP, &resp)
}

fn handle_int_write(sock: &mut UnixStream, payload: &[u8]) -> std::io::Result<()> {
    if payload.len() < 4 {
        return write_frame(sock, OP_INT_WRITE_RESP, &(-1i32).to_le_bytes());
    }
    let dlen = u32::from_le_bytes([payload[0], payload[1], payload[2], payload[3]]) as usize;
    if payload.len() < 4 + dlen {
        return write_frame(sock, OP_INT_WRITE_RESP, &(-1i32).to_le_bytes());
    }
    // Copy into an owned Vec — the plugin may call into its own USB callbacks
    // (which use cb_sock), so we don't want to hold a slice into our payload
    // buffer any longer than necessary.
    // Canary tail: in_buf is nominally read-only for int_write, but some
    // ESC/I interpreters munge the command bytes in place (encryption /
    // checksumming), and a stray store past `dlen` would corrupt our
    // heap silently. Detect it cheaply.
    let mut data = Vec::with_capacity(dlen + CANARY_SIZE);
    data.extend_from_slice(&payload[4..4 + dlen]);
    data.resize(dlen + CANARY_SIZE, CANARY_BYTE);
    eprintln!(
        "[stub]    int_write in  len={}: {}",
        dlen, hex_short(&data[..dlen], 48)
    );
    let ret = with_plugin(-1, |p| unsafe {
        (p.write)(data.as_mut_ptr() as *mut libc::c_void, dlen)
    });
    check_canary("int_write", &data, dlen);
    eprintln!(
        "[stub]    int_write out len={} ret={}: {}",
        dlen, ret, hex_short(&data[..dlen], 48)
    );
    write_frame(sock, OP_INT_WRITE_RESP, &ret.to_le_bytes())
}

fn handle_power_saving(sock: &mut UnixStream) -> std::io::Result<()> {
    with_plugin((), |p| {
        if let Some(f) = p.power_saving_mode {
            unsafe { f() };
        }
    });
    write_frame(sock, OP_INT_POWER_SAVING_MODE_RESP, &[])
}

fn handle_function_s_0(sock: &mut UnixStream, payload: &[u8]) -> std::io::Result<()> {
    if payload.len() < 20 {
        return write_frame(sock, OP_FUNCTION_S_0_RESP, &[]);
    }
    let offset = u32::from_le_bytes(payload[0..4].try_into().unwrap());
    let width  = u32::from_le_bytes(payload[4..8].try_into().unwrap());
    let res    = u32::from_le_bytes(payload[8..12].try_into().unwrap());
    let optres = u32::from_le_bytes(payload[12..16].try_into().unwrap());
    let tlen   = u32::from_le_bytes(payload[16..20].try_into().unwrap()) as usize;
    if payload.len() < 20 + tlen * 8 {
        return write_frame(sock, OP_FUNCTION_S_0_RESP, &[]);
    }
    let mut table = vec![0f64; tlen];
    for (i, t) in table.iter_mut().enumerate() {
        let off = 20 + i * 8;
        *t = f64::from_le_bytes(payload[off..off + 8].try_into().unwrap());
    }
    let ret = with_plugin(-1, |p| unsafe {
        (p.function_s_0)(offset, width, res, optres, table.as_mut_ptr())
    });
    let mut resp = Vec::with_capacity(4 + 4 + tlen * 8);
    resp.extend_from_slice(&ret.to_le_bytes());
    resp.extend_from_slice(&(tlen as u32).to_le_bytes());
    for t in &table {
        resp.extend_from_slice(&t.to_le_bytes());
    }
    write_frame(sock, OP_FUNCTION_S_0_RESP, &resp)
}

fn handle_function_s_1(sock: &mut UnixStream, payload: &[u8]) -> std::io::Result<()> {
    // Layout: width u32, color u8, tlen u32, table tlen*f64, inb_len u32, in_buf
    if payload.len() < 9 {
        return write_frame(sock, OP_FUNCTION_S_1_RESP, &[]);
    }
    let width = u32::from_le_bytes(payload[0..4].try_into().unwrap());
    let color = payload[4] != 0;
    let tlen = u32::from_le_bytes(payload[5..9].try_into().unwrap()) as usize;
    let inb_start = 9 + tlen * 8;
    if payload.len() < inb_start + 4 {
        return write_frame(sock, OP_FUNCTION_S_1_RESP, &[]);
    }
    let mut table = vec![0f64; tlen];
    for (i, t) in table.iter_mut().enumerate() {
        let off = 9 + i * 8;
        *t = f64::from_le_bytes(payload[off..off + 8].try_into().unwrap());
    }
    let inb_len = u32::from_le_bytes(payload[inb_start..inb_start + 4].try_into().unwrap()) as usize;
    if payload.len() < inb_start + 4 + inb_len {
        return write_frame(sock, OP_FUNCTION_S_1_RESP, &[]);
    }
    let mut inbuf = payload[inb_start + 4..inb_start + 4 + inb_len].to_vec();
    // Heuristic: out_buf is same length as in_buf. True for typical
    // per-line shading operations; revisit once we have the plugin's
    // actual behavior mapped out.
    let mut outbuf = vec![0u8; inb_len];
    let color_flag: IscanBool = if color { 1 } else { 0 };
    with_plugin((), |p| unsafe {
        (p.function_s_1)(inbuf.as_mut_ptr(), outbuf.as_mut_ptr(), width, color_flag, table.as_mut_ptr());
    });
    let mut resp = Vec::with_capacity(4 + outbuf.len() + 4 + tlen * 8);
    resp.extend_from_slice(&(outbuf.len() as u32).to_le_bytes());
    resp.extend_from_slice(&outbuf);
    resp.extend_from_slice(&(tlen as u32).to_le_bytes());
    for t in &table {
        resp.extend_from_slice(&t.to_le_bytes());
    }
    write_frame(sock, OP_FUNCTION_S_1_RESP, &resp)
}

fn serve(mut sock: UnixStream) -> std::io::Result<()> {
    loop {
        let op = match read_u8(&mut sock) {
            Ok(o) => o,
            Err(e) if e.kind() == ErrorKind::UnexpectedEof => return Ok(()),
            Err(e) => return Err(e),
        };
        let plen = read_u32(&mut sock)? as usize;
        let payload = read_exact(&mut sock, plen)?;

        // Per-op log to stderr — catches which call was in flight when the
        // loaded proprietary .so aborts the process (e.g. glibc double-free
        // detection). `eprintln!` flushes, so the final line before a crash
        // survives to the caller's stderr.
        let op_name = match op {
            OP_OPEN_LIBRARY => "OPEN_LIBRARY",
            OP_INT_INIT_WITH_CTRL => "INT_INIT[_WITH_CTRL]",
            OP_INT_FINI => "INT_FINI",
            OP_INT_READ => "INT_READ",
            OP_INT_WRITE => "INT_WRITE",
            OP_INT_POWER_SAVING_MODE => "INT_POWER_SAVING_MODE",
            OP_FUNCTION_S_0 => "FUNCTION_S_0",
            OP_FUNCTION_S_1 => "FUNCTION_S_1",
            _ => "?",
        };
        eprintln!("[stub] -> {} ({} bytes)", op_name, plen);
        let r = match op {
            OP_OPEN_LIBRARY => handle_open_library(&mut sock, &payload),
            OP_INT_INIT_WITH_CTRL => handle_int_init(&mut sock, &payload),
            OP_INT_FINI => handle_int_fini(&mut sock),
            OP_INT_READ => handle_int_read(&mut sock, &payload),
            OP_INT_WRITE => handle_int_write(&mut sock, &payload),
            OP_INT_POWER_SAVING_MODE => handle_power_saving(&mut sock),
            OP_FUNCTION_S_0 => handle_function_s_0(&mut sock, &payload),
            OP_FUNCTION_S_1 => handle_function_s_1(&mut sock, &payload),
            other => {
                eprintln!("[stub] unknown op 0x{:02x}", other);
                return Ok(());
            }
        };
        eprintln!("[stub] <- {} done", op_name);
        r?;
    }
}

fn main() -> std::io::Result<()> {
    // If the parent (aarch64 proxy) dies for any reason other than a clean
    // socket shutdown, we want to die with it. Linux-specific; harmless
    // elsewhere.
    unsafe {
        libc::prctl(libc::PR_SET_PDEATHSIG, libc::SIGTERM as libc::c_ulong, 0, 0, 0);
    }

    unsafe { IPC_SOCK_FD = IPC_FD };
    let sock = unsafe { UnixStream::from_raw_fd(IPC_FD) };
    serve(sock)
}
