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

// IME is a master flag internal to the CPU that controls whether any interrupt handlers are called,
// regardless of the contents of IE (stored at memory addr 0xFFFF)
ime: bool = false,
// The effect of ei is delayed by one instruction, hence the need for this delay counter
// 2 == delay, 1 == set, 0 == ignore
ime_pending_enable: ImeArmState = .nothing,

interrupt_enable: u8 = 0, // IE register, bit is 1 if enabled
interrupt_flag: u8 = 0, // IF register, bit is 1 if requested

pub const ImeArmState = enum {
    delay,
    armed,
    nothing,
};

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

pub fn clear(self: *Self, src: Component) void {
    self.interrupt_flag &= util.u8ClearMask(@intFromEnum(src));
}

pub fn highestPriority(self: *const Self) ?Component {
    if (!self.ime) return null;

    const flag = self.interrupt_enable & self.interrupt_flag & 0b11111;

    if (flag & util.u8SetMask(@intFromEnum(Component.vblank)) != 0) {
        return .vblank;
    } else if (flag & util.u8SetMask(@intFromEnum(Component.lcd)) != 0) {
        return .lcd;
    } else if (flag & util.u8SetMask(@intFromEnum(Component.timer)) != 0) {
        return .timer;
    } else if (flag & util.u8SetMask(@intFromEnum(Component.serial)) != 0) {
        return .serial;
    } else if (flag & util.u8SetMask(@intFromEnum(Component.joypad)) != 0) {
        return .joypad;
    }

    return null;
}

pub fn getHandlerAddr(component: Component) u16 {
    switch (component) {
        .vblank => return 0x40,
        .lcd => return 0x48,
        .timer => return 0x50,
        .serial => return 0x58,
        .joypad => return 0x60,
    }
    unreachable;
}
