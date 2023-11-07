const zware = @import("zware");

pub fn getMem(instance: zware.Instance) [*]u8 {
    if (instance.store.memories.items.len != 1) unreachable;
    const mem = instance.store.memories.items[0].data.items;
    if (mem.len != 65536) unreachable;
    return mem.ptr;
}

pub fn clearFramebuffer(instance: zware.Instance) void {
    const mem = getMem(instance);
    const fb = mem[framebuffer_addr..][0 .. framebuffer_len];
    @memset(fb, 0);
}

pub const palette_addr = 0x4;
pub const draw_colors_addr = 0x14;

pub const framebuffer_addr = 0xa0;
pub const framebuffer_len = 6400;  // 160 * 160 * 2 (bits per pixel) / 8 (bits per byte)
pub const framebuffer_stride = 40; // 160 * 2 (bits per pixel) / 8 (bits per byte)

pub const pixels_per_byte = 4;
