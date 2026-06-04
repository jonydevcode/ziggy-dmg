const Self = @This();
const std = @import("std");
const config = @import("config.zig");
const Registers = @import("Registers.zig");
const Memory = @import("Memory.zig");

allocator: std.mem.Allocator, // mainly for the stack
rng: std.Random,

interrupt_enable: u8 = 0,
interrupt_flags: u8 = 0,

registers: Registers,
memory: *Memory,

pub const StepResult = struct {
    display_changed: bool,
    cycles_used: usize,

    pub fn init(display_changed: bool, cycles_used: usize) StepResult {
        return .{ .display_changed = display_changed, .cycles_used = cycles_used };
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
        0b00 => {},
        0b01 => {},
        0b10 => {},
        0b11 => {},
    }

    return StepResult{
        .display_changed = true,
        .cycles_used = 10,
    };
}

pub fn cbPrefix(self: *Self) !StepResult {
    const opcode = self.memory.read(self.registers.pc);
    self.registers.pc += 1;

    _ = opcode;

    return StepResult.init(false, 0);
}

pub fn block0(self: *Self, opcode: u8) !StepResult {
    if (opcode == 0x0) {
        // nop
        return StepResult.init(false, 4);
    } else if (opcode == 0b00010000) {
        // stop - consume second byte
        self.registers.pc += 1;
        return StepResult.init(false, 4);
    } else {
        const low4: u4 = @intCast(u8 & 0b1111);
        switch (low4) {
            0b0001 => {},
            0b0010 => {},
            0b1010 => {},
            0b1000 => {},
            0b0011 => {},
            0b1011 => {},
            0b1001 => {},
            else => {
                const low3: u3 = @intCast(u8 & 0b111);
                switch (low3) {
                    0b100 => {},
                    0b101 => {},
                    0b110 => {},
                    0b111 => {
                        const mid3: u3 = @intCast((opcode >> 3) & 0b111);
                        switch (mid3) {
                            0b000 => {},
                            0b001 => {},
                            0b010 => {},
                            0b011 => {},
                            0b100 => {},
                            0b101 => {},
                            0b110 => {},
                            0b111 => {},
                        }
                    },
                    0b000 => {
                        const bit5: u1 = @intCast((opcode >> 5) & 1);
                        switch (bit5) {
                            0b0 => {},
                            0b1 => {},
                        }
                    },
                }
            },
        }
    }
}
