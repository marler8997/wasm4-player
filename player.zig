const builtin = @import("builtin");
const std = @import("std");
const zware = @import("zware");
const wasm4 = @import("wasm4.zig");

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

    try initWasm4(&store);

    var module = zware.Module.init(alloc, wasm_mapped.mem);
    defer module.deinit();
    try module.decode();

    var instance = zware.Instance.init(alloc, &store, module);
    try instance.instantiate();
    defer instance.deinit();

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

fn initWasm4(store: *zware.Store) !void {
    try store.exposeMemory("env", "memory", 1, 1);
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
    try store.exposeHostFunction("env", "textUtf8", blit, &[_]zware.ValType{
        .I32, // str
        .I32, .I32, // x, y
        .I32, // ?
    }, &[_]zware.ValType{ });
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

    if ((flags & BLIT_2BPP) != 0) {
        std.log.err("todo: blit 2bpp", .{});
    } else {
        const draw_colors = mem[wasm4.draw_colors_addr];
        const draw_color1: u3 = @intCast((draw_colors >> 0) % 5);
        const draw_color2: u3 = @intCast((draw_colors >> 4) % 5);

        const bit_stride = 160 * 2; // 2 bits per pixel
        const y_usize = std.math.cast(usize, y) orelse @panic("todo");
        const x_usize = std.math.cast(usize, x) orelse @panic("todo");

        var fb_bit_offset: usize = y_usize * bit_stride + (x_usize * 2);
        var sprite_bit_offset: usize = 0;

        for (0 .. height) |row| {
            const fb_y = y_usize + row;
            //std.log.info("row {} (fb_y={})", .{row, fb_y});
            if (fb_y >= 160) break;
            blit1bpp(
                fb, fb_bit_offset,
                sprite_ptr, sprite_bit_offset,
                x_usize, width,
                draw_color1, draw_color2,
            );
            fb_bit_offset += bit_stride;
            sprite_bit_offset += width;
        }
    }
}

fn blit1bpp(
    dst: [*]u8, dst_bit_offset: usize,
    src: [*]const u8, src_bit_offset: usize,
    x: usize,
    len: usize,
    draw_color1: u3,
    draw_color2: u3,
) void {
    for (0 .. len) |i| {
        if (x + i >= 160) return;
        const src_val: u8 = src[ (src_bit_offset + i) / 8 ];
        const shift: u3 = @intCast(((src_bit_offset + i) % 8));
        const src_bit = @as(u8, 1) << shift;
        const color = if ((src_val & src_bit) == 0) draw_color1 else draw_color2;
        if (color != 0) {
            setPixel(dst, dst_bit_offset + 2*i, @intCast(color - 1));
        }
    }
}

fn setPixel(dst: [*]u8, bit_offset: usize, color: u2) void {
    //std.log.info("setPixel bit_offset={}", .{bit_offset});
    const val = dst[bit_offset / 4];
    dst[bit_offset / 4] = switch (@as(u2, @intCast(bit_offset % 4))) {
        0 => (val & 0b00111111) | (@as(u8, color) << 6),
        1 => (val & 0b11001111) | (@as(u8, color) << 4),
        2 => (val & 0b11110011) | (@as(u8, color) << 2),
        3 => (val & 0b11111100) | (@as(u8, color) << 0),
    };
}

// TODO: this could be more efficient if aligned
fn bitcpy(dst: [*]u8, dst_off: usize, src: [*]const u8, src_off: usize, len: usize) void {
    for (0 .. len) |i| {
        var dst_val: u8 = dst[ (dst_off + i) / 8 ];
        const src_val: u8 = src[ (src_off + i) / 8 ];
        const src_bit = @as(u8, 1) << @as(u3, @intCast(((src_off + i) % 8)));

        if ((src_val & src_bit) != 0) {
            dst_val |= src_bit;
        } else {
            dst_val &= ~src_bit;
        }
        dst[ (dst_off + i) / 8 ] = dst_val;
    }
}

fn blitSub(vm: *zware.VirtualMachine) zware.WasmError!void {
    _ = vm;
    @panic("todo: blitSub");
}
