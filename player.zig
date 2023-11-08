const builtin = @import("builtin");
const std = @import("std");
const zware = @import("zware");
const wasm4 = @import("wasm4.zig");
const font = @import("font.zig").font;

const MappedFile = @import("MappedFile.zig");

pub const std_options = struct {
    pub const log_level = .info;
};

pub fn oom(e: error{OutOfMemory}) noreturn {
    @panic(@errorName(e));
}
pub fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.log.err(fmt, args);
    std.os.exit(0xff);
}

var windows_args_arena = if (builtin.os.tag == .windows)
    std.heap.ArenaAllocator.init(std.heap.page_allocator) else struct{}{};
pub fn cmdlineArgs() [][*:0]u8 {
    if (builtin.os.tag == .windows) {
        const slices = std.process.argsAlloc(windows_args_arena.allocator()) catch |err| switch (err) {
            error.OutOfMemory => oom(error.OutOfMemory),
            error.InvalidCmdLine => @panic("InvalidCmdLine"),
            error.Overflow => @panic("Overflow while parsing command line"),
        };
        const args = windows_args_arena.allocator().alloc([*:0]u8, slices.len - 1) catch |e| oom(e);
        for (slices[1..], 0..) |slice, i| {
            args[i] = slice.ptr;
        }
        return args;
    }
    return std.os.argv.ptr[1 .. std.os.argv.len];
}

pub fn main() !void {
    const cmdline_args = cmdlineArgs();
    if (cmdline_args.len <= 0) {
        try std.io.getStdErr().writer().writeAll(
            \\Usage: wasm4-vm WASM_FILE
                \\
        );
        std.os.exit(0xff);
    }
    if (cmdline_args.len != 1) {
        std.log.err("expected 1 cmdline argument but got {}", .{cmdline_args.len});
    }

    const wasm_filename = std.mem.span(cmdline_args[0]);

    const wasm_mapped = blk: {
        var wasm_file = std.fs.cwd().openFile(wasm_filename, .{}) catch |err| {
            std.log.err("open file '{s}' failed with {s}", .{wasm_filename, @errorName(err)});
            std.os.exit(0xff);
        };
        defer wasm_file.close();
        break :blk try MappedFile.init(wasm_file, .{ .mode = .read_only });
    };

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    //defer switch (gpa.deinit()) {
    //    .ok => {},
    //    .leak => std.log.err("memory leak", .{}), //@panic("memory leak"),
    //};
    const alloc = gpa.allocator();

    var store = zware.Store.init(alloc);
    defer store.deinit();

    try wasm4InitStore(&store);

    var module = zware.Module.init(alloc, wasm_mapped.mem);
    defer module.deinit();
    try module.decode();

    var instance = zware.Instance.init(alloc, &store, module);
    try instance.instantiate();
    defer instance.deinit();

    try wasm4InitInstance(instance);

    var has_start = false;
    var has_update = false;
    for (instance.module.exports.list.items) |e| {
        if (std.mem.eql(u8, e.name, "start")) {
            has_start = true;
        } else if (std.mem.eql(u8, e.name, "update")) {
            has_update = true;
        } else {
            std.log.warn("unknown export '{s}'", .{e.name});
        }
    }
    if (!has_update) {
        std.log.err("wasm file is missing the 'update' export", .{});
    }
    if (has_start) {
        try instance.invoke("start", &[_]u64{}, &[_]u64{}, .{});
    }
    try @import("x11backend.zig").go(&instance);
}

fn wasm4InitStore(store: *zware.Store) !void {
    try store.exposeMemory("env", "memory", 1, 1);

    // TODO: zware can't do varargs yet?
    //try store.exposeHostFunction("env", "tracef", tracef, &[_]zware.ValType{ .I32, .I32 }, &[_]zware.ValType{ });
    try store.exposeHostFunction("env", "trace", trace, &[_]zware.ValType{ .I32 }, &[_]zware.ValType{ });
    try store.exposeHostFunction("env", "traceUtf8", traceUtf8, &[_]zware.ValType{ .I32, .I32 }, &[_]zware.ValType{ });
    try store.exposeHostFunction("env", "text", text, &[_]zware.ValType{ .I32, .I32, .I32 }, &[_]zware.ValType{ });
    try store.exposeHostFunction("env", "textUtf8", textUtf8, &[_]zware.ValType{
        .I32, // str
        .I32, .I32, // x, y
        .I32, // ?
    }, &[_]zware.ValType{ });
    try store.exposeHostFunction("env", "hline", hline, &[_]zware.ValType{ .I32, .I32, .I32 }, &[_]zware.ValType{ });
    try store.exposeHostFunction("env", "vline", vline, &[_]zware.ValType{ .I32, .I32, .I32 }, &[_]zware.ValType{ });
    try store.exposeHostFunction("env", "line", line, &[_]zware.ValType{ .I32, .I32, .I32, .I32 }, &[_]zware.ValType{ });
    try store.exposeHostFunction("env", "rect", rect, &[_]zware.ValType{ .I32, .I32, .I32, .I32 }, &[_]zware.ValType{ });
    try store.exposeHostFunction("env", "oval", oval, &[_]zware.ValType{ .I32, .I32, .I32, .I32 }, &[_]zware.ValType{ });
    try store.exposeHostFunction("env", "blit", blit, &[_]zware.ValType{
        .I32, // sprite_ptr
        .I32, .I32, // x, y
        .I32, .I32, // width, height
        .I32, // flags
    }, &[_]zware.ValType{ });
    try store.exposeHostFunction("env", "blitSub", blit, &[_]zware.ValType{
        .I32, // sprite_ptr
        .I32, .I32, // x, y
        .I32, .I32, // width, height
        .I32, .I32, // srcX, srcY
        .I32, // stride
        .I32, // flags
    }, &[_]zware.ValType{ });
    try store.exposeHostFunction("env", "tone", diskr, &[_]zware.ValType{ .I32, .I32, .I32, .I32 }, &[_]zware.ValType{ });
    try store.exposeHostFunction("env", "diskr", diskr, &[_]zware.ValType{ .I32, .I32 }, &[_]zware.ValType{ });
}
fn wasm4InitInstance(instance: zware.Instance) !void {
    const mem = wasm4.getMem(instance);
    const palette: *align(1) [4]u32 = @ptrCast(mem + wasm4.palette_addr);
    palette[0] = 0xe0f8cf;
    palette[1] = 0x86c06c;
    palette[2] = 0x306850;
    palette[3] = 0x071821;
    mem[wasm4.draw_colors_addr + 0] = 0x03;
    mem[wasm4.draw_colors_addr + 1] = 0x12;
}

fn tracef(vm: *zware.VirtualMachine) zware.WasmError!void {
    //const str_addr: usize = @intCast(vm.popAnyOperand());
    _ = vm;
    std.log.warn("todo: tracef", .{});
}

fn trace(vm: *zware.VirtualMachine) zware.WasmError!void {
    const str_addr = vm.popOperand(u32);
    const mem = wasm4.getMem(vm.inst.*);
    const str_ptr = @as([*:0]u8, @ptrCast(mem + str_addr));
    std.io.getStdErr().writer().print("{s}\n", .{str_ptr}) catch |err|
        std.debug.panic("log to stderr failed with {s}", .{@errorName(err)});
}

fn traceUtf8(vm: *zware.VirtualMachine) zware.WasmError!void {
    const str_len = vm.popOperand(u32);
    const str_addr = vm.popOperand(u32);
    const mem = wasm4.getMem(vm.inst.*);
    const slice = (mem + str_addr)[0 .. str_len];
    std.io.getStdErr().writer().print("{s}\n", .{slice}) catch |err|
        std.debug.panic("log to stderr failed with {s}", .{@errorName(err)});
}

const fb_bit_stride = 160 * 2; // 2 bits per pixel

fn XY(comptime T: type) type { return struct { x: T, y: T }; }
fn Rect(comptime T: type) type { return struct { x: T, y: T, width: T, height: T }; }

fn textCommon(mem: [*]u8, str: []const u8, x: i32, y: i32) void {
    const fb = mem[wasm4.framebuffer_addr..][0 .. wasm4.framebuffer_len];
    const fg_color = wasm4.getDrawColor(mem, ._1);
    const bg_color = wasm4.getDrawColor(mem, ._2);

    var next_x: i32 = x;
    for (str) |c| {
        if (c < 32) {
            std.log.warn("unhandled control character 0x{x}", .{c});
            continue;
        }
        const c_index = c - 32;
        if (c_index > font.len) {
            std.log.warn("invalid text character 0x{x}", .{c});
            continue;
        }

        if (getFbRect(next_x, y, 8, 8)) |fb_rect| {
            const fb_bit_start: usize = @as(usize, fb_rect.y) * fb_bit_stride + 2 * @as(usize, fb_rect.x);
            blit1bpp(
                fb, fb_bit_start,
                8, 8,
                &font[c_index], 0, 8,
                bg_color, fg_color,
            );
        }
        next_x += 8;
    }
}

pub fn text(vm: *zware.VirtualMachine) zware.WasmError!void {
    const y = vm.popOperand(i32);
    const x = vm.popOperand(i32);
    const str_addr: usize = @intCast(vm.popAnyOperand());

    const mem = wasm4.getMem(vm.inst.*);
    const str = std.mem.span(@as([*:0]u8, @ptrCast(mem + str_addr)));
    textCommon(mem, str, x, y);
}

pub fn textUtf8(vm: *zware.VirtualMachine) zware.WasmError!void {
    const y = vm.popOperand(i32);
    const x = vm.popOperand(i32);
    const str_len: usize = @intCast(vm.popAnyOperand());
    const str_addr: usize = @intCast(vm.popAnyOperand());

    const mem = wasm4.getMem(vm.inst.*);
    textCommon(mem, (mem + str_addr)[0 .. str_len], x, y);
}

fn getFbRect(x: i32, y: i32, width: u32, height: u32) ?Rect(u8) {
    if (x >= 160) return null;
    if (y >= 160) return null;

    const limit_x: i32 = x + @as(i32, @intCast(width));
    if (limit_x <= 0) return null;
    const limit_y: i32 = y + @as(i32, @intCast(height));
    if (limit_y <= 0) return null;

    const pos = XY(u8) {
        .x = if (x < 0) 0 else @intCast(x),
        .y = if (y < 0) 0 else @intCast(y),
    };
    return .{
        .x = pos.x,
        .y = pos.y,
        .width = @intCast(@min(limit_x, 160) - pos.x),
        .height = @intCast(@min(limit_y, 160) - pos.y),
    };
}

fn hline(vm: *zware.VirtualMachine) zware.WasmError!void {
    const len = vm.popOperand(u32);
    const y = vm.popOperand(i32);
    const x = vm.popOperand(i32);

    const mem = wasm4.getMem(vm.inst.*);
    // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
    // TODO: do we need to popOperands if we're just going to return early?
    const color = wasm4.getDrawColor(mem, ._1) orelse return;
    std.log.info("todo: hline {},{} len={} color={}", .{x, y, len, color});
}

fn vline(vm: *zware.VirtualMachine) zware.WasmError!void {
    const len = vm.popOperand(u32);
    const y = vm.popOperand(i32);
    const x = vm.popOperand(i32);

    const mem = wasm4.getMem(vm.inst.*);
    // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
    // TODO: do we need to popOperands if we're just going to return early?
    const color = wasm4.getDrawColor(mem, ._1) orelse return;
    std.log.info("todo: vline {},{} len={} color={}", .{x, y, len, color});
}

fn line(vm: *zware.VirtualMachine) zware.WasmError!void {
    const y2 = vm.popOperand(i32);
    const x2 = vm.popOperand(i32);
    const y1 = vm.popOperand(i32);
    const x1 = vm.popOperand(i32);

    const mem = wasm4.getMem(vm.inst.*);
    const color = wasm4.getDrawColor(mem, ._1) orelse return;
    std.log.info("todo: line {},{} {},{} color={}", .{x1, y1, x2, y2, color});
}

fn rect(vm: *zware.VirtualMachine) zware.WasmError!void {
    const mem = wasm4.getMem(vm.inst.*);
    const fb = mem[wasm4.framebuffer_addr..][0 .. wasm4.framebuffer_len];

    const height = vm.popOperand(u32);
    const width = vm.popOperand(u32);
    const y = vm.popOperand(i32);
    const x = vm.popOperand(i32);
    //std.log.info("rect {},{} {}x{}", .{x, y, width, height});

    const fb_rect = getFbRect(x, y, width, height) orelse return;
    const draw_color1 = wasm4.getDrawColor(mem, ._1);
    const draw_color2 = wasm4.getDrawColor(mem, ._2);
    const border_color: u2 = blk: {
        if (draw_color2) |c| {
            //std.log.info("rect {},{} {}x{} c1={?} c2={}", .{x, y, width, height, draw_color1, c});
            break :blk c;
        }
        if (draw_color1) |c| break :blk c;
        return;
    };
    var fb_bit_offset: usize = @as(usize, fb_rect.y) * fb_bit_stride + 2 * @as(usize, fb_rect.x);

    setPixels(fb, fb_bit_offset, border_color, fb_rect.width);
    fb_bit_offset += fb_bit_stride;
    if (fb_rect.height >= 3) {
        for (1 .. fb_rect.height - 1) |_| {
            setPixel(fb, fb_bit_offset, border_color);
            if (draw_color1) |color| {
                if (fb_rect.width >= 3) {
                    setPixels(fb, fb_bit_offset + 2, color, fb_rect.width - 2);
                }
            }
            if (fb_rect.width >= 2) {
                setPixel(fb, fb_bit_offset + 2*(fb_rect.width - 1), border_color);
            }
            fb_bit_offset += fb_bit_stride;
        }
    }
    if (fb_rect.height >= 2) {
        setPixels(fb, fb_bit_offset, border_color, fb_rect.width);
    }
}

fn oval(vm: *zware.VirtualMachine) zware.WasmError!void {
    std.log.warn("oval not implemented, using rect instead", .{});
    return rect(vm);
}

const BLIT_2BPP = 1;

fn blit(vm: *zware.VirtualMachine) zware.WasmError!void {
    const mem = wasm4.getMem(vm.inst.*);
    const fb = mem[wasm4.framebuffer_addr..][0 .. wasm4.framebuffer_len];

    const flags = vm.popOperand(u32);
    const height = vm.popOperand(u32);
    const width = vm.popOperand(u32);
    const y = vm.popOperand(i32);
    const x = vm.popOperand(i32);
    const sprite_addr: usize = @intCast(vm.popAnyOperand());

    //std.log.info("blit ptr={} pos={},{} size={}x{} flags=0x{x}", .{sprite_addr, x, y, width, height, flags});
    const sprite_ptr = mem + sprite_addr;

    const fb_rect = getFbRect(x, y, width, height) orelse return;
    const sprite_offset = XY(u8){
        .x = @intCast(fb_rect.x - x),
        .y = @intCast(fb_rect.y - y),
    };

    var fb_bit_offset: usize = @as(usize, fb_rect.y) * fb_bit_stride + 2 * @as(usize, fb_rect.x);

    if ((flags & BLIT_2BPP) != 0) {
        var sprite_bit_offset: usize =
            @as(usize, sprite_offset.y) * @as(usize, width) * 2 +
            @as(usize, sprite_offset.x) * 2;
        const colors = [4]?u2{
            wasm4.getDrawColor(mem, ._1),
            wasm4.getDrawColor(mem, ._2),
            wasm4.getDrawColor(mem, ._3),
            wasm4.getDrawColor(mem, ._4),
        };
        for (0 .. fb_rect.height) |_| {
            blitRow2bpp(
                fb, fb_bit_offset,
                sprite_ptr, sprite_bit_offset,
                fb_rect.width,
                colors,
            );
            fb_bit_offset += fb_bit_stride;
            sprite_bit_offset += width * 2; // 2 bits per pixel
        }
    } else {
        const sprite_bit_start: usize =
            @as(usize, sprite_offset.y) * @as(usize, width) +
            @as(usize, sprite_offset.x);
        blit1bpp(
            fb, fb_bit_offset,
            fb_rect.width, fb_rect.height,
            sprite_ptr, sprite_bit_start,
            width,
            wasm4.getDrawColor(mem, ._1),
            wasm4.getDrawColor(mem, ._2),
        );
    }
}

fn blit1bpp(
    fb: *[wasm4.framebuffer_len]u8, fb_bit_start: usize,
    width: u8, height: u8,
    sprite: [*]const u8, sprite_bit_start: usize, sprite_stride: usize,
    color1: ?u2, color2: ?u2,
) void {
    var fb_bit_offset = fb_bit_start;
    var sprite_bit_offset = sprite_bit_start;
    for (0 .. height) |_| {
        blitRow1bpp(
            fb, fb_bit_offset,
            sprite, sprite_bit_offset,
            width,
            color1, color2,
        );
        fb_bit_offset += fb_bit_stride;
        sprite_bit_offset += sprite_stride;
    }
}

fn blitRow1bpp(
    dst: [*]u8, dst_bit_offset: usize,
    src: [*]const u8, src_bit_offset: usize,
    len: usize,
    draw_color1: ?u2,
    draw_color2: ?u2,
) void {
    for (0 .. len) |i| {
        const src_val: u8 = src[ (src_bit_offset + i) / 8 ];
        const shift: u3 = @intCast(((src_bit_offset + i) % 8));
        const src_bit = @as(u8, 0x80) >> shift;
        const color_opt: ?u2 = if ((src_val & src_bit) == 0) draw_color1 else draw_color2;
        if (color_opt) |c| {
            setPixel(dst, dst_bit_offset + 2*i, c);
        }
    }
}

fn blitRow2bpp(
    dst: [*]u8, dst_bit_offset: usize,
    src: [*]const u8, src_bit_offset: usize,
    len: usize,
    colors: [4]?u2,
) void {
    for (0 .. len) |i| {
        const color = colors[getPixel(src, src_bit_offset + 2*i)] orelse continue;
        setPixel(dst, dst_bit_offset + 2*i, color);
    }
}

fn getPixel(ptr: [*]const u8, bit_offset: usize) u2 {
    if (bit_offset % 2 != 0) unreachable;
    const val = ptr[bit_offset / 8];
    const shift: u3 = @intCast(6 - 2 * ((bit_offset/2) % 4));
    return @intCast(0x3 & (val >> shift));
}

fn setPixel(dst: [*]u8, bit_offset: usize, color: u2) void {
    if (bit_offset % 2 != 0) unreachable;

    //std.log.info("setPixel bit_offset={}", .{bit_offset});
    const val = dst[bit_offset / 8];
    dst[bit_offset / 8] = switch (@as(u2, @intCast((bit_offset/2) % 4))) {
        0 => (val & 0b00111111) | (@as(u8, color) << 6),
        1 => (val & 0b11001111) | (@as(u8, color) << 4),
        2 => (val & 0b11110011) | (@as(u8, color) << 2),
        3 => (val & 0b11111100) | (@as(u8, color) << 0),
    };
}

fn setPixels(dst: [*]u8, bit_offset: usize, color: u2, len: u8) void {
    for (0 .. len) |i| {
        setPixel(dst, bit_offset + 2*i, color);
    }
}


fn blitSub(vm: *zware.VirtualMachine) zware.WasmError!void {
    _ = vm;
    @panic("todo: blitSub");
}

fn tone(vm: *zware.VirtualMachine) zware.WasmError!void {
    const flags = vm.popOperand(u32);
    const volume = vm.popOperand(u32);
    const dur = vm.popOperand(u32);
    const freq = vm.popOperand(u32);
    _ = freq;
    _ = dur;
    _ = volume;
    _ = flags;
    std.log.warn("todo: implement tone", .{});
}

fn diskr(vm: *zware.VirtualMachine) zware.WasmError!void {
    const size = vm.popOperand(u32);
    const dest = vm.popOperand(u32);
    _ = size;
    _ = dest;
    std.log.warn("todo: implement diskr", .{});
}
