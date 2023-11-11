const builtin = @import("builtin");
const std = @import("std");
const ws2_32 = std.os.windows.ws2_32;
const zware = @import("zware");
const wasm4 = @import("wasm4.zig");
const zigx = @import("x");
const x11common = @import("x11common.zig");

const Size = struct {
    x: u16,
    y: u16,
    pub fn equals(self: Size, other: Size) bool {
        return self.x == other.x and self.y == other.y;
    }
};

const wasm4_size = Size{ .x = 160, .y = 160 };

const global = struct {
    var arena_instance = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const arena = arena_instance.allocator();

    var image_format: ImageFormat = undefined;
    var resource_id_base: u32 = undefined;
    var window_size: Size = .{ .x = wasm4_size.x, .y = wasm4_size.y };
    var put_img_buf: ?[]u8 = null;
    pub fn window_id() u32 { return resource_id_base; }
    pub fn bg_gc_id() u32 { return resource_id_base + 1; }
    pub fn fg_gc_id() u32 { return resource_id_base + 2; }
};

const Key = enum {
    _1, _2,
    left, right,
    up, down,
};

pub fn go(instance: *zware.Instance) !void {
    try zigx.wsaStartup();

    const conn = try x11common.connect(global.arena);
    defer std.os.shutdown(conn.sock, .both) catch {};

    const screen = blk: {
        const fixed = conn.setup.fixed();
        global.resource_id_base = fixed.resource_id_base;
        inline for (@typeInfo(@TypeOf(fixed.*)).Struct.fields) |field| {
            std.log.debug("{s}: {any}", .{field.name, @field(fixed, field.name)});
        }
        std.log.debug("vendor: {s}", .{try conn.setup.getVendorSlice(fixed.vendor_len)});
        const format_list_offset = zigx.ConnectSetup.getFormatListOffset(fixed.vendor_len);
        const format_list_limit = zigx.ConnectSetup.getFormatListLimit(format_list_offset, fixed.format_count);
        std.log.debug("fmt list off={} limit={}", .{format_list_offset, format_list_limit});
        const formats = try conn.setup.getFormatList(format_list_offset, format_list_limit);
        for (formats, 0..) |format, i| {
            std.log.debug("format[{}] depth={:3} bpp={:3} scanpad={:3}", .{i, format.depth, format.bits_per_pixel, format.scanline_pad});
        }
        var screen = conn.setup.getFirstScreenPtr(format_list_limit);
        inline for (@typeInfo(@TypeOf(screen.*)).Struct.fields) |field| {
            std.log.debug("SCREEN 0| {s}: {any}", .{field.name, @field(screen, field.name)});
        }

        const image_endian: std.builtin.Endian = switch (fixed.image_byte_order) {
            .lsb_first => .Little,
            .msb_first => .Big,
            else => |order| std.debug.panic("unknown image-byte-order {}", .{order}),
        };
        global.image_format = getImageFormat(
            image_endian,
            formats,
            screen.root_depth,
        ) catch |err| std.debug.panic("can't resolve root depth {} format: {s}", .{screen.root_depth, @errorName(err)});

        break :blk screen;
    };


    var keycode_map = std.AutoHashMapUnmanaged(u8, Key){};
    {
        const keymap = try zigx.keymap.request(global.arena, conn.sock, conn.setup.fixed().*);
        defer keymap.deinit(global.arena);
        std.log.info("Keymap: syms_per_code={} total_syms={}", .{keymap.syms_per_code, keymap.syms.len});
        {
            var i: usize = 0;
            var sym_offset: usize = 0;
            while (i < keymap.keycode_count) : (i += 1) {
                const keycode: u8 = @intCast(conn.setup.fixed().min_keycode + i);
                var j: usize = 0;
                while (j < keymap.syms_per_code) : (j += 1) {
                    const sym = keymap.syms[sym_offset];
                    if (false) {
                    } else if (sym == @intFromEnum(zigx.charset.Combined.latin_x) or
                                   sym == @intFromEnum(zigx.charset.Combined.latin_X)
                    ) {
                        std.log.info("keycode {} is button 1", .{keycode});
                        try keycode_map.put(global.arena, keycode, ._1);
                    } else if (sym == @intFromEnum(zigx.charset.Combined.latin_z) or
                        sym == @intFromEnum(zigx.charset.Combined.latin_Z)
                    ) {
                        std.log.info("keycode {} is button 2", .{keycode});
                        try keycode_map.put(global.arena, keycode, ._2);
                    } else if (sym == @intFromEnum(zigx.charset.Combined.kbd_left)) {
                        std.log.info("keycode {} is left", .{keycode});
                        try keycode_map.put(global.arena, keycode, .left);
                    } else if (sym == @intFromEnum(zigx.charset.Combined.kbd_right)) {
                        std.log.info("keycode {} is right", .{keycode});
                        try keycode_map.put(global.arena, keycode, .right);
                    } else if (sym == @intFromEnum(zigx.charset.Combined.kbd_up)) {
                        std.log.info("keycode {} is up", .{keycode});
                        try keycode_map.put(global.arena, keycode, .up);
                    } else if (sym == @intFromEnum(zigx.charset.Combined.kbd_down)) {
                        std.log.info("keycode {} is down", .{keycode});
                        try keycode_map.put(global.arena, keycode, .down);
                    }
                    sym_offset += 1;
                }
            }
        }
    }


    {
        var msg_buf: [zigx.create_window.max_len]u8 = undefined;
        const len = zigx.create_window.serialize(&msg_buf, .{
            .window_id = global.window_id(),
            .parent_window_id = screen.root,
            .depth = 0, // we don't care, just inherit from the parent
            .x = 0, .y = 0,
            .width = wasm4_size.x, .height = wasm4_size.y,
            .border_width = 0, // TODO: what is this?
            .class = .input_output,
            .visual_id = screen.root_visual,
        }, .{
            .bg_pixel = 0xaabbccdd,
            .event_mask =
                  zigx.event.key_press
                | zigx.event.key_release
                | zigx.event.exposure
                | zigx.event.structure_notify
                ,
        });
        try conn.send(msg_buf[0..len]);
    }

    {
        var msg_buf: [zigx.create_gc.max_len]u8 = undefined;
        const len = zigx.create_gc.serialize(&msg_buf, .{
            .gc_id = global.bg_gc_id(),
            .drawable_id = global.window_id(),
        }, .{
            .foreground = screen.black_pixel,
        });
        try conn.send(msg_buf[0..len]);
    }
    {
        var msg_buf: [zigx.create_gc.max_len]u8 = undefined;
        const len = zigx.create_gc.serialize(&msg_buf, .{
            .gc_id = global.fg_gc_id(),
            .drawable_id = global.window_id(),
        }, .{
            .background = screen.black_pixel,
            .foreground = 0xffaadd,
        });
        try conn.send(msg_buf[0..len]);
    }

    {
        var msg: [zigx.map_window.len]u8 = undefined;
        zigx.map_window.serialize(&msg, global.window_id());
        try conn.send(&msg);
    }

    var double_buf = try zigx.DoubleBuffer.init(
        std.mem.alignForward(usize, 1000, std.mem.page_size),
        .{ .memfd_name = "ZigX11DoubleBuffer" },
    );
    // double_buf.deinit() (not necessary)
    std.log.info("read buffer capacity is {}", .{double_buf.half_len});
    var buf = double_buf.contiguousReadBuffer();

    updateSocketBlocking(conn.sock, .nonblocking);

    const micros_per_frame = @divTrunc(1000000, 60);
    var delay_update_timestamp: ?i64 = null;

    var exposed = false;

    while (true) {
        if (exposed) {
            const loop_timestamp = std.time.microTimestamp();
            const do_update = blk: {
                if (delay_update_timestamp) |delay_timestamp| {
                    const diff = loop_timestamp - delay_timestamp;
                    break :blk diff >= micros_per_frame;
                }
                break :blk true;
            };

            const now = blk: {
                if (do_update) {
                    delay_update_timestamp = loop_timestamp;
                    wasm4.clearFramebuffer(instance.*);
                    try instance.invoke("update", &[_]u64{}, &[_]u64{}, .{});
                    try render(instance.*, conn.sock);
                    break :blk std.time.microTimestamp();
                }
                break :blk loop_timestamp;
            };

            const elapsed_micros = now - delay_update_timestamp.?;
            if (elapsed_micros < micros_per_frame) {
                const timeout_millis = @divTrunc(micros_per_frame - elapsed_micros, 1000);
                if (timeout_millis > 0) {
                    //std.log.info("waiting (timeout={}ms)", .{timeout_millis});
                    _ = try waitSocketReadable(conn.sock, @intCast(timeout_millis));
                }
            } else {
                //std.log.info("no wait (elapsed={} want={})", .{elapsed_micros, micros_per_frame});
            }
        }

        {
            const recv_buf = buf.nextReadBuffer();
            if (recv_buf.len == 0) {
                std.log.err("buffer size {} not big enough!", .{buf.half_len});
                std.os.exit(0xff);
            }
            const len = zigx.readSock(conn.sock, recv_buf, 0) catch |err| switch (err) {
                error.WouldBlock => continue,
                error.ConnectionResetByPeer => {
                    std.log.info("X server connection reset", .{});
                    std.os.exit(0);
                },
                else => |e| return e,
            };
            if (len == 0) {
                std.log.info("X server connection closed", .{});
                std.os.exit(0);
            }
            buf.reserve(len);
        }
        while (true) {
            const data = buf.nextReservedBuffer();
            if (data.len < 32)
                break;
            const msg_len = zigx.parseMsgLen(data[0..32].*);
            if (data.len < msg_len)
                break;
            buf.release(msg_len);
            //buf.resetIfEmpty();
            switch (zigx.serverMsgTaggedUnion(@alignCast(data.ptr))) {
                .err => |msg| {
                    std.log.err("{}", .{msg});
                    std.os.exit(0xff);
                },
                .reply => |msg| {
                    std.log.info("todo: handle a reply message {}", .{msg});
                    return error.TodoHandleReplyMessage;
                },
                .key_press => |msg| {
                    if (keycode_map.get(msg.keycode)) |key| {
                        updateKey(instance.*, key, .down);
                    }
                },
                .key_release => |msg| {
                    if (keycode_map.get(msg.keycode)) |key| {
                        updateKey(instance.*, key, .up);
                    }
                },
                .button_press => |msg| {
                    std.log.info("button_press: {}", .{msg});
                },
                .button_release => |msg| {
                    std.log.info("button_release: {}", .{msg});
                },
                .enter_notify => |msg| {
                    std.log.info("enter_window: {}", .{msg});
                },
                .leave_notify => |msg| {
                    std.log.info("leave_window: {}", .{msg});
                },
                .motion_notify => |msg| {
                    // too much logging
                    _ = msg;
                    //std.log.info("pointer_motion: {}", .{msg});
                },
                .keymap_notify => |msg| {
                    std.log.info("keymap_state: {}", .{msg});
                },
                .expose => {
                    exposed = true;
                },
                .mapping_notify => |msg| {
                    std.log.info("mapping_notify: {}", .{msg});
                },
                .no_exposure => |msg| std.debug.panic("unexpected no_exposure {}", .{msg}),
                .unhandled => |msg| {
                    std.log.info("todo: server msg {}", .{msg});
                    return error.UnhandledServerMsg;
                },
                .configure_notify => |msg| onConfigureNotify(msg.*),
                .map_notify => {},
                .reparent_notify => {},
            }
        }
    }
}

fn updateKey(instance: zware.Instance, key: Key, state: enum { down, up }) void {
    const flag = switch (key) {
        ._1 => wasm4.button_1,
        ._2 => wasm4.button_2,
        .left => wasm4.button_left,
        .right => wasm4.button_right,
        .up => wasm4.button_up,
        .down => wasm4.button_down,
    };
    const mem = wasm4.getMem(instance);
    switch (state) {
        .down => mem[wasm4.gamepad1_addr] |= flag,
        .up => mem[wasm4.gamepad1_addr] &= ~flag,
    }
}

fn render(
    instance: zware.Instance,
    sock: std.os.socket_t,
) !void {
    //std.log.info("render", .{});

    //std.log.info("render mem.data.len={}", .{mem.len});
    const mem = wasm4.getMem(instance);
    const fb = mem[wasm4.framebuffer_addr..][0 .. wasm4.framebuffer_len];

    const palette: *align(1) const [4]u32 = @ptrCast(mem + wasm4.palette_addr);

    const stride = calcStride(
        global.image_format.bits_per_pixel,
        global.image_format.scanline_pad,
        global.window_size.x,
    );

    // TODO: use the SHM extension if available

    const stride_u18 = std.math.cast(u18, stride) orelse
        std.debug.panic("image stride {} too big!", .{stride});
    const msg_len = zigx.put_image.getLen(stride_u18);
    if (global.put_img_buf) |buf| {
        if (buf.len != msg_len) {
            //std.log.info("realloc {} to {}", .{buf.len, msg_len});
            global.put_img_buf = try global.arena.realloc(buf, msg_len);
        }
    } else {
        global.put_img_buf = try global.arena.alloc(u8, msg_len);
    }
    const msg = global.put_img_buf.?;

    const msg_data = msg[zigx.put_image.data_offset..];
    var row: u16 = 0;
    while (row < global.window_size.y) : (row += 1) {
        zigx.put_image.serializeNoDataCopy(msg.ptr, stride_u18, .{
            .format = .z_pixmap,
            .drawable_id = global.window_id(),
            .gc_id = global.fg_gc_id(),
            .width = global.window_size.x,
            .height = 1,
            .x = 0,
            .y = @bitCast(row),
            .left_pad = 0,
            .depth = global.image_format.depth,
        });
        var dst_off: usize = 0;
        const y_ratio: f32 = @as(f32, @floatFromInt(row)) / @as(f32, @floatFromInt(global.window_size.y));
        var src_y: usize = @intFromFloat(@trunc(y_ratio * @as(f32, @floatFromInt(wasm4_size.y))));
        if (src_y >= wasm4_size.y) src_y = wasm4_size.y - 1;
        //const src_y_off: usize = src_y * wasm4_size.x;

        const fb_row = fb.ptr + src_y * wasm4.framebuffer_stride;

        var col: usize = 0;
        while (col < global.window_size.x) : (col += 1) {
            const x_ratio: f32 = @as(f32, @floatFromInt(col)) / @as(f32, @floatFromInt(global.window_size.x));
            var src_x: usize = @intFromFloat(@trunc(x_ratio * @as(f32, @floatFromInt(wasm4_size.x))));
            if (src_x >= wasm4_size.x) src_x = wasm4_size.x - 1;

            // 4 pixels per byte
            const color_byte = fb_row[@divTrunc(src_x, 4)];
            const pixel_pos: u2 = @intCast(src_x % 4);
            const shift: u3 = switch (pixel_pos) { 0 => 0, 1 => 2, 2 => 4, 3 => 6 };
            const color_palette_index: u2 = @intCast(0x3 & (color_byte >> shift));

            switch (global.image_format.depth) {
                16 => @panic("todo"),
                24 => {
                    const color: u32 = palette[color_palette_index];
                    msg_data[dst_off + 0] = @intCast(0xff & (color >>  0)); // blue
                    msg_data[dst_off + 1] = @intCast(0xff & (color >>  8)); // green
                    msg_data[dst_off + 2] = @intCast(0xff & (color >> 16)); // red
                },
                32 => @panic("todo"),
                else => |d| std.debug.panic("TODO: implement image depth {}", .{d}),
            }
            dst_off += global.image_format.bits_per_pixel / 8;
        }
        try sendAll(sock, msg);
    }
}

const fd_set = extern struct {
    fd_count: u32,
    fd_array: [1]ws2_32.SOCKET,
};
const Timeval = struct { tv_sec: c_long, tv_usec: c_long };
extern "ws2_32" fn select(
    nfds: i32,
    readfds: ?*fd_set,
    writefds: ?*fd_set,
    exceptfds: ?*fd_set,
    timeout: ?*const Timeval,
) callconv(std.os.windows.WINAPI) i32;

fn waitSocketReadable(sock: std.os.socket_t, timeout: u31) !bool {
    if (builtin.os.tag == .windows) {
        const timeval = Timeval{
            .tv_sec = @divTrunc(timeout, 1000),
            .tv_usec = @intCast(1000 * @mod(timeout, 1000)),
        };
        var read_set = fd_set{ .fd_count = 1, .fd_array = [_]ws2_32.SOCKET{ sock } };
        return switch (select(0, &read_set, null, null, &timeval)) {
            0 => false, // timeout
            1 => true,
            else => std.debug.panic("select failed, error={s}", .{@tagName(ws2_32.WSAGetLastError())}),
        };
    }
    var pollfds = [_]std.os.pollfd{
        .{
            .fd = sock,
            .events = std.os.POLL.IN,
            .revents = 0,
        },
    };
    const result = try std.os.poll(&pollfds, timeout);
    if (result == 0) {
        return false; // timeout
    }
    if (result != 1) std.debug.panic("poll unexpectedly returned {}", .{result});
    return true;
}

// ZFormat
// depth:
//     bits-per-pixel: 1, 4, 8, 16, 24, 32
//         bpp can be larger than depth, when it is, the
//         least significant bits hold the pixmap data
//         when bpp is 4, order of nibbles in the bytes is the
//         same as the image "byte-order"
//     scanline-pad: 8, 16, 32
const ImageFormat = struct {
    endian: std.builtin.Endian,
    depth: u8,
    bits_per_pixel: u8,
    scanline_pad: u8,
};
fn getImageFormat(
    endian: std.builtin.Endian,
    formats: []const align(4) zigx.Format,
    root_depth: u8,
) !ImageFormat {
    var opt_match_index: ?usize = null;
    for (formats, 0..) |format, i| {
        if (format.depth == root_depth) {
            if (opt_match_index) |_|
                return error.MultiplePixmapFormatsSameDepth;
            opt_match_index = i;
        }
    }
    const match_index = opt_match_index orelse
        return error.MissingPixmapFormat;
    return ImageFormat {
        .endian = endian,
        .depth = root_depth,
        .bits_per_pixel = formats[match_index].bits_per_pixel,
        .scanline_pad = formats[match_index].scanline_pad,
    };
}

fn calcStride(
    bits_per_pixel: u8,
    scanline_pad: u8,
    width: u16,
) usize {
    std.debug.assert(0 == (bits_per_pixel & 0x7));
    std.debug.assert(0 == (scanline_pad & 0x7));
    const bytes_per_pixel = bits_per_pixel / 8;
    return std.mem.alignForward(
        usize,
        @as(usize, @intCast(bytes_per_pixel)) * @as(usize, @intCast(width)),
        scanline_pad / 8,
    );
}

fn sendAll(sock: std.os.socket_t, data: []const u8) !void {
    var changed_to_blocking = false;
    defer if (changed_to_blocking) {
        updateSocketBlocking(sock, .nonblocking);
    };

    var total_sent: usize = 0;
    while (total_sent != data.len) {
        const last_sent = zigx.writeSock(sock, data[total_sent..], 0) catch |err| switch (err) {
            error.WouldBlock => {
                if (changed_to_blocking) @panic("possible?");
                //std.log.info("temporarily set the socket to blocking mode", .{});
                updateSocketBlocking(sock, .blocking);
                changed_to_blocking = true;
                continue;
            },
            error.BrokenPipe => {
                std.log.info("X server connection closed", .{});
                std.os.exit(0);
            },
            else => |e| return e,
        };
        if (last_sent == 0) {
            std.debug.panic("write sock returned 0!", .{});
        }
        total_sent += last_sent;
    }
}

fn onConfigureNotify(msg: zigx.Event.ConfigureNotify) void {
    const new_window_size = Size{ .x = msg.width, .y = msg.height };
    if (!global.window_size.equals(new_window_size)) {
        std.log.info("X11 window size changed from {}x{} to {}x{}", .{
            global.window_size.x, global.window_size.y,
            new_window_size.x, new_window_size.y,
        });
        global.window_size = new_window_size;
    }
}

const Blocking = enum { blocking, nonblocking };

fn updateSocketBlocking(sock: std.os.socket_t, blocking: Blocking) void {
    if (builtin.os.tag == .windows) {
        var nonblocking: c_ulong = switch (blocking) { .blocking => 0, .nonblocking => 1 };
        if (ws2_32.SOCKET_ERROR == ws2_32.ioctlsocket(sock, ws2_32.FIONBIO, &nonblocking)) {
            std.log.err("ioctlsocket failed, error={s}", .{@tagName(ws2_32.WSAGetLastError())});
            std.os.exit(0xff);
        }
    } else {
        const flags = try std.os.fcntl(sock, std.os.F.GETFL, 0);
        const currently_blocking: Blocking = if (0 == (flags & std.os.O.NONBLOCK)) .blocking else .nonblocking;
        if (blocking == currently_blocking) {
            std.log.warn("socket is already in {s} mode", .{blocking});
            return;
        }
        const new_flags = switch (blocking) {
            .blocking => flags & ~std.os.O.NONBLOCK,
            .nonblocking => flags | std.os.O.NONBLOCK,
        };
        //std.log.info("socket flags 0x{x}", .{flags});
        _ = try std.os.fcntl(sock, std.os.F.SETFL, new_flags);
    }
}
