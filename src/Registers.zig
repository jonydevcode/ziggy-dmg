const Self = @This();

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

pub inline fn af(self: *const Self) u16 {
    return (@as(u16, self.a) << 8) | self.f;
}

pub inline fn setAf(self: *const Self, val: u16) void {
    self.a = @intCast(val >> 8);
    self.f = @intCast(val & 0x00FF);
}

pub inline fn bc(self: *const Self) u16 {
    return (@as(u16, self.b) << 8) | self.c;
}

pub inline fn setBc(self: *const Self, val: u16) void {
    self.b = @intCast(val >> 8);
    self.c = @intCast(val & 0x00FF);
}

pub inline fn de(self: *const Self) u16 {
    return (@as(u16, self.d) << 8) | self.e;
}

pub inline fn setDe(self: *const Self, val: u16) void {
    self.d = @intCast(val >> 8);
    self.e = @intCast(val & 0x00FF);
}

pub inline fn hl(self: *const Self) u16 {
    return (@as(u16, self.h) << 8) | self.l;
}

pub inline fn setHl(self: *const Self, val: u16) void {
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
        .z => return if ((self.f & 0b1000000) != 0) 1 else 0,
        .n => return if ((self.f & 0b0100000) != 0) 1 else 0,
        .h => return if ((self.f & 0b0010000) != 0) 1 else 0,
        .c => return if ((self.f & 0b0001000) != 0) 1 else 0,
    }
}

pub inline fn setFlag(self: *const Self, flag: FlagsRegister, val: u1) void {
    // uses a clear-then-set approach
    switch (flag) {
        .z => self.f = (self.f & ~(1 << 7)) | (val << 7),
        .n => self.n = (self.n & ~(1 << 6)) | (val << 6),
        .h => self.h = (self.h & ~(1 << 5)) | (val << 5),
        .c => self.c = (self.c & ~(1 << 4)) | (val << 4),
    }
}
