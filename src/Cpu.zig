const Self = @This();
const std = @import("std");
const config = @import("config.zig");

allocator: std.mem.Allocator, // mainly for the stack
rng: std.Random,

rom: []const u8,
ram: [config.cpu.ram_size]u8 = @splat(0),
vram: [config.cpu.vram_size]u8 = @splat(0),
oam: [config.cpu.oam_size]u8 = @splat(0),
hram: [config.cpu.hram_size]u8 = @splat(0),

interrupt_enable: u8 = 0,
interrupt_flags: u8 = 0,

pub fn init(allocator: std.mem.Allocator, rng: std.Random, rom: []const u8) Self {
    return Self{
        .allocator = allocator,
        .rng = rng,
        .rom = rom,
    };
}

pub fn deinit(self: *Self) void {
    _ = self;
}

pub const StepResult = struct {
    display_changed: bool,
    cycles_used: usize,
};

pub fn step(self: *Self) !StepResult {
    _ = self;
    return StepResult{
        .display_changed = false,
        .cycles_used = 1,
    };
}
