const build_options = @import("build_options");
pub var array: switch (build_options.wasm) {
    .zware => void,
    .bytebox => [65536]u8,
} = undefined;
