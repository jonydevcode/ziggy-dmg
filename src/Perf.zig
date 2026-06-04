const Self = @This();
const sdl = @import("sdl");

cycles: usize = 0,
poll_ns: u64 = 0,
cpu_step_ns: u64 = 0,
renderer_ns: u64 = 0,
timers_ns: u64 = 0,
audio_tick_ns: u64 = 0,
start_ns: u64 = 0,

pub fn start(self: *Self) void {
    self.start_ns = sdl.SDL_GetTicksNS();
}

pub fn lap(self: *Self) u64 {
    const old_start = self.start_ns;
    self.start_ns = sdl.SDL_GetTicksNS();
    return self.start_ns - old_start;
}
