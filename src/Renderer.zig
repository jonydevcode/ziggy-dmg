const Self = @This();
const std = @import("std");
const sdl = @import("sdl");
const sdlx = @import("sdlx.zig");
const SdlGpu = @import("SdlGpu.zig");
const RGBA = SdlGpu.RGBA;

pub const black = RGBA{ .r = 0, .g = 0, .b = 0, .a = 0 };
pub const white = RGBA{ .r = 255, .g = 255, .b = 255, .a = 255 };

window: *sdl.SDL_Window,
pixel_size: usize,
frame_width: usize,
frame_height: usize,
frame_buf: []RGBA,
sdlgpu: SdlGpu,

/// Caller owns frame_buf
pub fn init(
    comptime window_width: usize,
    comptime window_height: usize,
    comptime pixel_size: usize,
    comptime frame_width: usize,
    comptime frame_height: usize,
    frame_buf: *[frame_width * frame_height]RGBA,
) !Self {
    try sdlx.check("SDL_SetAppMetadata", sdl.SDL_SetAppMetadata(
        "zigb-emu: Gameboy Emulator",
        "0.1.0",
        "jonydevcode.zigb-emu",
    ));

    try sdlx.check("SDL_Init", sdl.SDL_Init(sdl.SDL_INIT_VIDEO | sdl.SDL_INIT_AUDIO));

    std.debug.print(
        "video driver: {s}\n",
        .{sdl.SDL_GetCurrentVideoDriver() orelse @as([*c]const u8, "null")},
    );

    // Create a window
    const window = sdl.SDL_CreateWindow(
        "zigb-emu: Gameboy Emulator (@jonydevcode)",
        window_width,
        window_height,
        sdl.SDL_WINDOW_RESIZABLE | sdl.SDL_WINDOW_HIGH_PIXEL_DENSITY,
    ) orelse return error.SdlError;

    const sdlgpu = try SdlGpu.init(window, frame_width, frame_height, frame_buf[0..]);

    return Self{
        .window = window,
        .pixel_size = pixel_size,
        .frame_width = frame_width,
        .frame_height = frame_height,
        .sdlgpu = sdlgpu,
        .frame_buf = frame_buf,
    };
}

pub fn deinit(self: *Self) void {
    self.sdlgpu.deinit();
    sdl.SDL_DestroyWindow(self.window);
    sdl.SDL_Quit();
}

fn toDevice(self: *Self, v: usize) usize {
    return v * self.pixel_size;
}

fn buildRGBAFrame(screen: []const u2, palette: *const [4]RGBA, dest_frame: []RGBA) void {
    for (screen, 0..) |p, i| {
        const color = palette[p];
        dest_frame[i] = color;
    }
}

pub fn paint(self: *Self, source_display: []const u2, palette: *const [4]RGBA) !void {
    buildRGBAFrame(source_display, palette, self.frame_buf);
    self.sdlgpu.markFramebufferDirty();
    try self.sdlgpu.present();
}
