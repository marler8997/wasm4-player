const zware = @import("zware");
const build_options = @import("build_options");
const WasmInstance = switch (build_options.wasm) {
    .zware => zware.Instance,
    .bytebox => @import("bytebox").ModuleInstance,
};
const bbmem = @import("bbmem.zig");

pub fn getMem(instance: WasmInstance) [*]u8 {
    switch (build_options.wasm) {
        .zware => {
            if (instance.store.memories.items.len != 1) unreachable;
            const mem = instance.store.memories.items[0].data.items;
            if (mem.len != 65536) unreachable;
            return mem.ptr;
        },
        .bytebox => {
            const mem = instance.memoryAll();
            @import("std").debug.assert(mem.len == 65536);
            @import("std").debug.assert(mem.ptr == &bbmem.array);
            //return mem.ptr;
            return &bbmem.array;
        },
    }
}

pub fn clearFramebuffer(instance: WasmInstance) void {
    const mem = getMem(instance);
    const fb = mem[framebuffer_addr..][0 .. framebuffer_len];
    @memset(fb, 0);
}

pub const DrawColor = enum(u2) { _1, _2, _3, _4 };
pub fn getDrawColor(mem: [*]const u8, color: DrawColor) ?u2 {
    const draw_colors: *const align(1) u16 = @ptrCast(mem + draw_colors_addr);
    const shift: u4 = @as(u4, @intFromEnum(color)) * 4;
    const c = (0xf & (draw_colors.* >> shift)) % 5;
    if (c == 0) return null;
    return @intCast(c - 1);
}

pub const palette_addr = 0x4;
pub const draw_colors_addr = 0x14;
pub const gamepad1_addr = 0x16;

pub const framebuffer_addr = 0xa0;
pub const framebuffer_len = 6400;  // 160 * 160 * 2 (bits per pixel) / 8 (bits per byte)
pub const framebuffer_stride = 40; // 160 * 2 (bits per pixel) / 8 (bits per byte)

pub const pixels_per_byte = 4;

pub const blit_flip_x = 0b0010;

pub const button_1:     u8 = 0b00000001;
pub const button_2:     u8 = 0b00000010;
pub const button_left:  u8 = 0b00010000;
pub const button_right: u8 = 0b00100000;
pub const button_up:    u8 = 0b01000000;
pub const button_down:  u8 = 0b10000000;
