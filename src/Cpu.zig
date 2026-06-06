const Self = @This();
const std = @import("std");
const config = @import("config.zig");
const Registers = @import("Registers.zig");
const Memory = @import("Memory.zig");
const readInt = std.mem.readInt;

allocator: std.mem.Allocator, // mainly for the stack
rng: std.Random,

interrupt_enable: u8 = 0,
interrupt_flags: u8 = 0,

registers: Registers,
memory: *Memory,

pub const State = enum {
    running,
    stopped,
};

pub const StepResult = struct {
    display_changed: bool,
    cycles_used: usize,
    new_state: State,

    pub fn init(display_changed: bool, cycles_used: usize) StepResult {
        return .{
            .display_changed = display_changed,
            .cycles_used = cycles_used,
            .new_state = .running,
        };
    }

    pub fn displayUnchanged(cycles_used: usize) StepResult {
        return .{
            .display_changed = false,
            .cycles_used = cycles_used,
            .new_state = .running,
        };
    }

    pub fn displayChanged(cycles_used: usize) StepResult {
        return .{
            .display_changed = true,
            .cycles_used = cycles_used,
            .new_state = .running,
        };
    }

    pub fn stopped() StepResult {
        return .{
            .display_changed = false,
            .cycles_used = 0,
            .new_state = .stopped,
        };
    }
};

pub fn init(allocator: std.mem.Allocator, rng: std.Random, memory: *Memory) Self {
    return Self{
        .allocator = allocator,
        .rng = rng,
        .memory = memory,
        .registers = .{
            .pc = 0x100,
        },
    };
}

pub fn deinit(self: *Self) void {
    _ = self;
}

pub fn step(self: *Self) !StepResult {
    const opcode = self.memory.read(self.registers.pc);
    self.registers.pc += 1;

    if (opcode == 0xCB) {
        // https://gbdev.io/pandocs/CPU_Instruction_Set.html#cb-prefix-instructions
        return try self.cbPrefix();
    }

    const block: u2 = @intCast(opcode >> 6);
    switch (block) {
        0b00 => return self.block0(opcode),
        0b01 => {},
        0b10 => {},
        0b11 => {},
    }

    return .displayUnchanged(5 * 4);
}

/// https://gbdev.io/pandocs/CPU_Instruction_Set.html#cb-prefix-instructions
pub fn cbPrefix(self: *Self) !StepResult {
    const opcode = self.memory.read(self.registers.pc);
    self.registers.pc += 1;

    _ = opcode;

    return StepResult.init(false, 0);
}

pub fn block0(self: *Self, opcode: u8) !StepResult {
    if (opcode == 0x0) {
        return self.nop();
    } else if (opcode == 0b00010000) {
        return self.stop();
    } else {
        const low4: u4 = @intCast(opcode & 0b1111);
        switch (low4) {
            0b0001 => return self.ldR16N16(opcode),
            0b0010 => return self.ldR16A(opcode),
            0b1010 => return self.ldAR16(opcode),
            0b1000 => return self.ldN16SP(),
            0b0011 => return self.incR16(opcode),
            0b1011 => return self.decR16(opcode),
            0b1001 => return self.addHLR16(opcode),
            else => {
                const low3: u3 = @intCast(opcode & 0b111);
                switch (low3) {
                    0b100 => return self.incR8(opcode),
                    0b101 => return self.decR8(opcode),
                    0b110 => return self.ldR8N8(opcode),
                    0b111 => {
                        const mid3: u3 = @intCast((opcode >> 3) & 0b111);
                        switch (mid3) {
                            0b000 => return self.rlca(),
                            0b001 => return self.rrca(),
                            0b010 => return self.rla(),
                            0b011 => return self.rra(),
                            0b100 => return self.daa(),
                            0b101 => return self.cpl(),
                            0b110 => return self.scf(),
                            0b111 => return self.ccf(),
                        }
                    },
                    0b000 => {
                        const bit5: u1 = @intCast((opcode >> 5) & 1);
                        switch (bit5) {
                            0b0 => return self.jrN16(),
                            0b1 => return self.jrCCN16(opcode),
                        }
                    },
                    else => std.debug.panic("Invalid opcode: {X}\n", .{opcode}),
                }
            },
        }
    }
    std.debug.panic("Invalid opcode: {X}\n", .{opcode});
}

// Instructions

/// No OPeration.
inline fn nop(self: *Self) StepResult {
    _ = self;
    return .displayUnchanged(1 * 4);
}

/// STOP - also consume second byte
inline fn stop(self: *Self) StepResult {
    self.registers.pc += 1;
    return StepResult.stopped();
}

/// LD r16,n16
inline fn ldR16N16(self: *Self, opcode: u8) StepResult {
    const placeholder: u2 = @intCast((opcode >> 4) & 0b11);
    const byte1 = self.memory.read(self.registers.pc);
    const byte2 = self.memory.read(self.registers.pc + 1);
    self.registers.pc += 2;
    const n16 = readInt(u16, &.{ byte1, byte2 }, .little);
    self.registers.setR16(placeholder, n16);
    return StepResult.displayUnchanged(3 * 4);
}

/// LD [r16],A
inline fn ldR16A(self: *Self, opcode: u8) StepResult {
    const placeholder: u2 = @intCast((opcode >> 4) & 0b11);
    const addr = self.registers.getR16Mem(placeholder);
    self.memory.write(addr, self.registers.a);
    return StepResult.displayUnchanged(2 * 4);
}

/// LD A,[r16]
inline fn ldAR16(self: *Self, opcode: u8) StepResult {
    const placeholder: u2 = @intCast((opcode >> 4) & 0b11);
    const addr = self.registers.getR16Mem(placeholder);
    self.registers.a = self.memory.read(addr);
    return StepResult.displayUnchanged(2 * 4);
}

/// LD [n16],SP
inline fn ldN16SP(self: *Self) StepResult {
    const byte1 = self.memory.read(self.registers.pc);
    const byte2 = self.memory.read(self.registers.pc + 1);
    self.registers.pc += 2;
    const n16 = readInt(u16, &.{ byte1, byte2 }, .little);
    self.memory.write(n16, @intCast(self.registers.sp & 0xFF));
    self.memory.write(n16 + 1, @intCast((self.registers.sp >> 8) & 0xFF));
    return StepResult.displayUnchanged(5 * 4);
}

inline fn incR16(self: *Self, opcode: u8) StepResult {
    const placeholder: u2 = @intCast((opcode >> 4) & 0b11);
    self.registers.setR16(placeholder, self.registers.getR16(placeholder) +% 1);
    return .displayUnchanged(2 * 4);
}

inline fn decR16(self: *Self, opcode: u8) StepResult {
    const placeholder: u2 = @intCast((opcode >> 4) & 0b11);
    self.registers.setR16(placeholder, self.registers.getR16(placeholder) -% 1);
    return .displayUnchanged(2 * 4);
}

inline fn addHLR16(self: *Self, opcode: u8) StepResult {
    const placeholder: u2 = @intCast((opcode >> 4) & 0b11);
    const old_val = self.registers.hl();
    const r_val = self.registers.getR16(placeholder);
    self.registers.setHl(old_val + r_val);
    self.registers.setFlag(.n, 0);
    self.registers.setFlag(.h, @intFromBool(((old_val & 0x0FFF) + (r_val & 0x0FFF)) > 0x0FFF));
    self.registers.setFlag(.c, @intFromBool(@as(u32, old_val) + @as(u32, r_val) > 0xFFFF));
    return .displayUnchanged(2 * 4);
}

inline fn incR8(self: *Self, opcode: u8) StepResult {
    const mid3: u3 = @intCast((opcode >> 3) & 0b111);
    const old_val = self.registers.getR8(mid3, self.memory);
    const new_val = old_val +% 1;
    self.registers.setR8(mid3, new_val, self.memory);
    self.registers.setFlag(.z, @intFromBool(new_val == 0));
    self.registers.setFlag(.n, 0);
    self.registers.setFlag(.h, @intFromBool((old_val & 0x0F) == 0x0F));
    return .displayUnchanged(1 * 4);
}

inline fn decR8(self: *Self, opcode: u8) StepResult {
    const mid3: u3 = @intCast((opcode >> 3) & 0b111);
    const old_val = self.registers.getR8(mid3, self.memory);
    const new_val = old_val -% 1;
    self.registers.setR8(mid3, new_val, self.memory);
    self.registers.setFlag(.z, @intFromBool(new_val == 0));
    self.registers.setFlag(.n, 1);
    self.registers.setFlag(.h, @intFromBool((old_val & 0x0F) == 0x00));
    return .displayUnchanged(1 * 4);
}

inline fn ldR8N8(self: *Self, opcode: u8) StepResult {
    const n8 = self.memory.read(self.registers.pc);
    self.registers.pc += 1;
    const mid3: u3 = @intCast((opcode >> 3) & 0b111);
    self.registers.setR8(mid3, n8, self.memory);
    return .displayUnchanged(2 * 4);
}

/// RLCA
inline fn rlca(self: *Self) StepResult {
    const msb: u1 = @intCast((self.registers.a >> 7) & 0b1);
    self.registers.a = (self.registers.a << 1) | msb;
    self.registers.setFlag(.z, 0);
    self.registers.setFlag(.n, 0);
    self.registers.setFlag(.n, 0);
    self.registers.setFlag(.c, msb);
    return .displayUnchanged(1 * 4);
}

/// RRCA
inline fn rrca(self: *Self) StepResult {
    const lsb: u1 = @intCast((self.registers.a >> 7) & 0b1);
    self.registers.a = ((self.registers.a >> 1) & ~(@as(u8, 1) << 7)) | (@as(u8, lsb) << 7);
    self.registers.setFlag(.z, 0);
    self.registers.setFlag(.n, 0);
    self.registers.setFlag(.h, 0);
    self.registers.setFlag(.c, lsb);
    return .displayUnchanged(1 * 4);
}

/// RLA
inline fn rla(self: *Self) StepResult {
    const msb: u1 = @intCast((self.registers.a >> 7) & 0b1);
    const c = self.registers.getFlag(.c);
    self.registers.a = (self.registers.a << 1) | c;
    self.registers.setFlag(.z, 0);
    self.registers.setFlag(.n, 0);
    self.registers.setFlag(.h, 0);
    self.registers.setFlag(.c, msb);
    return .displayUnchanged(1 * 4);
}

inline fn rra(self: *Self) StepResult {
    const lsb: u1 = @intCast((self.registers.a >> 7) & 0b1);
    const c = self.registers.getFlag(.c);
    self.registers.a = ((self.registers.a >> 1) & ~(@as(u8, 1) << 7)) | (@as(u8, c) << 7);
    self.registers.setFlag(.z, 0);
    self.registers.setFlag(.n, 0);
    self.registers.setFlag(.h, 0);
    self.registers.setFlag(.c, lsb);
    return .displayUnchanged(1 * 4);
}

/// DAA
inline fn daa(self: *Self) StepResult {
    if (self.registers.getFlag(.n) == 1) {
        var adjust: u8 = 0;
        if (self.registers.getFlag(.h) == 1)
            adjust += 0x6;
        if (self.registers.getFlag(.c) == 1)
            adjust += 0x60;
        self.registers.a -%= adjust;
    } else {
        var adjust: u8 = 0;
        if (self.registers.getFlag(.h) == 1 or (self.registers.a & 0xF) > 0x9)
            adjust += 0x6;
        if (self.registers.getFlag(.c) == 1 or self.registers.a > 0x99) {
            adjust += 0x60;
            self.registers.setFlag(.c, 1);
        }
        self.registers.a +%= adjust;
    }
    self.registers.setFlag(.z, @intFromBool(self.registers.a == 0));
    self.registers.setFlag(.h, 0);
    return .displayUnchanged(1 * 4);
}

/// CPL
inline fn cpl(self: *Self) StepResult {
    self.registers.a = ~self.registers.a;
    self.registers.setFlag(.n, 1);
    self.registers.setFlag(.h, 1);
    return .displayUnchanged(1 * 4);
}

/// SCF
inline fn scf(self: *Self) StepResult {
    self.registers.setFlag(.c, 1);
    self.registers.setFlag(.n, 0);
    self.registers.setFlag(.h, 0);
    return .displayUnchanged(1 * 4);
}

/// CCF
inline fn ccf(self: *Self) StepResult {
    self.registers.setFlag(.c, ~self.registers.getFlag(.c));
    self.registers.setFlag(.n, 0);
    self.registers.setFlag(.h, 0);
    return .displayUnchanged(1 * 4);
}

/// JR n16 (actually imm8)
inline fn jrN16(self: *Self) StepResult {
    const raw = self.memory.read(self.registers.pc);
    self.registers.pc += 1;
    const offset: i8 = @bitCast(raw);
    // Do this cast to leverage Zig's integer wrapping
    self.registers.pc +%= @as(u16, @bitCast(@as(i16, offset)));
    return .displayUnchanged(3 * 4);
}

/// JR cc, n16 (actually imm8)
inline fn jrCCN16(self: *Self, opcode: u8) StepResult {
    const raw = self.memory.read(self.registers.pc);
    self.registers.pc += 1;
    const offset: i8 = @bitCast(raw);
    const placeholder: u2 = @intCast((opcode >> 3) & 0b11);
    if (self.registers.getCond(placeholder)) {
        // Do this cast to leverage Zig's integer wrapping
        self.registers.pc +%= @as(u16, @bitCast(@as(i16, offset)));
        return .displayUnchanged(3 * 4);
    } else {
        return .displayUnchanged(2 * 4);
    }
}
