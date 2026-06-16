const Self = @This();
const std = @import("std");
const config = @import("config.zig");
const Registers = @import("Registers.zig");
const Memory = @import("Memory.zig");
const Interrupts = @import("Interrupts.zig");
const Timers = @import("Timers.zig");
const util = @import("util.zig");
const readInt = std.mem.readInt;

allocator: std.mem.Allocator, // mainly for the stack
rng: std.Random,

registers: Registers,
memory: *Memory,
interrupts: *Interrupts,
timers: *Timers,
state: State,

pub const State = enum {
    running,
    stopped,
    halted, // HALT instruction
    interrupted,
    terminated,
};

pub const StepResult = struct {
    display_changed: bool = false,
    // gbz80 reference - Cycles: 5 means 5 Game Boy machine cycles or M-cycles,
    // not 5 raw 4.194304 MHz clock ticks or T-cycles
    t_cycles_used: usize,
    new_state: State,

    pub fn init(display_changed: bool, m_cycles_used: usize) StepResult {
        return .{
            .display_changed = display_changed,
            .t_cycles_used = m_cycles_used * 4,
            .new_state = .running,
        };
    }

    pub fn ok(m_cycles_used: usize) StepResult {
        return .{
            .t_cycles_used = m_cycles_used * 4,
            .new_state = .running,
        };
    }

    pub fn interrupted(m_cycles_used: usize) StepResult {
        return .{ .t_cycles_used = m_cycles_used * 4, .new_state = .interrupted };
    }

    pub fn stopped() StepResult {
        return .{ .t_cycles_used = 0, .new_state = .stopped };
    }

    pub fn halted() StepResult {
        return .{ .t_cycles_used = 4, .new_state = .halted };
    }

    pub fn terminated() StepResult {
        return .{ .t_cycles_used = 4, .new_state = .terminated };
    }
};

/// For Gameboy Doctor testing
pub fn writeState(self: *Self, writer: *std.Io.Writer) !void {
    try writer.print("A:{X:0>2} F:{X:0>2} B:{X:0>2} C:{X:0>2} D:{X:0>2} E:{X:0>2} H:{X:0>2} L:{X:0>2} SP:{X:0>4} PC:{X:0>4} PCMEM:{X:0>2},{X:0>2},{X:0>2},{X:0>2}\n", .{
        self.registers.a,
        self.registers.f,
        self.registers.b,
        self.registers.c,
        self.registers.d,
        self.registers.e,
        self.registers.h,
        self.registers.l,
        self.registers.sp,
        self.registers.pc,
        self.memory.peek(self.registers.pc),
        self.memory.peek(self.registers.pc + 1),
        self.memory.peek(self.registers.pc + 2),
        self.memory.peek(self.registers.pc + 3),
    });
    try writer.flush();
}

pub fn init(allocator: std.mem.Allocator, rng: std.Random, memory: *Memory, interrupts: *Interrupts, timers: *Timers) Self {
    return Self{
        .allocator = allocator,
        .rng = rng,
        .memory = memory,
        .interrupts = interrupts,
        .timers = timers,
        .registers = .{
            .pc = 0x100,
        },
        .state = .running,
    };
}

pub fn deinit(self: *Self) void {
    _ = self;
}

inline fn consumePC(self: *Self) u8 {
    const val = self.memory.read(self.registers.pc);
    self.registers.pc += 1;
    // self.timers.tickOneMCycle();
    return val;
}

/// Pushes a u16 onto the stack. Consumes 2 M-cycles from the 2x memory writes.
///
/// A separate stack helper is needed because CALL and PUSH both push things
/// onto the stack:
///     DEC SP
///     LD [SP], HIGH(r16)  ; B, D or H
///     DEC SP
///     LD [SP], LOW(r16)   ; C, E or L
inline fn stackPush(self: *Self, val: u16) void {
    const hi_byte = util.fromMask(u8, val, 0xFF00);
    const lo_byte = util.fromMask(u8, val, 0x00FF);
    self.registers.sp -%= 1;
    self.memory.write(self.registers.sp, hi_byte);
    self.registers.sp -%= 1;
    self.memory.write(self.registers.sp, lo_byte);
}

/// Pops a u16 from the stack.
///
/// A separate stack helper is needed because RET and POP both pop things
/// from the stack:
///     LD LOW(r16), [SP]   ; C, E or L
///     INC SP
///     LD HIGH(r16), [SP]  ; B, D or H
///     INC SP
inline fn stackPop(self: *Self) u16 {
    const lo_byte = self.memory.read(self.registers.sp);
    self.registers.sp +%= 1;
    const hi_byte = self.memory.read(self.registers.sp);
    self.registers.sp +%= 1;
    return util.concatU16(lo_byte, hi_byte);
}

// Step

pub fn step(self: *Self) StepResult {
    switch (self.interrupts.ime_pending_enable) {
        .delay => self.interrupts.ime_pending_enable = .armed,
        .armed => {
            self.interrupts.ime = true;
            self.interrupts.ime_pending_enable = .nothing;
        },
        .nothing => {},
    }

    if (self.state == .halted) {
        // Check if there's a PENDING interrupt and if yes, even if IME is false, continue processing
        if ((self.interrupts.interrupt_enable & self.interrupts.interrupt_flag & 0b11111) != 0) {
            self.state = .running;
            return .ok(0);
        } else {
            self.timers.tickOneMCycle();
            return .halted();
        }
    }

    // This design avoids incrementing PC then decrementing if there's a pending interrupt.
    // See https://gist.github.com/SonoSooS/c0055300670d678b5ae8433e20bea595#isr-and-nmi
    self.timers.tickOneMCycle();
    if (self.interrupts.highestPriority()) |component| {
        self.interrupts.clear(component);
        self.interrupts.ime = false;
        self.timers.tickOneMCycle();
        self.stackPush(self.registers.pc);
        self.registers.pc = Interrupts.getHandlerAddr(component);
        self.timers.tickOneMCycle();
        return .interrupted(5);
    }

    // If there was no pending interrupt, then 1 M-cycle is paid. Hence,
    // this opcode fetch should not consume another M-cycle.
    const opcode = self.memory.peek(self.registers.pc);
    self.registers.pc += 1;

    if (config.flags.mooneye_testing and opcode == 0x40) {
        // std.debug.print("ld B, B executed\n", .{});
        const b = self.registers.b == 3;
        const c = self.registers.c == 5;
        const d = self.registers.d == 8;
        const e = self.registers.e == 13;
        const h = self.registers.h == 21;
        const l = self.registers.l == 34;
        if (b and c and d and e and h and l) {
            std.debug.print("mooneye test PASS\n", .{});
        } else {
            std.debug.print("mooneye test FAIL\n", .{});
        }
        return .terminated();
    }

    const block = util.fromMask(u2, opcode, 0b1100_0000);
    switch (block) {
        0b00 => return self.block0(opcode),
        0b01 => return self.block1(opcode),
        0b10 => return self.block2(opcode),
        0b11 => return self.block3(opcode),
    }

    unreachable;
}

pub fn block0(self: *Self, opcode: u8) StepResult {
    switch (opcode) {
        0b0000_0000 => return self.nop(),
        0b0000_1000 => return self.ldN16SP(),
        0b0000_0111 => return self.rlca(),
        0b0000_1111 => return self.rrca(),
        0b0001_0111 => return self.rla(),
        0b0001_1111 => return self.rra(),
        0b0010_0111 => return self.daa(),
        0b0010_1111 => return self.cpl(),
        0b0011_0111 => return self.scf(),
        0b0011_1111 => return self.ccf(),
        0b0001_1000 => return self.jrN16(),
        0b0001_0000 => return self.stop(),
        else => {
            const low4 = util.fromMask(u4, opcode, 0b1111);
            switch (low4) {
                0b0001 => return self.ldR16N16(opcode),
                0b0010 => return self.ldR16A(opcode),
                0b1010 => return self.ldAR16(opcode),
                0b0011 => return self.incR16(opcode),
                0b1011 => return self.decR16(opcode),
                0b1001 => return self.addHLR16(opcode),
                else => {
                    const low3 = util.fromMask(u3, opcode, 0b111);
                    switch (low3) {
                        0b100 => return self.incR8(opcode),
                        0b101 => return self.decR8(opcode),
                        0b110 => return self.ldR8N8(opcode),
                        else => {
                            const bit5 = util.fromMask(u1, opcode, 0b100000);
                            if (bit5 == 1 and low3 == 0b000) {
                                return self.jrCCN16(opcode);
                            }
                        },
                    }
                },
            }
        },
    }

    std.debug.panic("Invalid opcode: {X}\n", .{opcode});
}

pub fn block1(self: *Self, opcode: u8) StepResult {
    if (opcode == 0b01110110) {
        return self.halt();
    }
    if (util.fromMask(u2, opcode, 0b11000000) == 0b01) {
        return self.ldR8R8(opcode);
    }
    std.debug.panic("Invalid opcode: {X}\n", .{opcode});
}

pub fn block2(self: *Self, opcode: u8) StepResult {
    const bits_hi5 = util.fromMask(u5, opcode, 0b11111000);
    switch (bits_hi5) {
        0b10000 => return self.addAR8(opcode),
        0b10001 => return self.adcAR8(opcode),
        0b10010 => return self.subAR8(opcode),
        0b10011 => return self.sbcAR8(opcode),
        0b10100 => return self.andAR8(opcode),
        0b10101 => return self.xorAR8(opcode),
        0b10110 => return self.orAR8(opcode),
        0b10111 => return self.cpAR8(opcode),
        else => {},
    }
    std.debug.panic("Invalid opcode: {X}\n", .{opcode});
}

pub fn block3(self: *Self, opcode: u8) StepResult {
    switch (opcode) {
        // table 1
        0b1100_0110 => return self.addAN8(),
        0b1100_1110 => return self.adcAN8(),
        0b1101_0110 => return self.subAN8(),
        0b1101_1110 => return self.sbcAN8(),
        0b1110_0110 => return self.andAN8(),
        0b1110_1110 => return self.xorAN8(),
        0b1111_0110 => return self.orAN8(),
        0b1111_1110 => return self.cpAN8(),
        // table 4
        0xCB => {
            // https://gbdev.io/pandocs/CPU_Instruction_Set.html#cb-prefix-instructions
            const byte = self.consumePC();
            const bit67 = util.fromMask(u2, byte, 0b1100_0000);
            switch (bit67) {
                0b00 => {
                    const bit345 = util.fromMask(u3, byte, 0b111000);
                    switch (bit345) {
                        0b000 => return self.rlcR8(byte),
                        0b001 => return self.rrcR8(byte),
                        0b010 => return self.rlR8(byte),
                        0b011 => return self.rrR8(byte),
                        0b100 => return self.slaR8(byte),
                        0b101 => return self.sraR8(byte),
                        0b110 => return self.swapR8(byte),
                        0b111 => return self.srlR8(byte),
                    }
                },
                0b01 => return self.bitU3R8(byte),
                0b10 => return self.resU3R8(byte),
                0b11 => return self.setU3R8(byte),
            }
        },
        // table 5
        0b1110_0010 => return self.ldhCA(),
        0b1110_0000 => return self.ldhN16A(),
        0b1110_1010 => return self.ldN16A(),
        0b1111_0010 => return self.ldhAC(),
        0b1111_0000 => return self.ldhAN16(),
        0b1111_1010 => return self.ldAN16(),
        // table 6
        0b1110_1000 => return self.addSPE8(),
        0b1111_1000 => return self.ldHLSPE8(),
        0b1111_1001 => return self.ldSPHL(),
        // table 7
        0b1111_0011 => return self.di(),
        0b1111_1011 => return self.ei(),
        else => {
            const bit67 = util.fromMask(u2, opcode, 0b1100_0000);
            const bit0123 = util.fromMask(u4, opcode, 0b0000_1111);
            // table 3
            if (bit67 == 0b11) {
                if (bit0123 == 0b0001) return self.popR16(opcode);
                if (bit0123 == 0b0101) return self.pushR16(opcode);
            }
            // table 2
            switch (opcode) {
                0b1100_1001 => return self.ret(),
                0b1101_1001 => return self.reti(),
                0b1100_0011 => return self.jpN16(),
                0b1110_1001 => return self.jpHL(),
                0b1100_1101 => return self.callN16(),
                else => {
                    const bit012 = util.fromMask(u3, opcode, 0b111);
                    switch (bit012) {
                        0b000 => return self.retCC(opcode),
                        0b010 => return self.jpCCN16(opcode),
                        0b100 => return self.callCCN16(opcode),
                        0b111 => return self.rstVec(opcode),
                        else => {},
                    }
                },
            }
        },
    }
    std.debug.panic("Invalid opcode: {X}\n", .{opcode});
}

// Instructions - Reference to https://rgbds.gbdev.io/docs/v1.0.1/gbz80.7

// Load instructions ///////////////////////////////////////////////////////////

/// LD r8,r8 | ld r8, r8
///
/// Copy (aka Load) the value in register on the right into the register on the left.
inline fn ldR8R8(self: *Self, opcode: u8) StepResult {
    const src = util.fromMask(u3, opcode, 0b111);
    const dest = util.fromMask(u3, opcode, 0b111000);
    self.registers.setR8(dest, self.registers.getR8(src, self.memory), self.memory);
    return if (Registers.isR8HL(dest)) .ok(2) else .ok(1);
}

/// LD r8,n8 | ld r8, imm8
///
/// Copy the value n8 into register r8.
inline fn ldR8N8(self: *Self, opcode: u8) StepResult {
    const n8 = self.consumePC();
    const op_r8 = util.fromMask(u3, opcode, 0b111000);
    self.registers.setR8(op_r8, n8, self.memory);
    return if (Registers.isR8HL(op_r8)) .ok(3) else .ok(2);
}

/// LD r16,n16 | ld r16, imm16
///
/// Copy the value n16 into register r16.
inline fn ldR16N16(self: *Self, opcode: u8) StepResult {
    const op_r16 = util.fromMask(u2, opcode, 0b110000);
    const byte1 = self.consumePC();
    const byte2 = self.consumePC();
    const n16 = util.concatU16(byte1, byte2);
    self.registers.setR16(op_r16, n16);
    return .ok(3);
}

/// LD [r16],A | ld [r16mem], a
///
/// Copy the value in register A into the byte pointed to by r16.
inline fn ldR16A(self: *Self, opcode: u8) StepResult {
    const op_r16 = util.fromMask(u2, opcode, 0b110000);
    const addr = self.registers.getR16Mem(op_r16);
    self.memory.write(addr, self.registers.a);
    return .ok(2);
}

/// LD [n16],A | ld [imm16], a
///
/// Copy the value in register A into the byte at address n16.
inline fn ldN16A(self: *Self) StepResult {
    const byte1 = self.consumePC();
    const byte2 = self.consumePC();
    const addr = util.concatU16(byte1, byte2);
    self.memory.write(addr, self.registers.a);
    return .ok(4);
}

/// LDH [n16],A | ldh [imm8], a
///
/// Copy the value in register A into the byte at address n16.
/// The destination address n16 is encoded as its 8-bit low byte and assumes a high
/// byte of $FF, so it must be between $FF00 and $FFFF.
inline fn ldhN16A(self: *Self) StepResult {
    const low_byte = self.consumePC();
    const addr: u16 = 0xFF00 + @as(u16, low_byte);
    self.memory.write(addr, self.registers.a);
    return .ok(3);
}

/// LDH [C],A | ldh [c], a
///
/// Copy the value in register A into the byte at address $FF00+C.
inline fn ldhCA(self: *Self) StepResult {
    const addr: u16 = 0xFF00 + @as(u16, self.registers.c);
    self.memory.write(addr, self.registers.a);
    return .ok(2);
}

/// LD A,[r16] | ld a, [r16mem]
///
/// Copy the byte pointed to by r16 into register A.
inline fn ldAR16(self: *Self, opcode: u8) StepResult {
    const op_r16 = util.fromMask(u2, opcode, 0b110000);
    const addr = self.registers.getR16Mem(op_r16);
    self.registers.a = self.memory.read(addr);
    return .ok(2);
}

/// LD A,[n16]
///
/// Copy the byte at address n16 into register A.
inline fn ldAN16(self: *Self) StepResult {
    const byte1 = self.consumePC();
    const byte2 = self.consumePC();
    const addr = util.concatU16(byte1, byte2);
    self.registers.a = self.memory.read(addr);
    return .ok(4);
}

/// LDH A,[n16] | ldh a, [imm8]
///
/// Copy the byte at address n16 into register A.
///
/// The source address n16 is encoded as its 8-bit low byte and assumes a
/// high byte of $FF, so it must be between $FF00 and $FFFF.
inline fn ldhAN16(self: *Self) StepResult {
    const byte = self.consumePC();
    const addr: u16 = 0xFF00 + @as(u16, byte);
    self.registers.a = self.memory.read(addr);
    return .ok(3);
}

/// LDH A,[C] | ldh a, [c]
///
/// Copy the byte at address $FF00+C into register A.
inline fn ldhAC(self: *Self) StepResult {
    const addr: u16 = 0xFF00 + @as(u16, self.registers.c);
    self.registers.a = self.memory.read(addr);
    return .ok(2);
}

// 8 bit arithmetic instructions ///////////////////////////////////////////////

/// ADC A,r8 | adc a, r8
///
/// Add the value in r8 plus the carry flag to A.
inline fn adcAR8(self: *Self, opcode: u8) StepResult {
    const op_r8 = util.fromMask(u3, opcode, 0b111);
    const val = self.registers.getR8(op_r8, self.memory);
    const old_val = self.registers.a;
    self.registers.a +%= val +% self.registers.getFlag(.c);
    self.registers.setFlag(.z, @intFromBool(self.registers.a == 0));
    self.registers.setFlag(.n, 0);
    // H: Set if overflow from bit 3
    self.registers.setFlag(.h, @intFromBool((old_val & 0x0F) + (val & 0x0F) + self.registers.getFlag(.c) > 0x0F));
    // C: Set if overflow from bit 7
    self.registers.setFlag(.c, @intFromBool(@as(u16, old_val) + @as(u16, val) + @as(u16, self.registers.getFlag(.c)) > 0xFF));
    return if (Registers.isR8HL(op_r8)) .ok(2) else .ok(1);
}

/// ADC A,n8 | adc a, imm8
///
/// Add the value n8 plus the carry flag to A.
inline fn adcAN8(self: *Self) StepResult {
    const val = self.consumePC();
    const old_val = self.registers.a;
    self.registers.a +%= val +% self.registers.getFlag(.c);
    // Z: Set if result is 0
    self.registers.setFlag(.z, @intFromBool(self.registers.a == 0));
    // N: 0
    self.registers.setFlag(.n, 0);
    // H: Set if overflow from bit 3
    self.registers.setFlag(.h, @intFromBool((old_val & 0x0F) + (val & 0x0F) + self.registers.getFlag(.c) > 0x0F));
    // C: Set if overflow from bit 7
    self.registers.setFlag(.c, @intFromBool(@as(u16, old_val) + @as(u16, val) + @as(u16, self.registers.getFlag(.c)) > 0xFF));
    return .ok(2);
}

/// ADD A,r8 | add a, r8
///
/// Add the value in r8 to A.
inline fn addAR8(self: *Self, opcode: u8) StepResult {
    const op_r8 = util.fromMask(u3, opcode, 0b111);
    const val = self.registers.getR8(op_r8, self.memory);
    const old_val = self.registers.a;
    self.registers.a +%= val;
    // Z: Set if result is 0
    self.registers.setFlag(.z, @intFromBool(self.registers.a == 0));
    // N: 0
    self.registers.setFlag(.n, 0);
    // H: Set if overflow from bit 3
    self.registers.setFlag(.h, @intFromBool((old_val & 0x0F) + (val & 0x0F) > 0x0F));
    // C: Set if overflow from bit 7
    self.registers.setFlag(.c, @intFromBool(@as(u16, old_val) + @as(u16, val) > 0xFF));
    return if (Registers.isR8HL(op_r8)) .ok(2) else .ok(1);
}

/// ADD A,n8
///
/// Add the value n8 to A.
inline fn addAN8(self: *Self) StepResult {
    const val = self.consumePC();
    const old_val = self.registers.a;
    self.registers.a +%= val;
    self.registers.setFlag(.z, @intFromBool(self.registers.a == 0));
    self.registers.setFlag(.n, 0);
    // H: Set if overflow from bit 3
    self.registers.setFlag(.h, @intFromBool((old_val & 0x0F) + (val & 0x0F) > 0x0F));
    // C: Set if overflow from bit 7
    self.registers.setFlag(.c, @intFromBool(@as(u16, old_val) + @as(u16, val) > 0xFF));
    return .ok(2);
}

/// CP A,r8
///
/// ComPare the value in A with the value in r8.
///
/// This subtracts the value in r8 from A and sets flags accordingly, but discards the result.
inline fn cpAR8(self: *Self, opcode: u8) StepResult {
    const op_r8 = util.fromMask(u3, opcode, 0b111);
    const val_r8 = self.registers.getR8(op_r8, self.memory);
    const result = self.registers.a -% val_r8;
    self.registers.setFlag(.z, @intFromBool(result == 0));
    self.registers.setFlag(.n, 1);
    // H: Set if borrow from bit 4
    self.registers.setFlag(.h, @intFromBool((self.registers.a & 0x0F) < (val_r8 & 0x0F)));
    // C: Set if borrow at all
    self.registers.setFlag(.c, @intFromBool(val_r8 > self.registers.a));
    return if (Registers.isR8HL(op_r8)) .ok(2) else .ok(1);
}

/// CP A,n8 | cp a, imm8
///
/// ComPare the value in A with the value n8.
///
/// This subtracts the value n8 from A and sets flags accordingly, but discards the result.
inline fn cpAN8(self: *Self) StepResult {
    const val_r8 = self.consumePC();
    const result = self.registers.a -% val_r8;
    self.registers.setFlag(.z, @intFromBool(result == 0));
    self.registers.setFlag(.n, 1);
    // H: Set if borrow from bit 4
    self.registers.setFlag(.h, @intFromBool((self.registers.a & 0x0F) < (val_r8 & 0x0F)));
    // C: Set if borrow at all
    self.registers.setFlag(.c, @intFromBool(val_r8 > self.registers.a));
    return .ok(2);
}

/// DEC r8 | DEC [HL]
///
/// Decrement the value in register r8 by 1.
inline fn decR8(self: *Self, opcode: u8) StepResult {
    const mid3 = util.fromMask(u3, opcode, 0b111000);
    const old_val = self.registers.getR8(mid3, self.memory);
    const new_val = old_val -% 1;
    self.registers.setR8(mid3, new_val, self.memory);
    self.registers.setFlag(.z, @intFromBool(new_val == 0));
    self.registers.setFlag(.n, 1);
    // H: Set if borrow from bit 4
    self.registers.setFlag(.h, @intFromBool((old_val & 0x0F) == 0x00));
    return if (Registers.isR8HL(mid3)) .ok(3) else .ok(1);
}

/// INC r8
///
/// Increment the value in register r8 by 1.
inline fn incR8(self: *Self, opcode: u8) StepResult {
    const mid3 = util.fromMask(u3, opcode, 0b111000);
    const old_val = self.registers.getR8(mid3, self.memory);
    const new_val = old_val +% 1;
    self.registers.setR8(mid3, new_val, self.memory);
    self.registers.setFlag(.z, @intFromBool(new_val == 0));
    self.registers.setFlag(.n, 0);
    // H: Set if overflow from bit 3
    self.registers.setFlag(.h, @intFromBool((old_val & 0x0F) == 0x0F));
    return if (Registers.isR8HL(mid3)) .ok(3) else .ok(1);
}

inline fn sbcAR8(self: *Self, opcode: u8) StepResult {
    const op_r8 = util.fromMask(u3, opcode, 0b111);
    const val = self.registers.getR8(op_r8, self.memory);
    const old_val = self.registers.a;
    self.registers.a -%= val +% self.registers.getFlag(.c);
    self.registers.setFlag(.z, @intFromBool(self.registers.a == 0));
    self.registers.setFlag(.n, 1);
    // H: Set if borrow from bit 4
    self.registers.setFlag(.h, @intFromBool((old_val & 0x0F) < (val & 0x0F) + self.registers.getFlag(.c)));
    // C: Set if borrow (i.e. if (r8 + carry) > A).
    self.registers.setFlag(.c, @intFromBool((@as(u16, val) + self.registers.getFlag(.c)) > old_val));
    return if (Registers.isR8HL(op_r8)) .ok(2) else .ok(1);
}

inline fn sbcAN8(self: *Self) StepResult {
    const val = self.consumePC();
    const old_val = self.registers.a;
    self.registers.a -%= val +% self.registers.getFlag(.c);
    self.registers.setFlag(.z, @intFromBool(self.registers.a == 0));
    self.registers.setFlag(.n, 1);
    // H: Set if borrow from bit 4
    self.registers.setFlag(.h, @intFromBool((old_val & 0x0F) < (val & 0x0F) + self.registers.getFlag(.c)));
    // C: Set if borrow (i.e. if (r8 + carry) > A).
    self.registers.setFlag(.c, @intFromBool((@as(u16, val) + self.registers.getFlag(.c)) > old_val));
    return .ok(2);
}

inline fn subAR8(self: *Self, opcode: u8) StepResult {
    const op_r8 = util.fromMask(u3, opcode, 0b111);
    const val = self.registers.getR8(op_r8, self.memory);
    const old_val = self.registers.a;
    self.registers.a -%= val;
    self.registers.setFlag(.z, @intFromBool(self.registers.a == 0));
    self.registers.setFlag(.n, 1);
    // H: Set if borrow from bit 4
    self.registers.setFlag(.h, @intFromBool((old_val & 0x0F) < (val & 0x0F)));
    // C: Set if borrow (i.e. if (r8 + carry) > A).
    self.registers.setFlag(.c, @intFromBool(val > old_val));
    return if (Registers.isR8HL(op_r8)) .ok(2) else .ok(1);
}

inline fn subAN8(self: *Self) StepResult {
    const val = self.consumePC();
    const old_val = self.registers.a;
    self.registers.a -%= val;
    self.registers.setFlag(.z, @intFromBool(self.registers.a == 0));
    self.registers.setFlag(.n, 1);
    // H: Set if borrow from bit 4
    self.registers.setFlag(.h, @intFromBool((old_val & 0x0F) < (val & 0x0F)));
    // C: Set if borrow (i.e. if r8 > A).
    self.registers.setFlag(.c, @intFromBool(val > old_val));
    return .ok(2);
}

// 16 bit arithmetic instructions //////////////////////////////////////////////

/// ADD HL,r16 - Add the value in r16 to HL.
inline fn addHLR16(self: *Self, opcode: u8) StepResult {
    const placeholder: u2 = @intCast((opcode >> 4) & 0b11);
    const old_val = self.registers.hl();
    const r_val = self.registers.getR16(placeholder);
    self.registers.setHl(old_val +% r_val);
    self.registers.setFlag(.n, 0);
    self.registers.setFlag(.h, @intFromBool(((old_val & 0x0FFF) + (r_val & 0x0FFF)) > 0x0FFF));
    self.registers.setFlag(.c, @intFromBool(@as(u32, old_val) + @as(u32, r_val) > 0xFFFF));
    self.timers.tickOneMCycle();
    return .ok(2);
}

inline fn decR16(self: *Self, opcode: u8) StepResult {
    const placeholder: u2 = @intCast((opcode >> 4) & 0b11);
    self.registers.setR16(placeholder, self.registers.getR16(placeholder) -% 1);
    self.timers.tickOneMCycle();
    return .ok(2);
}

inline fn incR16(self: *Self, opcode: u8) StepResult {
    const placeholder: u2 = @intCast((opcode >> 4) & 0b11);
    self.registers.setR16(placeholder, self.registers.getR16(placeholder) +% 1);
    self.timers.tickOneMCycle();
    return .ok(2);
}

// Bitwise logic instructions //////////////////////////////////////////////////

/// AND A,r8 | and a, r8 | AND A,[HL]
///
/// Set A to the bitwise AND between the value in r8 and A.
inline fn andAR8(self: *Self, opcode: u8) StepResult {
    const op_r8 = util.fromMask(u3, opcode, 0b111);
    const val = self.registers.getR8(op_r8, self.memory);
    const result = self.registers.a & val;
    self.registers.a = result;
    self.registers.setFlag(.z, @intFromBool(result == 0));
    self.registers.setFlag(.n, 0);
    self.registers.setFlag(.h, 1);
    self.registers.setFlag(.c, 0);
    return if (Registers.isR8HL(op_r8)) .ok(2) else .ok(1);
}

inline fn andAN8(self: *Self) StepResult {
    const val = self.consumePC();
    const result = self.registers.a & val;
    self.registers.a = result;
    self.registers.setFlag(.z, @intFromBool(result == 0));
    self.registers.setFlag(.n, 0);
    self.registers.setFlag(.h, 1);
    self.registers.setFlag(.c, 0);
    return .ok(2);
}

/// CPL
inline fn cpl(self: *Self) StepResult {
    self.registers.a = ~self.registers.a;
    self.registers.setFlag(.n, 1);
    self.registers.setFlag(.h, 1);
    return .ok(1);
}

inline fn orAR8(self: *Self, opcode: u8) StepResult {
    const op_r8 = util.fromMask(u3, opcode, 0b111);
    const val = self.registers.getR8(op_r8, self.memory);
    const result = self.registers.a | val;
    self.registers.a = result;
    self.registers.setFlag(.z, @intFromBool(result == 0));
    self.registers.setFlag(.n, 0);
    self.registers.setFlag(.h, 0);
    self.registers.setFlag(.c, 0);
    return if (Registers.isR8HL(op_r8)) .ok(2) else .ok(1);
}

inline fn orAN8(self: *Self) StepResult {
    const val = self.consumePC();
    const result = self.registers.a | val;
    self.registers.a = result;
    self.registers.setFlag(.z, @intFromBool(result == 0));
    self.registers.setFlag(.n, 0);
    self.registers.setFlag(.h, 0);
    self.registers.setFlag(.c, 0);
    return .ok(2);
}

inline fn xorAR8(self: *Self, opcode: u8) StepResult {
    const op_r8 = util.fromMask(u3, opcode, 0b111);
    const val = self.registers.getR8(op_r8, self.memory);
    const result = self.registers.a ^ val;
    self.registers.a = result;
    self.registers.setFlag(.z, @intFromBool(result == 0));
    self.registers.setFlag(.n, 0);
    self.registers.setFlag(.h, 0);
    self.registers.setFlag(.c, 0);
    return if (Registers.isR8HL(op_r8)) .ok(2) else .ok(1);
}

inline fn xorAN8(self: *Self) StepResult {
    const val = self.consumePC();
    const result = self.registers.a ^ val;
    self.registers.a = result;
    self.registers.setFlag(.z, @intFromBool(result == 0));
    self.registers.setFlag(.n, 0);
    self.registers.setFlag(.h, 0);
    self.registers.setFlag(.c, 0);
    return .ok(2);
}

// Bit flag instructions ///////////////////////////////////////////////////////

/// Test bit u3 in register r8, set the zero flag if bit not set.
inline fn bitU3R8(self: *Self, opcode: u8) StepResult {
    const bit_index = util.fromMask(u3, opcode, 0b111000);
    const op_r8 = util.fromMask(u3, opcode, 0b111);
    const r8_val = self.registers.getR8(op_r8, self.memory);
    const bit: u1 = @intCast((r8_val >> bit_index) & 0b1);
    self.registers.setFlag(.z, @intFromBool(bit == 0));
    self.registers.setFlag(.n, 0);
    self.registers.setFlag(.h, 1);
    return if (Registers.isR8HL(op_r8)) .ok(3) else .ok(2);
}

inline fn resU3R8(self: *Self, opcode: u8) StepResult {
    const bit_index = util.fromMask(u3, opcode, 0b111000);
    const op_r8 = util.fromMask(u3, opcode, 0b111);
    const r8_val = self.registers.getR8(op_r8, self.memory);
    const new_val: u8 = @intCast(r8_val & ~(@as(u8, 1) << bit_index));
    self.registers.setR8(op_r8, new_val, self.memory);
    return if (Registers.isR8HL(op_r8)) .ok(4) else .ok(2);
}

inline fn setU3R8(self: *Self, opcode: u8) StepResult {
    const bit_index = util.fromMask(u3, opcode, 0b111000);
    const op_r8 = util.fromMask(u3, opcode, 0b111);
    const r8_val = self.registers.getR8(op_r8, self.memory);
    // reset to 0 first, then set the bit to 1
    const new_val: u8 = @intCast((r8_val & ~(@as(u8, 1) << bit_index)) | (@as(u8, 1) << bit_index));
    self.registers.setR8(op_r8, new_val, self.memory);
    return if (Registers.isR8HL(op_r8)) .ok(4) else .ok(2);
}

// Bit shift instructions //////////////////////////////////////////////////////

/// RL r8 | RL [HL]
///
/// Rotate bits in register r8 left, through the carry flag.
inline fn rlR8(self: *Self, opcode: u8) StepResult {
    const op = util.fromMask(u3, opcode, 0b111);
    const val = self.registers.getR8(op, self.memory);
    const old_c = self.registers.getFlag(.c);
    const msb = util.fromMask(u1, val, 0b1000_0000);
    self.registers.setFlag(.c, msb);
    const new_r8 = (val << 1) | old_c;
    self.registers.setR8(op, new_r8, self.memory);
    self.registers.setFlag(.z, @intFromBool(new_r8 == 0));
    self.registers.setFlag(.n, 0);
    self.registers.setFlag(.h, 0);
    return if (Registers.isR8HL(op)) .ok(4) else .ok(2);
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
    return .ok(1);
}

/// RLC r8
///
/// Rotate register r8 left.
inline fn rlcR8(self: *Self, opcode: u8) StepResult {
    const op = util.fromMask(u3, opcode, 0b111);
    const val = self.registers.getR8(op, self.memory);
    const msb = util.fromMask(u1, val, 0b1000_0000);
    self.registers.setFlag(.c, msb);
    const new_r8 = (val << 1) | msb;
    self.registers.setR8(op, new_r8, self.memory);
    self.registers.setFlag(.z, @intFromBool(new_r8 == 0));
    self.registers.setFlag(.n, 0);
    self.registers.setFlag(.h, 0);
    return if (Registers.isR8HL(op)) .ok(4) else .ok(2);
}

/// RLCA
inline fn rlca(self: *Self) StepResult {
    const msb: u1 = @intCast((self.registers.a >> 7) & 0b1);
    self.registers.a = (self.registers.a << 1) | msb;
    self.registers.setFlag(.z, 0);
    self.registers.setFlag(.n, 0);
    self.registers.setFlag(.h, 0);
    self.registers.setFlag(.c, msb);
    return .ok(1);
}

///RR r8
///
///Rotate register r8 right, through the carry flag.
inline fn rrR8(self: *Self, opcode: u8) StepResult {
    const op = util.fromMask(u3, opcode, 0b111);
    const val = self.registers.getR8(op, self.memory);
    const lsb = util.fromMask(u1, val, 0b1);
    const old_c = self.registers.getFlag(.c);
    const new_r8 = (val >> 1) | (@as(u8, old_c) << 7);
    self.registers.setR8(op, new_r8, self.memory);
    self.registers.setFlag(.z, @intFromBool(new_r8 == 0));
    self.registers.setFlag(.n, 0);
    self.registers.setFlag(.h, 0);
    self.registers.setFlag(.c, lsb);
    return if (Registers.isR8HL(op)) .ok(4) else .ok(2);
}

inline fn rra(self: *Self) StepResult {
    const lsb = util.fromMask(u1, self.registers.a, 0b1);
    const c = self.registers.getFlag(.c);
    self.registers.a = ((self.registers.a >> 1) & util.u8ClearMask(7)) | (@as(u8, c) << 7);
    self.registers.setFlag(.z, 0);
    self.registers.setFlag(.n, 0);
    self.registers.setFlag(.h, 0);
    self.registers.setFlag(.c, lsb);
    return .ok(1);
}

/// RRC r8
///
/// Rotate register r8 right.
inline fn rrcR8(self: *Self, opcode: u8) StepResult {
    const op = util.fromMask(u3, opcode, 0b111);
    const val = self.registers.getR8(op, self.memory);
    const lsb = util.fromMask(u1, val, 0b1);
    const new_r8 = ((val >> 1) & util.u8ClearMask(7)) | (@as(u8, lsb) << 7);
    self.registers.setR8(op, new_r8, self.memory);
    self.registers.setFlag(.z, @intFromBool(new_r8 == 0));
    self.registers.setFlag(.n, 0);
    self.registers.setFlag(.h, 0);
    self.registers.setFlag(.c, lsb);
    return if (Registers.isR8HL(op)) .ok(4) else .ok(2);
}

/// RRCA
inline fn rrca(self: *Self) StepResult {
    const lsb: u1 = util.fromMask(u1, self.registers.a, 0b1);
    self.registers.a = (self.registers.a >> 1) | (@as(u8, lsb) << 7);
    self.registers.setFlag(.z, 0);
    self.registers.setFlag(.n, 0);
    self.registers.setFlag(.h, 0);
    self.registers.setFlag(.c, lsb);
    return .ok(1);
}

/// SLA r8
///
/// Shift Left Arithmetically register r8.
inline fn slaR8(self: *Self, opcode: u8) StepResult {
    const op = util.fromMask(u3, opcode, 0b111);
    const val = self.registers.getR8(op, self.memory);
    const msb = util.fromMask(u1, val, 0b1000_0000);
    const new_r8 = val << 1;
    self.registers.setR8(op, new_r8, self.memory);
    self.registers.setFlag(.z, @intFromBool(new_r8 == 0));
    self.registers.setFlag(.n, 0);
    self.registers.setFlag(.h, 0);
    self.registers.setFlag(.c, msb);
    return if (Registers.isR8HL(op)) .ok(4) else .ok(2);
}

/// SRA [HL]
///
/// Shift Right Arithmetically the byte pointed to by HL (bit 7 of the byte
/// pointed to by HL is unchanged).
inline fn sraR8(self: *Self, opcode: u8) StepResult {
    const op = util.fromMask(u3, opcode, 0b111);
    const val = self.registers.getR8(op, self.memory);
    const msb = util.fromMask(u1, val, 0b1000_0000);
    const lsb = util.fromMask(u1, val, 0b1);
    // Zig's >> operator: Moves all bits to the right, inserting zeroes at msb.
    // Hence, we have to set the msb to the old value ourselves.
    const new_r8 = (val >> 1) | (@as(u8, msb) << 7);
    self.registers.setR8(op, new_r8, self.memory);
    self.registers.setFlag(.z, @intFromBool(new_r8 == 0));
    self.registers.setFlag(.n, 0);
    self.registers.setFlag(.h, 0);
    self.registers.setFlag(.c, lsb);
    return if (Registers.isR8HL(op)) .ok(4) else .ok(2);
}

/// SRL r8
///
/// Shift Right Logically register r8.
inline fn srlR8(self: *Self, opcode: u8) StepResult {
    const op = util.fromMask(u3, opcode, 0b111);
    const val = self.registers.getR8(op, self.memory);
    const lsb = util.fromMask(u1, val, 0b1);
    // Zig's >> operator: Moves all bits to the right, inserting zeroes at msb.
    const new_r8 = (val >> 1);
    self.registers.setR8(op, new_r8, self.memory);
    self.registers.setFlag(.z, @intFromBool(new_r8 == 0));
    self.registers.setFlag(.n, 0);
    self.registers.setFlag(.h, 0);
    self.registers.setFlag(.c, lsb);
    return if (Registers.isR8HL(op)) .ok(4) else .ok(2);
}

/// SWAP r8
///
/// Swap the upper 4 bits in register r8 and the lower 4 ones.
inline fn swapR8(self: *Self, opcode: u8) StepResult {
    const op = util.fromMask(u3, opcode, 0b111);
    const val = self.registers.getR8(op, self.memory);
    const upper_4 = util.fromMask(u4, val, 0b1111_0000);
    const lower_4 = util.fromMask(u4, val, 0b0000_1111);
    const new_r8 = util.concatU8(upper_4, lower_4);
    self.registers.setR8(op, new_r8, self.memory);
    self.registers.setFlag(.z, @intFromBool(new_r8 == 0));
    self.registers.setFlag(.n, 0);
    self.registers.setFlag(.h, 0);
    self.registers.setFlag(.c, 0);
    return if (Registers.isR8HL(op)) .ok(4) else .ok(2);
}

// Jumps and subroutine instructions ///////////////////////////////////////////

inline fn callN16(self: *Self) StepResult {
    const lo_byte = self.consumePC();
    const hi_byte = self.consumePC();
    const addr = util.concatU16(lo_byte, hi_byte);
    self.timers.tickOneMCycle();
    self.stackPush(self.registers.pc);
    self.registers.pc = addr;
    return .ok(6);
}

inline fn callCCN16(self: *Self, opcode: u8) StepResult {
    const op_cond = util.fromMask(u2, opcode, 0b11000);
    const cond = self.registers.getCond(op_cond);
    const lo_byte = self.consumePC();
    const hi_byte = self.consumePC();
    const addr = util.concatU16(lo_byte, hi_byte);
    if (cond) {
        self.timers.tickOneMCycle();
        self.stackPush(self.registers.pc);
        self.registers.pc = addr;
        return .ok(6);
    } else {
        return .ok(3);
    }
}

inline fn jpHL(self: *Self) StepResult {
    self.registers.pc = self.registers.hl();
    return .ok(1);
}

inline fn jpN16(self: *Self) StepResult {
    const lo_byte = self.consumePC();
    const hi_byte = self.consumePC();
    const addr = util.concatU16(lo_byte, hi_byte);
    self.registers.pc = addr;
    self.timers.tickOneMCycle();
    return .ok(4);
}

inline fn jpCCN16(self: *Self, opcode: u8) StepResult {
    const op_cond = util.fromMask(u2, opcode, 0b11000);
    const cond = self.registers.getCond(op_cond);
    const lo_byte = self.consumePC();
    const hi_byte = self.consumePC();
    const addr = util.concatU16(lo_byte, hi_byte);
    if (cond) {
        self.timers.tickOneMCycle();
        self.registers.pc = addr;
        return .ok(4);
    } else {
        return .ok(3);
    }
}

/// JR n16 (actually imm8)
inline fn jrN16(self: *Self) StepResult {
    const raw = self.consumePC();
    const offset: i8 = @bitCast(raw);
    // Do this cast to leverage Zig's integer wrapping
    self.registers.pc +%= @as(u16, @bitCast(@as(i16, offset)));
    self.timers.tickOneMCycle();
    return .ok(3);
}

/// JR cc, n16 (actually imm8)
inline fn jrCCN16(self: *Self, opcode: u8) StepResult {
    const raw = self.consumePC();
    const offset: i8 = @bitCast(raw);
    const placeholder: u2 = @intCast((opcode >> 3) & 0b11);
    if (self.registers.getCond(placeholder)) {
        // Do this cast to leverage Zig's integer wrapping
        self.registers.pc +%= @as(u16, @bitCast(@as(i16, offset)));
        self.timers.tickOneMCycle();
        return .ok(3);
    } else {
        return .ok(2);
    }
}

/// RET cc - Return from subroutine if condition cc is met.
inline fn retCC(self: *Self, opcode: u8) StepResult {
    self.timers.tickOneMCycle();
    const op_cond = util.fromMask(u2, opcode, 0b11000);
    const cond = self.registers.getCond(op_cond);
    if (cond) {
        self.timers.tickOneMCycle();
        self.registers.pc = self.stackPop();
        return .ok(5);
    } else {
        return .ok(2);
    }
}

/// RET
///
/// Return from subroutine. This is basically a POP PC (if such an instruction existed).
/// See POP r16 for an explanation of how POP works.
inline fn ret(self: *Self) StepResult {
    self.registers.pc = self.stackPop();
    self.timers.tickOneMCycle();
    return .ok(4);
}

/// RETI
///
/// Return from subroutine and enable interrupts. This is basically equivalent to
/// executing EI then RET, meaning that IME is set right after this instruction.
inline fn reti(self: *Self) StepResult {
    _ = self.ei();
    _ = self.ret();
    return .ok(4);
}

/// RST vec
///
/// Call address vec. This is a shorter and faster equivalent to CALL for suitable
/// values of vec.
inline fn rstVec(self: *Self, opcode: u8) StepResult {
    const op_vec = util.fromMask(u3, opcode, 0b111000);
    const addr = @as(u16, @intCast(op_vec)) * 8;
    self.timers.tickOneMCycle();
    self.stackPush(self.registers.pc);
    self.registers.pc = addr;
    return .ok(4);
}

// Carry flag instructions /////////////////////////////////////////////////////

/// CCF
inline fn ccf(self: *Self) StepResult {
    self.registers.setFlag(.c, ~self.registers.getFlag(.c));
    self.registers.setFlag(.n, 0);
    self.registers.setFlag(.h, 0);
    return .ok(1);
}

/// SCF
inline fn scf(self: *Self) StepResult {
    self.registers.setFlag(.c, 1);
    self.registers.setFlag(.n, 0);
    self.registers.setFlag(.h, 0);
    return .ok(1);
}

// Stack manipulation instructions /////////////////////////////////////////////

/// ADD HL,SP - Add the value in SP to HL.
inline fn addHLSP(self: *Self) StepResult {
    const old_val = self.registers.hl();
    const sp = self.registers.sp;
    self.registers.setHl(old_val + sp);
    self.registers.setFlag(.n, 0);
    self.registers.setFlag(.h, @intFromBool(((old_val & 0x0FFF) + (sp & 0x0FFF)) > 0x0FFF));
    self.registers.setFlag(.c, @intFromBool(@as(u32, old_val) + @as(u32, sp) > 0xFFFF));
    self.timers.tickOneMCycle();
    return .ok(2);
}

/// ADD SP,e8 - Add the signed value e8 to SP.
inline fn addSPE8(self: *Self) StepResult {
    const raw = self.consumePC();
    const offset: i8 = @bitCast(raw);
    const old_val = self.registers.sp;
    // i8 -> i16 -> u16: Do this cast to leverage Zig's integer wrapping
    const new_val = old_val +% @as(u16, @bitCast(@as(i16, offset)));
    self.registers.sp = new_val;
    self.registers.setFlag(.z, 0);
    self.registers.setFlag(.n, 0);
    // H: Set if overflow from bit 3
    self.registers.setFlag(.h, @intFromBool((old_val & 0x0F) + (raw & 0x0F) > 0x0F));
    // C: Set if overflow from bit 7
    self.registers.setFlag(.c, @intFromBool((old_val & 0xFF) + (raw & 0xFF) > 0xFF));
    self.timers.tickOneMCycle();
    self.timers.tickOneMCycle();
    return .ok(4);
}

inline fn decSP(self: *Self) StepResult {
    self.registers.sp -%= 1;
    self.timers.tickOneMCycle();
    return .ok(2);
}

inline fn incSP(self: *Self) StepResult {
    self.registers.sp +%= 1;
    self.timers.tickOneMCycle();
    return .ok(2);
}

inline fn ldSPN16(self: *Self) StepResult {
    const byte1 = self.consumePC();
    const byte2 = self.consumePC();
    const addr = util.concatU16(byte1, byte2);
    self.registers.sp = addr;
    return .ok(3);
}
/// LD [n16],SP
inline fn ldN16SP(self: *Self) StepResult {
    const byte1 = self.consumePC();
    const byte2 = self.consumePC();
    const n16 = util.concatU16(byte1, byte2);
    self.memory.write(n16, @intCast(self.registers.sp & 0xFF));
    self.memory.write(n16 + 1, @intCast((self.registers.sp >> 8) & 0xFF));
    return .ok(5);
}

/// LD HL,SP+e8 - Add the signed value e8 to SP and copy the result in HL.
inline fn ldHLSPE8(self: *Self) StepResult {
    const raw = self.consumePC();
    const offset: i8 = @bitCast(raw);
    const old_val = self.registers.sp;
    // i8 -> i16 -> u16: Do this cast to leverage Zig's integer wrapping
    const new_val = old_val +% @as(u16, @bitCast(@as(i16, offset)));
    self.registers.setHl(new_val);
    self.registers.setFlag(.z, 0);
    self.registers.setFlag(.n, 0);
    // H: Set if overflow from bit 3
    self.registers.setFlag(.h, @intFromBool((old_val & 0x0F) + (raw & 0x0F) > 0x0F));
    // C: Set if overflow from bit 7
    self.registers.setFlag(.c, @intFromBool((old_val & 0xFF) + (raw & 0xFF) > 0xFF));
    self.timers.tickOneMCycle();
    return .ok(3);
}

inline fn ldSPHL(self: *Self) StepResult {
    self.registers.sp = self.registers.hl();
    self.timers.tickOneMCycle();
    return .ok(2);
}

inline fn popAF(self: *Self) StepResult {
    self.registers.setAf(self.stackPop());
    return .ok(3);
}

/// POP r16 | pop r16stk - Pop register r16 from the stack.
inline fn popR16(self: *Self, opcode: u8) StepResult {
    const r16_op = util.fromMask(u2, opcode, 0b110000);
    const new_val = self.stackPop();
    self.registers.setR16Stk(r16_op, new_val);
    return .ok(3);
}

inline fn pushAF(self: *Self) StepResult {
    self.stackPush(self.registers.af());
    self.timers.tickOneMCycle();
    return .ok(4);
}

inline fn pushR16(self: *Self, opcode: u8) StepResult {
    const r16_op = util.fromMask(u2, opcode, 0b110000);
    const r16 = self.registers.getR16Stk(r16_op);
    self.stackPush(r16);
    self.timers.tickOneMCycle();
    return .ok(4);
}

// Interrupt-related instructions //////////////////////////////////////////////

inline fn di(self: *Self) StepResult {
    self.interrupts.ime = false;
    return .ok(1);
}

inline fn ei(self: *Self) StepResult {
    self.interrupts.ime_pending_enable = .delay;
    return .ok(1);
}

inline fn halt(self: *Self) StepResult {
    self.state = .halted;
    return .halted();
}

// Miscellaneous instructions //////////////////////////////////////////////////

/// No OPeration.
inline fn nop(self: *Self) StepResult {
    _ = self;
    return .ok(1);
}

/// STOP - also consume second byte
inline fn stop(self: *Self) StepResult {
    _ = self.consumePC();
    self.timers.div = 0;
    self.timers.div_enabled = false;
    return .stopped();
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
    return .ok(1);
}
