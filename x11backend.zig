const std = @import("std");
const zware = @import("zware");
const zigx = @import("x");
const x11common = @import("x11common.zig");

const ResourceIds = struct {
    base: u32,
    pub fn window(self: ResourceIds) u32 { return self.base; }
    pub fn bg_gc(self: ResourceIds) u32 { return self.base + 1; }
    pub fn fg_gc(self: ResourceIds) u32 { return self.base + 2; }
};

pub fn go(instance: *zware.Instance) !void {
    try zigx.wsaStartup();

    var arena_instance = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();

    const conn = try x11common.connect(arena);
    defer std.os.shutdown(conn.sock, .both) catch {};

    const screen = blk: {
        const fixed = conn.setup.fixed();
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
        break :blk screen;
    };

    // TODO: maybe need to call conn.setup.verify or something?
    const resource_ids = ResourceIds{ .base = conn.setup.fixed().resource_id_base };
    {
        var msg_buf: [zigx.create_window.max_len]u8 = undefined;
        const len = zigx.create_window.serialize(&msg_buf, .{
            .window_id = resource_ids.window(),
            .parent_window_id = screen.root,
            .depth = 0, // we don't care, just inherit from the parent
            .x = 0, .y = 0,
            .width = 160, .height = 160,
            .border_width = 0, // TODO: what is this?
            .class = .input_output,
            .visual_id = screen.root_visual,
        }, .{
            .bg_pixel = 0xaabbccdd,
            .event_mask =
                  zigx.event.key_press
                | zigx.event.key_release
                | zigx.event.button_press
                | zigx.event.button_release
                | zigx.event.enter_window
                | zigx.event.leave_window
                | zigx.event.pointer_motion
                | zigx.event.keymap_state
                | zigx.event.exposure
                ,
        });
        try conn.send(msg_buf[0..len]);
    }

    {
        var msg_buf: [zigx.create_gc.max_len]u8 = undefined;
        const len = zigx.create_gc.serialize(&msg_buf, .{
            .gc_id = resource_ids.bg_gc(),
            .drawable_id = resource_ids.window(),
        }, .{
            .foreground = screen.black_pixel,
        });
        try conn.send(msg_buf[0..len]);
    }
    {
        var msg_buf: [zigx.create_gc.max_len]u8 = undefined;
        const len = zigx.create_gc.serialize(&msg_buf, .{
            .gc_id = resource_ids.fg_gc(),
            .drawable_id = resource_ids.window(),
        }, .{
            .background = screen.black_pixel,
            .foreground = 0xffaadd,
        });
        try conn.send(msg_buf[0..len]);
    }

    {
        var msg: [zigx.map_window.len]u8 = undefined;
        zigx.map_window.serialize(&msg, resource_ids.window());
        try conn.send(&msg);
    }

    var double_buf = try zigx.DoubleBuffer.init(
        std.mem.alignForward(usize, 1000, std.mem.page_size),
        .{ .memfd_name = "ZigX11DoubleBuffer" },
    );
    // double_buf.deinit() (not necessary)
    std.log.info("read buffer capacity is {}", .{double_buf.half_len});
    var buf = double_buf.contiguousReadBuffer();

    {
        const flags = try std.os.fcntl(conn.sock, std.os.F.GETFL, 0);
        std.log.info("socket flags 0x{x}", .{flags});
        _ = try std.os.fcntl(conn.sock, std.os.F.SETFL, flags | std.os.O.NONBLOCK);
    }

    const micros_per_frame = @divTrunc(1000000, 60);
    var delay_update_timestamp: ?i64 = null;

    while (true) {
        {
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
                    try instance.invoke("update", &[_]u64{}, &[_]u64{}, .{});
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
            // TODO: use a timeout so we can update the frame
            const len = zigx.readSock(conn.sock, recv_buf, 0) catch |err| switch (err) {
                error.WouldBlock => continue,
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
                    std.log.info("key_press: keycode={}", .{msg.keycode});
                },
                .key_release => |msg| {
                    std.log.info("key_release: keycode={}", .{msg.keycode});
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
                .expose => |msg| {
                    std.log.info("expose: {}", .{msg});
                    try renderX11(conn.sock, resource_ids);
                },
                .mapping_notify => |msg| {
                    std.log.info("mapping_notify: {}", .{msg});
                },
                .no_exposure => |msg| std.debug.panic("unexpected no_exposure {}", .{msg}),
                .unhandled => |msg| {
                    std.log.info("todo: server msg {}", .{msg});
                    return error.UnhandledServerMsg;
                },
                .map_notify,
                .reparent_notify,
                .configure_notify,
                => unreachable, // did not register for these
            }
        }
    }
}

fn renderX11(sock: std.os.socket_t, resource_ids: ResourceIds) !void {
    _ = sock;
    _ = resource_ids;
}

fn waitSocketReadable(sock: std.os.socket_t, timeout: i32) !bool {
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
