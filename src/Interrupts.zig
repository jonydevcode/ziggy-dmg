//! Manages all Interrupts related functionality.
//! Broadly, needs these features:
//! - read/write ie and if
//! - check if there is a pending interrupt (if correct bit on ie and if are set)
//! - request an interrupt
//! - clear an interrupt request
//! - check which interrupt request is the highest priority
const Self = @This();
const std = @import("std");
const util = @import("util.zig");

interrupt_enable: u8 = 0, // ie register, bit is 1 if enabled
interrupt_flag: u8 = 0, // if register, bit is 1 if requested

pub const Component = enum(u3) {
    vblank = 0,
    lcd = 1,
    timer = 2,
    serial = 3,
    joypad = 4,
};

pub fn init() Self {
    return Self{};
}

pub fn isPending(self: *const Self) bool {
    return ((self.interrupt_enable & self.interrupt_flag & 0b11111) != 0);
}

pub fn request(self: *Self, src: Component) void {
    self.interrupt_flag |= util.u8SetMask(@intFromEnum(src));
}

pub fn clear(self: *const Self, src: Component) void {
    self.interrupt_flag &= util.u8ClearMask(@intFromEnum(src));
}

pub fn highestPriority(self: *const Self) ?Component {
    const flag = self.interrupt_enable & self.interrupt_flag & 0b11111;

    if (flag & util.u8SetMask(Component.vblank) != 0) {
        return .vblank;
    } else if (flag & util.u8SetMask(Component.lcd) != 0) {
        return .lcd;
    } else if (flag & util.u8SetMask(Component.timer) != 0) {
        return .timer;
    } else if (flag & util.u8SetMask(Component.serial) != 0) {
        return .serial;
    } else if (flag & util.u8SetMask(Component.joypad) != 0) {
        return .joypad;
    }

    return null;
}
