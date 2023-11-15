const builtin = @import("builtin");
const std = @import("std");
const build_options = @import("build_options");
const zware = @import("zware");
const wasm4 = @import("wasm4.zig");
const font = @import("font.zig").font;
const bbmem = @import("bbmem.zig");

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

    return switch (build_options.wasm) {
        .zware => try runZware(wasm_mapped.mem),
        .bytebox => try runBytebox(wasm_mapped.mem),
    };
}

fn runZware(wasm_mem: []const u8) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    //defer switch (gpa.deinit()) {
    //    .ok => {},
    //    .leak => std.log.err("memory leak", .{}), //@panic("memory leak"),
    //};
    const alloc = gpa.allocator();

    var store = zware.Store.init(alloc);
    defer store.deinit();

    try wasm4InitStore(&store);

    var module = zware.Module.init(alloc, wasm_mem);
    defer module.deinit();
    try module.decode();

    var instance = zware.Instance.init(alloc, &store, module);
    try instance.instantiate();
    defer instance.deinit();

    wasm4InitMem(wasm4.getMem(instance));

    var has_underscore_start = false;
    var has_underscore_initialize = false;
    var has_start = false;
    var has_update = false;
    for (instance.module.exports.list.items) |e| {
        if (false) {
        } else if (std.mem.eql(u8, e.name, "_start")) {
            has_underscore_start = true;
        } else if (std.mem.eql(u8, e.name, "_initialize")) {
            has_underscore_initialize = true;
        } else if (std.mem.eql(u8, e.name, "start")) {
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
    std.log.info("exports _start={} _initialize={} start={}", .{
        has_underscore_start,
        has_underscore_initialize,
        has_start,
    });
    if (has_underscore_start) {
        try instance.invoke("_start", &[_]u64{}, &[_]u64{}, .{});
    }
    if (has_underscore_initialize) {
        try instance.invoke("_initialize", &[_]u64{}, &[_]u64{}, .{});
    }
    if (has_start) {
        try instance.invoke("start", &[_]u64{}, &[_]u64{}, .{});
    }
    try @import("x11backend.zig").go(&instance);
}

fn noResize(mem: ?[*]u8, new_size_bytes: usize, old_size_bytes: usize, userdata: ?*anyopaque) ?[*]u8 {
    _ = mem;
    //_ = new_size_bytes;
    //_ = old_size_bytes;
    _ = userdata;
    std.debug.assert(old_size_bytes == 0);
    std.debug.assert(new_size_bytes ==  65536);
    return &bbmem.array;
    //re
    //std.log.info("{} {}", .{new_size_bytes, old_size_bytes});
    //@panic("noresize");
}
fn noFree(mem: ?[*]u8, size_bytes: usize, userdata: ?*anyopaque) void {
    _ = mem;
    _ = size_bytes;
    _ = userdata;
    @panic("nofree");
}

fn runBytebox(wasm_mem: []const u8) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    //defer switch (gpa.deinit()) {
    //    .ok => {},
    //    .leak => std.log.err("memory leak", .{}), //@panic("memory leak"),
    //};
    const alloc = gpa.allocator();

    const bytebox = @import("bytebox");
    var module_definition = bytebox.ModuleDefinition.init(alloc, .{});
    defer module_definition.deinit();
    try module_definition.decode(wasm_mem);

    var imports = [_]bytebox.ModuleImportPackage{
        bytebox.ModuleImportPackage.init("env", null, null, alloc) catch |e| oom(e),
    };
    const env = &imports[0];
    var host_mem = bytebox.MemoryInstance.init(
        .{ .min = 0, .max = 1 },
        .{
            .resize_callback = noResize,
            .free_callback = noFree,
            .userdata = null,
        },
    );
    if (host_mem.grow(1) == false) {
        unreachable;
    }
    env.memories.append(.{
        .name = "memory",
        .data = .{ .Host = &host_mem },
    }) catch |e| oom(e);
    try env.addHostFunction("traceUtf8", &[_]bytebox.ValType{ .I32, .I32 }, &[_]bytebox.ValType{ }, bb_todo, null);
    try env.addHostFunction("blit", &[_]bytebox.ValType{
        .I32, // sprite_ptr
        .I32, .I32, // x, y
        .I32, .I32, // width, height
        .I32, // flags
    }, &[_]bytebox.ValType{ }, bb_blit, null);
    try env.addHostFunction("blitSub", &[_]bytebox.ValType{
        .I32, // sprite_ptr
        .I32, .I32, // x, y
        .I32, .I32, // width, height
        .I32, .I32, // srcX, srcY
        .I32, // stride
        .I32, // flags
    }, &[_]bytebox.ValType{ }, bb_blitSub, null);
    try env.addHostFunction("textUtf8", &[_]bytebox.ValType{
        .I32, // str
        .I32, .I32, // x, y
        .I32, // ?
    }, &[_]bytebox.ValType{ }, bb_textUtf8, null);

    var instance = bytebox.ModuleInstance.init(&module_definition, alloc);
    defer instance.deinit();
    try instance.instantiate(.{
        .imports = &imports,
        //.wasm_memory_external = .{},
    });

    @memset(wasm4.getMem(instance)[0..65536], 0);
    wasm4InitMem(wasm4.getMem(instance));
    //try wasm4InitStore(&store);
    //try wasm4InitInstance(instance);

    var funcs: struct {
        _start: ?bytebox.FunctionHandle = null,
        start: ?bytebox.FunctionHandle = null,
        _initialize: ?bytebox.FunctionHandle = null,
        update: ?bytebox.FunctionHandle = null,
    } = .{};
    for (module_definition.exports.functions.items) |func| {
        if (false) {
        } else if (std.mem.eql(u8, func.name, "_start")) {
            funcs._start = .{ .index = func.index, .type = .Export };
        } else if (std.mem.eql(u8, func.name, "_initialize")) {
            funcs._initialize = .{ .index = func.index, .type = .Export };
        } else if (std.mem.eql(u8, func.name, "start")) {
            funcs.start = .{ .index = func.index, .type = .Export };
        } else if (std.mem.eql(u8, func.name, "update")) {
            funcs.update = .{ .index = func.index, .type = .Export };
        } else {
            std.log.warn("unknown export '{s}'", .{func.name});
        }
    }
    const update = funcs.update orelse fatal("wasm file is missing the 'update' export", .{});
    std.log.info("exports _start={?} _initialize={?} start={?}", .{
        funcs._start,
        funcs._initialize,
        funcs.start,
    });
    if (funcs._start) |_start| {
        try instance.invoke(_start, &[_]bytebox.Val{}, &[_]bytebox.Val{}, .{});
    }
    if (funcs._initialize) |_initialize| {
        try instance.invoke(_initialize, &[_]bytebox.Val{}, &[_]bytebox.Val{}, .{});
    }
    if (funcs.start) |start| {
        try instance.invoke(start, &[_]bytebox.Val{}, &[_]bytebox.Val{}, .{});
    }
    _ = update;
    //bytebox.DebugTrace.traceFunction(&instance, 0, update.index);
    //const did_set = bytebox.DebugTrace.setMode(.Function);
    //const did_set = bytebox.DebugTrace.setMode(.Instruction);
    //std.debug.assert(did_set);
    try @import("x11backend.zig").go(&instance);
}

fn wasm4InitStore(store: *zware.Store) !void {
    try store.exposeMemory("env", "memory", 1, 1);

    try store.exposeHostFunction("env", "tracef", tracef, &[_]zware.ValType{ .I32, .I32 }, &[_]zware.ValType{ });
    try store.exposeHostFunction("env", "trace", trace, &[_]zware.ValType{ .I32 }, &[_]zware.ValType{ });
    try store.exposeHostFunction("env", "traceUtf8", traceUtf8, &[_]zware.ValType{ .I32, .I32 }, &[_]zware.ValType{ });
    try store.exposeHostFunction("env", "text", text, &[_]zware.ValType{ .I32, .I32, .I32 }, &[_]zware.ValType{ });
    try store.exposeHostFunction("env", "textUtf8", textUtf8, &[_]zware.ValType{
        .I32, // str
        .I32, .I32, // x, y
        .I32, // ?
    }, &[_]zware.ValType{ });
    try store.exposeHostFunction("env", "textUtf16", textUtf16, &[_]zware.ValType{ .I32, .I32, .I32, .I32 }, &[_]zware.ValType{});
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
    try store.exposeHostFunction("env", "blitSub", blitSub, &[_]zware.ValType{
        .I32, // sprite_ptr
        .I32, .I32, // x, y
        .I32, .I32, // width, height
        .I32, .I32, // srcX, srcY
        .I32, // stride
        .I32, // flags
    }, &[_]zware.ValType{ });
    try store.exposeHostFunction("env", "tone", diskr, &[_]zware.ValType{ .I32, .I32, .I32, .I32 }, &[_]zware.ValType{ });
    try store.exposeHostFunction("env", "diskr", diskr, &[_]zware.ValType{ .I32, .I32 }, &[_]zware.ValType{ .I32 });
    try store.exposeHostFunction("env", "diskw", diskw, &[_]zware.ValType{ .I32, .I32 }, &[_]zware.ValType{ .I32 });
}
fn wasm4InitMem(mem: [*]u8) void {
    //const mem = wasm4.getMem(instance);
    const palette: *align(1) [4]u32 = @ptrCast(mem + wasm4.palette_addr);
    palette[0] = 0xe0f8cf;
    palette[1] = 0x86c06c;
    palette[2] = 0x306850;
    palette[3] = 0x071821;
    mem[wasm4.draw_colors_addr + 0] = 0x03;
    mem[wasm4.draw_colors_addr + 1] = 0x12;
}

fn onTraceError(e: anytype) noreturn {
    std.debug.panic("trace to stderr failed with {s}", .{@errorName(e)});
}

fn tracef(vm: *zware.VirtualMachine) zware.WasmError!void {
    const stack_addr: usize = @intCast(vm.popAnyOperand());
    const fmt_addr: usize = @intCast(vm.popAnyOperand());

    const mem = wasm4.getMem(vm.inst.*);
    const fmt: [*:0]const u8 = @ptrCast(mem + fmt_addr);
    const stderr = std.io.getStdErr().writer();
    var bw = std.io.bufferedWriter(stderr);

    const stack: [*]align(1) u32 = @ptrCast(mem + stack_addr);
    var stack_offset: usize = 0;
    var last_flush_index: usize = 0;
    var i: usize = 0;
    while (true) : (i += 1) {
        if (fmt[i] != 0 and fmt[i] != '%')
            continue;

        bw.writer().writeAll(fmt[last_flush_index..i]) catch |e| onTraceError(e);
        last_flush_index = i;
        if (fmt[i] == 0)
            break;

        i += 1;
        last_flush_index = i + 1;
        switch (fmt[i]) {
            'c' => @panic("todo"),
            'd' => {
                const value: i32 = @bitCast(stack[stack_offset]);
                stack_offset += 1;
                bw.writer().print("{}", .{value}) catch |e| onTraceError(e);
            },
            'f' => @panic("todo"),
            's' => {
                const str_addr = stack[stack_offset];
                stack_offset += 1;
                const str_ptr: [*:0]const u8 = @ptrCast(mem + str_addr);
                bw.writer().writeAll(std.mem.span(str_ptr)) catch |e| onTraceError(e);
            },
            'x' => {
                const value = stack[stack_offset];
                stack_offset += 1;
                bw.writer().print("{x}", .{value}) catch |e| onTraceError(e);
            },
            0 => {
                std.log.err("tracef format string ended with dangling '%'", .{});
                i -= 1;
                last_flush_index = i;
            },
            else => |spec| {
                i -= 1;
                last_flush_index = i-1;
                std.log.err("tracef unknown format specifier '{c}'", .{spec});
            },
        }
    }
    bw.writer().writeAll("\n") catch |e| onTraceError(e);
    bw.flush() catch |e| onTraceError(e);
}

fn trace(vm: *zware.VirtualMachine) zware.WasmError!void {
    const str_addr = vm.popOperand(u32);
    const mem = wasm4.getMem(vm.inst.*);
    const str_ptr = @as([*:0]u8, @ptrCast(mem + str_addr));
    std.io.getStdErr().writer().print("{s}\n", .{str_ptr}) catch |e| onTraceError(e);
}

fn traceUtf8(vm: *zware.VirtualMachine) zware.WasmError!void {
    const str_len = vm.popOperand(u32);
    const str_addr = vm.popOperand(u32);
    const mem = wasm4.getMem(vm.inst.*);
    const slice = (mem + str_addr)[0 .. str_len];
    std.io.getStdErr().writer().print("{s}\n", .{slice}) catch |e| onTraceError(e);
}

const fb_bit_stride = 160 * 2; // 2 bits per pixel

fn XY(comptime T: type) type { return struct { x: T, y: T }; }
fn Rect(comptime T: type) type { return struct { x: T, y: T, width: T, height: T }; }

fn textCommon(mem: [*]u8, str: []const u8, x: i32, y: i32) void {
    const fb = mem[wasm4.framebuffer_addr..][0 .. wasm4.framebuffer_len];
    const fg_color = wasm4.getDrawColor(mem, ._1);
    const bg_color = wasm4.getDrawColor(mem, ._2);

    var next_x: i32 = x;
    var next_y: i32 = y;
    for (str) |c| {
        if (c < 32) {
            if (c == 0) {
                std.log.warn("unexpected null-terminator", .{});
                return;
            } else if (c == '\n') {
                next_x = x;
                next_y += 8;
            } else {
                std.log.warn("unhandled control character 0x{x}", .{c});
            }
            continue;
        }
        const c_index = c - 32;
        if (c_index > font.len) {
            std.log.warn("invalid text character 0x{x}", .{c});
            continue;
        }

        if (getFbRect(next_x, next_y, 8, 8)) |fb_rect| {
            const sprite_offset = XY(u32){
                .x = @as(u32, @intCast(fb_rect.x - next_x)),
                .y = @as(u32, @intCast(fb_rect.y - next_y)),
            };
            const fb_bit_start: usize = @as(usize, fb_rect.y) * fb_bit_stride + 2 * @as(usize, fb_rect.x);
            const sprite_bit_start: usize =
                @as(usize, sprite_offset.y) * 8 +
                @as(usize, sprite_offset.x);
            blit1bpp(
                fb, fb_bit_start,
                fb_rect.width, fb_rect.height,
                @as([*]const u8, &font[c_index]),
                sprite_bit_start,
                8,
                false, // flip x
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

pub fn textUtf16(vm: *zware.VirtualMachine) zware.WasmError!void {
    _ = vm;
    std.log.warn("textUtf16 not implemented", .{});
}

// Reference Implementation Issue:
//
// if a rect has an "outline", it seems like it adds 2 vertical pixels
// even if the height is 0?  The same is not done for the width.
//

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
    const color = wasm4.getDrawColor(mem, ._1) orelse return;
    const fb_rect = getFbRect(x, y, len, 1) orelse return;
    const fb_bit_offset: usize = @as(usize, fb_rect.y) * fb_bit_stride + 2 * @as(usize, fb_rect.x);
    const fb = mem[wasm4.framebuffer_addr..][0 .. wasm4.framebuffer_len];
    setPixels(fb, fb_bit_offset, color, fb_rect.width);
}

fn vline(vm: *zware.VirtualMachine) zware.WasmError!void {
    const len = vm.popOperand(u32);
    const y = vm.popOperand(i32);
    const x = vm.popOperand(i32);

    const mem = wasm4.getMem(vm.inst.*);
    const color = wasm4.getDrawColor(mem, ._1) orelse return;
    const fb_rect = getFbRect(x, y, 1, len) orelse return;
    const fb = mem[wasm4.framebuffer_addr..][0 .. wasm4.framebuffer_len];
    var fb_bit_offset: usize = @as(usize, fb_rect.y) * fb_bit_stride + 2 * @as(usize, fb_rect.x);
    for (0 .. fb_rect.height) |_| {
        setPixel(fb, fb_bit_offset, color);
        fb_bit_offset += fb_bit_stride;
    }
}

fn line(vm: *zware.VirtualMachine) zware.WasmError!void {
    var y2 = vm.popOperand(i32);
    var x2 = vm.popOperand(i32);
    var y1 = vm.popOperand(i32);
    var x1 = vm.popOperand(i32);
    //std.log.info("line {},{} > {},{}", .{x1, y1, x2, y2});

    const mem = wasm4.getMem(vm.inst.*);
    const color = wasm4.getDrawColor(mem, ._1) orelse return;
    const fb = mem[wasm4.framebuffer_addr..][0 .. wasm4.framebuffer_len];

    if (y1 > y2) {
        {
            const swap = x1;
            x1 = x2;
            x2 = swap;
        }
        {
            const swap = y1;
            y1 = y2;
            y2 = swap;
        }
    }

    var dx: i32 = std.math.absInt(x2 - x1) catch unreachable;
    var sx: i32 = if (x1 < x2) 1 else -1;
    var dy: i32 = y2 - y1;
    var err: i32 = @divTrunc(if (dx > dy) dx else -dy,  2);
    var e2: i32 = undefined;

    while (true) {
        if (x1 >= 0 and x1 < 160 and y1 >= 0 and y1 < 160) {
            setPixelXY(fb, @intCast(x1), @intCast(y1), color);
        }
        if (x1 == x2 and y1 == y2)
            break;

        e2 = err;
        if (e2 > -dx) {
            err -= dy;
            x1 += sx;
        }
        if (e2 < dy) {
            err += dx;
            y1 += 1;
        }
    }
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
        if (draw_color2) |c| break :blk c;
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
                setPixel(fb, fb_bit_offset + 2*(@as(usize, fb_rect.width) - 1), border_color);
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

fn blitCommon(
    mem: [*]u8,
    sprite: [*]const u8,
    x: i32,
    y: i32,
    width: u32,
    height: u32,
    src_x: u32,
    src_y: u32,
    sprite_stride: u32,
    flags: u32,
) void {
    const fb = mem[wasm4.framebuffer_addr..][0 .. wasm4.framebuffer_len];

    std.log.info("blit ptr={*} pos={},{} size={}x{} flags=0x{x}", .{sprite, x, y, width, height, flags});
    const fb_rect = getFbRect(x, y, width, height) orelse return;
    const sprite_offset = XY(u32){
        .x = src_x + @as(u32, @intCast(fb_rect.x - x)),
        .y = src_y + @as(u32, @intCast(fb_rect.y - y)),
    };

    const flip_x = (flags & wasm4.blit_flip_x) != 0;
    var fb_bit_offset: usize = @as(usize, fb_rect.y) * fb_bit_stride + 2 * @as(usize, fb_rect.x);

    if ((flags & BLIT_2BPP) != 0) {
        var sprite_bit_offset: usize =
            @as(usize, sprite_offset.y) * @as(usize, sprite_stride) * 2 +
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
                sprite, sprite_bit_offset,
                fb_rect.width,
                colors,
            );
            fb_bit_offset += fb_bit_stride;
            sprite_bit_offset += sprite_stride * 2; // 2 bits per pixel
        }
    } else {
        const sprite_bit_x_offset = if (flip_x) 0 else @as(usize, sprite_offset.x);
        const sprite_bit_start: usize =
            @as(usize, sprite_offset.y) * @as(usize, sprite_stride) +
            sprite_bit_x_offset;
        blit1bpp(
            fb, fb_bit_offset,
            fb_rect.width, fb_rect.height,
            sprite, sprite_bit_start, sprite_stride,
            flip_x,
            wasm4.getDrawColor(mem, ._1),
            wasm4.getDrawColor(mem, ._2),
        );
    }
}

fn bb_todo(
    userdata: ?*anyopaque,
    module: *@import("bytebox").ModuleInstance,
    params: [*]const @import("bytebox").Val,
    returns: [*]@import("bytebox").Val,
) void {
    _ = userdata;
    _ = module;
    _ = params;
    _ = returns;
    std.log.info("todo: implement this function", .{});
}

fn bb_textUtf8(
    userdata: ?*anyopaque,
    module: *@import("bytebox").ModuleInstance,
    params: [*]const @import("bytebox").Val,
    returns: [*]@import("bytebox").Val,
) void {
    _ = userdata;
    _ = module;
    _ = params;
    _ = returns;
    std.log.info("todo: textUtf8", .{});
}

fn bb_blit(
    userdata: ?*anyopaque,
    module: *@import("bytebox").ModuleInstance,
    params: [*]const @import("bytebox").Val,
    returns: [*]@import("bytebox").Val,
) void {
    _ = userdata;
    _ = module;
    _ = params;
    _ = returns;
    std.log.info("todo: blit", .{});
}

fn bb_blitSub(
    userdata: ?*anyopaque,
    module: *@import("bytebox").ModuleInstance,
    params: [*]const @import("bytebox").Val,
    returns: [*]@import("bytebox").Val,
) void {
    _ = userdata;
    _ = module;
    _ = params;
    _ = returns;
    std.log.info("todo: blitSub", .{});
}

fn blit(vm: *zware.VirtualMachine) zware.WasmError!void {
    const flags = vm.popOperand(u32);
    const height = vm.popOperand(u32);
    const width = vm.popOperand(u32);
    const y = vm.popOperand(i32);
    const x = vm.popOperand(i32);
    const sprite_addr: usize = @intCast(vm.popAnyOperand());
    const mem = wasm4.getMem(vm.inst.*);
    blitCommon(
        mem,
        mem + sprite_addr,
        x, y,
        width, height,
        0, 0, // src x/y
        width,
        flags,
    );
}

fn blitSub(vm: *zware.VirtualMachine) zware.WasmError!void {
    const flags = vm.popOperand(u32);
    const stride = vm.popOperand(u32);
    const src_y = vm.popOperand(u32);
    const src_x = vm.popOperand(u32);
    const height = vm.popOperand(u32);
    const width = vm.popOperand(u32);
    const y = vm.popOperand(i32);
    const x = vm.popOperand(i32);
    const sprite_addr: usize = @intCast(vm.popAnyOperand());
    const mem = wasm4.getMem(vm.inst.*);
    blitCommon(
        mem,
        mem + sprite_addr,
        x, y,
        width, height,
        src_x, src_y,
        stride,
        flags,
    );
}

fn blit1bpp(
    fb: *[wasm4.framebuffer_len]u8, fb_bit_start: usize,
    width: u8, height: u8,
    sprite: [*]const u8, sprite_bit_start: usize, sprite_stride: usize,
    flip_x: bool,
    color1: ?u2, color2: ?u2,
) void {
    var fb_bit_offset = fb_bit_start;
    var sprite_bit_offset = sprite_bit_start;
    for (0 .. height) |_| {
        blitRow1bpp(
            fb, fb_bit_offset,
            sprite, sprite_bit_offset,
            width, flip_x,
            color1, color2,
        );
        fb_bit_offset += fb_bit_stride;
        sprite_bit_offset += sprite_stride;
    }
}

fn blitRow1bpp(
    dst: [*]u8, dst_bit_start: usize,
    src: [*]const u8, src_bit_start: usize,
    len: usize,
    flip_x: bool,
    draw_color1: ?u2,
    draw_color2: ?u2,
) void {
    var dst_bit_offset: isize = @intCast(dst_bit_start);
    var bit_inc: i32 = 2;
    if (flip_x) {
        dst_bit_offset += 2 * (@as(isize, @intCast(len)) - 1);
        bit_inc = -2;
    }

    for (0 .. len) |i| {
        const src_val: u8 = src[ (src_bit_start + i) / 8 ];
        const shift: u3 = @intCast((src_bit_start + i) % 8);
        const src_bit = @as(u8, 0x80) >> shift;
        const color_opt: ?u2 = if ((src_val & src_bit) == 0) draw_color1 else draw_color2;
        if (color_opt) |c| {
            setPixel(dst, @as(usize, @intCast(dst_bit_offset)), c);
        }
        dst_bit_offset +%= bit_inc;
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
        0 => (val & 0b11111100) | (@as(u8, color) << 0),
        1 => (val & 0b11110011) | (@as(u8, color) << 2),
        2 => (val & 0b11001111) | (@as(u8, color) << 4),
        3 => (val & 0b00111111) | (@as(u8, color) << 6),
    };
}

fn setPixels(dst: [*]u8, bit_offset: usize, color: u2, len: u8) void {
    for (0 .. len) |i| {
        setPixel(dst, bit_offset + 2*i, color);
    }
}

fn setPixelXY(fb: *[wasm4.framebuffer_len]u8, x: u8, y: u8, color: u2) void {
    if (x >= 160) unreachable;
    if (y >= 160) unreachable;
    const bit_offset: usize = @as(usize, y) * fb_bit_stride + @as(usize, x) * 2;
    setPixel(fb, bit_offset, color);
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

// TODO: implement actually storing things on the disk
var global_disk_buf: [1024]u8 = undefined;
var global_disk_len: u32 = 0;

fn diskr(vm: *zware.VirtualMachine) zware.WasmError!void {
    const size = vm.popOperand(u32);
    const dst = vm.popOperand(u32);

    const mem = wasm4.getMem(vm.inst.*);

    const copy_len: u32 = @min(size, global_disk_len);
    @memcpy(mem[dst..][0 .. copy_len], global_disk_buf[0 .. copy_len]);
    try vm.pushOperand(u32, copy_len);
}

fn diskw(vm: *zware.VirtualMachine) zware.WasmError!void {
    const size = vm.popOperand(u32);
    const src = vm.popOperand(u32);

    const mem = wasm4.getMem(vm.inst.*);

    const copy_len: u32 = @min(size, 1024);
    @memcpy(global_disk_buf[0 .. copy_len], mem[src..][0 .. copy_len]);
    global_disk_len = copy_len;
    try vm.pushOperand(u32, copy_len);
}
