# Epkowa IPC Protocol v1

Proxy (aarch64 native, inside libsane-epkowa.so) talks to Stub (x86_64 under
qemu-user, loading the proprietary `libesci-interpreter-*.so`) over a Unix
domain socket.

## Framing

Every message is:

```
u8   op
u32  payload_len (little-endian)
...  payload (payload_len bytes)
```

All multi-byte integers are little-endian (both archs are LE).

## Bi-directional flow

- Proxy initiates. It sends a request, then reads messages until it gets the
  matching response. Messages in between are callbacks from stub and are
  answered by proxy in-line before continuing to read the response.
- Stub processes one proxy request at a time. While handling a request, the
  proprietary plugin may call the stub's local `usb_read`/`usb_write`/`usb_ctrl`
  trampolines — these send a CB_* request and block until the matching CB_*_RESP.

Ops use the high bit to disambiguate direction:
- `0x0_` — proxy → stub request
- `0x8_` — stub → proxy response to request
- `0xC_` — stub → proxy callback request
- `0xD_` — proxy → stub response to callback

## Operations

### OPEN_LIBRARY (0x08) → OPEN_LIBRARY_RESP (0x88)

Proxy asks stub to dlopen a specific interpreter plugin by filename.

Request payload:
```
u16  name_len
...  name (utf-8, no null terminator)
```

Response payload:
```
u8   success (1 = ok, 0 = fail)
u8   has_ctrl (1 if int_init_with_ctrl present, else 0)
```

### INT_INIT_WITH_CTRL (0x01) → INT_INIT_RESP (0x81)

Proxy tells stub to call `int_init` or `int_init_with_ctrl`. Stub substitutes
its own local callbacks that forward USB ops back over the socket.

Request payload:
```
i32  fd (opaque — passed through to plugin, but USB goes through callbacks)
u8   use_ctrl (1 → int_init_with_ctrl, 0 → int_init)
```

Response payload:
```
u8   success (1 = ok, 0 = fail)
```

### INT_FINI (0x02) → INT_FINI_RESP (0x82)

No payload in either direction.

### INT_READ (0x03) → INT_READ_RESP (0x83)

Request:
```
u32  length
```

Response:
```
i32  ret (bytes read or negative error)
u32  data_len
...  data (data_len bytes; present only if ret > 0)
```

### INT_WRITE (0x04) → INT_WRITE_RESP (0x84)

Request:
```
u32  data_len
...  data (data_len bytes)
```

Response:
```
i32  ret
```

### INT_POWER_SAVING_MODE (0x05) → INT_POWER_SAVING_MODE_RESP (0x85)

No payload either direction.

### FUNCTION_S_0 (0x06) → FUNCTION_S_0_RESP (0x86)

Gamma/shading table setup. Inputs offset/width/resolution/opt_resolution, plus
an input `table` of f64 values. Output is a return code plus an updated table
(same length).

Request:
```
u32  offset
u32  width
u32  resolution
u32  opt_resolution
u32  table_len (in elements, not bytes)
...  table (table_len * 8 bytes of IEEE754 f64)
```

Response:
```
i32  ret
u32  table_len
...  table (table_len * 8 bytes)
```

### FUNCTION_S_1 (0x07) → FUNCTION_S_1_RESP (0x87)

Image processing. Takes in_buf + width + color + table; writes out_buf.
in_buf and out_buf are of length `width` bytes each (need to confirm — revisit
when implementing against the actual plugin behavior).

Request:
```
u32  width
u8   color (0/1)
u32  table_len
...  table (table_len * 8 bytes)
u32  in_buf_len
...  in_buf
```

Response:
```
u32  out_buf_len
...  out_buf
u32  table_len
...  table (updated; might be unchanged)
```

## Callback operations (stub → proxy)

### CB_USB_READ (0xC1) → CB_USB_READ_RESP (0xD1)

Request:
```
u32  length
```

Response:
```
i64  ret
u32  data_len
...  data
```

### CB_USB_WRITE (0xC2) → CB_USB_WRITE_RESP (0xD2)

Request:
```
u32  data_len
...  data
```

Response:
```
i64  ret
```

### CB_USB_CTRL (0xC3) → CB_USB_CTRL_RESP (0xD3)

USB control transfer. Direction encoded in request_type (bmRequestType);
0x80 bit = IN (device-to-host), else OUT.

Request:
```
u32  request_type
u32  request
u32  value
u32  index
u32  size
u32  data_len (0 if IN transfer; = size if OUT transfer with data)
...  data (if data_len > 0)
```

Response:
```
i64  ret
u32  data_len (0 if OUT transfer; returned bytes if IN)
...  data
```

## Design notes

- No message tags — protocol is strictly request/response with stackable
  callbacks. One outstanding outer request at any time.
- No version handshake yet. If we change the protocol later, add a VERSION op
  first.
- All "lengths" are u32; no message exceeds 4 GiB — realistic for ESC/I traffic.
- `fd` is opaque. The plugin may log it; it's not used for USB since all USB
  goes through callbacks.
