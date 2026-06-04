//! Calculates the exact frame duration without drift.
//! The exact frame duration is cpu cycles per frame / cpu cycles per second.
//!    (CYC / FRAME) / (CYC / SEC)
//!  = (CYC / FRAME) * (SEC / CYC) [CYC cancels out]
//!  = SEC / FRAME
//! => 1_000_000_000 * (CYC / FRAME) / (CYC / SEC) [for nanoseconds per frame]
//! This gives 1_000_000_000 * 70_224 / 4_194_304 as the exact frametime in
//! nanoseconds (see config.zig for the values of CYC/FRAME and CYC/SEC).
//! Since this fraction doesn't give a whole number, keep track of the numerator
//! and produce the result each time it's asked for.
const Self = @This();
const config = @import("config.zig");

numerator: u64 = 0,

pub fn init() Self {
    return Self{};
}

pub fn getNextFrameDurationNs(self: *Self) u64 {
    self.numerator += 1_000_000_000 * config.cpu.cycles_per_frame;
    const frame_ns = self.numerator / config.cpu.clock_hz;

    // keep only the leftover fraction so we don't overflow
    self.numerator %= config.cpu.clock_hz;

    return frame_ns;
}
