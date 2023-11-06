const zware = @import("zware");

pub fn getMem(instance: zware.Instance) [*]u8 {
    if (instance.store.memories.items.len != 1) @panic("codebug");
    const mem = instance.store.memories.items[0].data.items;
    if (mem.len != 65536) @panic("codebug");
    return mem.ptr;
}

pub const draw_colors_addr = 0x14;

pub const framebuffer_addr = 0xa0;
pub const framebuffer_len = 6400;  // 160 * 160 * 2 (bits per pixel) / 8 (bits per byte)
pub const framebuffer_stride = 40; // 160 * 2 (bits per pixel) / 8 (bits per byte)

pub const pixels_per_byte = 4;
