//! Global config shared across all namespaces
//! References:
//! - TCAGB Docs = https://github.com/geaz/emu-gameboy/blob/master/docs/The%20Cycle-Accurate%20Game%20Boy%20Docs.pdf

const RGBA = @import("SdlGpu.zig").RGBA;

/// The hardware screen of the Gameboy
pub const screen = struct {
    pub const width = 160;
    pub const height = 144;
};

/// Window properties
pub const window = struct {
    pub const pixel_size = 3;
    pub const width = screen.width * pixel_size;
    pub const height = screen.height * pixel_size;
    // pub const target_fps: f64 = 4_194_304 / 70_224;
    // pub const target_frame_time_ns = 1_000_000_000 * cpu.cycles_per_frame / cpu.clock_hz;
};

/// Gameboy CPU hardware
pub const cpu = struct {
    // TCAGB Docs (Page 5)
    // This value is the number of T-states.
    // To get the equivalent M-cycles, divide by 4.
    pub const clock_hz = 4_194_304;
    // TCAGB Docs (Page 27)
    pub const cycles_per_frame = 70_224;

    // Memory (bytes)
    pub const ram_size = 8192;
    pub const vram_size = 8192;
    pub const oam_size = 160;
    pub const hram_size = 127;
    pub const extram_size = 8192;
};

pub const ppu = struct {};

pub const palette: [4]RGBA = .{
    .{ .r = 224, .g = 248, .b = 208, .a = 255 },
    .{ .r = 136, .g = 192, .b = 112, .a = 255 },
    .{ .r = 52, .g = 104, .b = 86, .a = 255 },
    .{ .r = 8, .g = 24, .b = 32, .a = 255 },
};

const Flags = struct {
    gameboy_doctor_enabled: bool = false,
    mooneye_testing: bool = false,
};

pub var flags = Flags{};
