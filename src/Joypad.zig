const Self = @This();
const std = @import("std");
const util = @import("util.zig");
const Interrupts = @import("Interrupts.zig");

select_buttons: u1 = 0,
select_dpad: u1 = 0,

up: State = .up,
down: State = .up,
left: State = .up,
right: State = .up,
a: State = .up,
b: State = .up,
start: State = .up,
select: State = .up,

pub const Button = enum {
    up,
    down,
    left,
    right,
    a,
    b,
    start,
    select,
};

pub const State = enum(u1) {
    // See https://gbdev.io/pandocs/Joypad_Input.html
    // a button being pressed is seen as the corresponding bit being 0, not 1
    down = 0,
    up = 1,
};

pub fn init() Self {
    return Self{};
}

pub fn readReg(self: *Self) u8 {
    if (self.select_buttons == 1 and self.select_dpad == 1) {
        return 0x3F;
    }
    if (self.select_buttons == 0 and self.select_dpad == 0) {
        std.debug.print("Joypad register invalid state: both bit 4 and 5 are 0.", .{});
        return 0x0F;
    }
    if (self.select_buttons == 0) {
        return @as(u8, 0b01_0000) | @as(u4, @intFromEnum(self.start)) << 3 | @as(u4, @intFromEnum(self.select)) << 2 | @as(u4, @intFromEnum(self.b)) << 1 | @intFromEnum(self.a);
    }
    if (self.select_dpad == 0) {
        return @as(u8, 0b10_0000) | @as(u4, @intFromEnum(self.down)) << 3 | @as(u4, @intFromEnum(self.up)) << 2 | @as(u4, @intFromEnum(self.left)) << 1 | @intFromEnum(self.right);
    }
    unreachable;
}

pub fn writeReg(self: *Self, val: u8) void {
    self.select_buttons = util.fromMask(u1, val, 0b10_0000);
    self.select_dpad = util.fromMask(u1, val, 0b01_0000);
}

pub fn updateButton(self: *Self, button: Button, state: State, interrupts: *Interrupts) void {
    const old = self.readReg();

    switch (button) {
        .a => self.a = state,
        .b => self.b = state,
        .down => self.down = state,
        .left => self.left = state,
        .right => self.right = state,
        .select => self.select = state,
        .start => self.start = state,
        .up => self.up = state,
    }

    const new = self.readReg();

    const falling = (old & ~new) & 0x0F;
    if (falling != 0) {
        interrupts.request(.joypad);
    }
}
