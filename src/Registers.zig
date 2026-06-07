const Self = @This();
const std = @import("std");
const Memory = @import("Memory.zig");
const util = @import("util.zig");

a: u8 = 0,
f: u8 = 0,
b: u8 = 0,
c: u8 = 0,
d: u8 = 0,
e: u8 = 0,
h: u8 = 0,
l: u8 = 0,

sp: u16 = 0,
pc: u16 = 0,

// IME is a flag internal to the CPU that controls whether any interrupt handlers are called,
// regardless of the contents of IE (stored at memory addr 0xFFFF)
ime: bool = false,
// The effect of ei is delayed by one instruction, hence the need for this bool
ime_pending_enable: bool = false,

pub inline fn af(self: *const Self) u16 {
    return (@as(u16, self.a) << 8) | self.f;
}

pub inline fn setAf(self: *Self, val: u16) void {
    self.a = @intCast(val >> 8);
    self.f = @intCast(val & 0x00F0);
}

pub inline fn bc(self: *const Self) u16 {
    return (@as(u16, self.b) << 8) | self.c;
}

pub inline fn setBc(self: *Self, val: u16) void {
    self.b = @intCast(val >> 8);
    self.c = @intCast(val & 0x00FF);
}

pub inline fn de(self: *const Self) u16 {
    return (@as(u16, self.d) << 8) | self.e;
}

pub inline fn setDe(self: *Self, val: u16) void {
    self.d = @intCast(val >> 8);
    self.e = @intCast(val & 0x00FF);
}

pub inline fn hl(self: *const Self) u16 {
    return (@as(u16, self.h) << 8) | self.l;
}

pub inline fn setHl(self: *Self, val: u16) void {
    self.h = @intCast(val >> 8);
    self.l = @intCast(val & 0x00FF);
}

pub const FlagsRegister = enum {
    z, // zero flag
    n, // substraction flag (bcd)
    h, // half carry flag (bcd)
    c, // carry flag
};

pub inline fn getFlag(self: *const Self, flag: FlagsRegister) u1 {
    switch (flag) {
        .z => return if ((self.f & 0b10000000) != 0) 1 else 0,
        .n => return if ((self.f & 0b01000000) != 0) 1 else 0,
        .h => return if ((self.f & 0b00100000) != 0) 1 else 0,
        .c => return if ((self.f & 0b00010000) != 0) 1 else 0,
    }
}

pub inline fn setFlag(self: *Self, flag: FlagsRegister, val: u1) void {
    // uses a clear-then-set approach
    switch (flag) {
        .z => self.f = (self.f & util.u8ClearMask(7)) | (@as(u8, val) << 7),
        .n => self.f = (self.f & util.u8ClearMask(6)) | (@as(u8, val) << 6),
        .h => self.f = (self.f & util.u8ClearMask(5)) | (@as(u8, val) << 5),
        .c => self.f = (self.f & util.u8ClearMask(4)) | (@as(u8, val) << 4),
    }
}

pub inline fn getR8(self: *Self, placeholder: u3, memory: *Memory) u8 {
    switch (placeholder) {
        0 => return self.b,
        1 => return self.c,
        2 => return self.d,
        3 => return self.e,
        4 => return self.h,
        5 => return self.l,
        6 => return memory.read(self.hl()),
        7 => return self.a,
    }
}

pub inline fn isR8HL(op: u3) bool {
    return op == 6;
}

pub inline fn setR8(self: *Self, placeholder: u3, val: u8, memory: *Memory) void {
    switch (placeholder) {
        0 => self.b = val,
        1 => self.c = val,
        2 => self.d = val,
        3 => self.e = val,
        4 => self.h = val,
        5 => self.l = val,
        6 => memory.write(self.hl(), val),
        7 => self.a = val,
    }
}

pub inline fn getR16(self: *Self, placeholder: u2) u16 {
    switch (placeholder) {
        0 => return self.bc(),
        1 => return self.de(),
        2 => return self.hl(),
        3 => return self.sp,
    }
}

pub inline fn setR16(self: *Self, placeholder: u2, val: u16) void {
    switch (placeholder) {
        0 => self.setBc(val),
        1 => self.setDe(val),
        2 => self.setHl(val),
        3 => self.sp = val,
    }
}

pub inline fn getR16Stk(self: *Self, placeholder: u2) u16 {
    switch (placeholder) {
        0 => return self.bc(),
        1 => return self.de(),
        2 => return self.hl(),
        3 => return self.af(),
    }
}

pub inline fn setR16Stk(self: *Self, placeholder: u2, val: u16) void {
    switch (placeholder) {
        0 => self.setBc(val),
        1 => self.setDe(val),
        2 => self.setHl(val),
        3 => self.setAf(val),
    }
}

pub inline fn getR16Mem(self: *Self, placeholder: u2) u16 {
    switch (placeholder) {
        0 => return self.bc(),
        1 => return self.de(),
        2 => {
            const addr = self.hl();
            self.setHl(addr + 1);
            return addr;
        },
        3 => {
            const addr = self.hl();
            self.setHl(addr - 1);
            return addr;
        },
    }
}

pub inline fn getCond(self: *Self, placeholder: u2) bool {
    switch (placeholder) {
        0 => return self.getFlag(.z) == 0,
        1 => return self.getFlag(.z) == 1,
        2 => return self.getFlag(.c) == 0,
        3 => return self.getFlag(.c) == 1,
    }
}
