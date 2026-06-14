const Self = @This();
const std = @import("std");
const Interrupts = @import("Interrupts.zig");
const config = @import("config.zig");
const util = @import("util.zig");

const cycles_limit = config.cpu.cycles_per_frame;

div: u8 = 0,
tima: u8 = 0,
tma: u8 = 0,
tac: u8 = 0,

// internal:
div_enabled: bool = true,
div_accumulator_mcycles: usize = 0,
div_every_mcycle: usize = 64,
tima_accumulator_mcycles: usize = 0,
tima_enabled: bool = false,
tima_every_mcycles: usize = 0,
tima_interrupt_state: TimaInterruptState = .normal,

interrupts: *Interrupts,

// version 2 implementation

pub const TimaInterruptState = enum {
    normal,
    armed,
    pending_interrupt,
};

pub fn init(interrupts: *Interrupts) Self {
    return Self{ .interrupts = interrupts };
}

pub inline fn incDiv(self: *Self) void {
    if (self.div_enabled)
        self.div +%= 1;
}

pub inline fn readDiv(self: *Self) u8 {
    return self.div;
}

/// Writing any value to this register resets it to $00.
pub inline fn writeDiv(self: *Self, val: u8) void {
    _ = val;
    self.div = 0;
}

pub inline fn incTima(self: *Self) void {
    if (self.tima == 0xFF) {
        // see https://gbdev.io/pandocs/Timer_Obscure_Behaviour.html#relation-between-timer-and-divider-register
        self.tima = 0x00;
        self.tima_interrupt_state = .armed;
    } else {
        self.tima += 1;
    }
}

pub fn processTimaState(self: *Self) void {
    switch (self.tima_interrupt_state) {
        .normal => {},
        .armed => self.tima_interrupt_state = .pending_interrupt,
        .pending_interrupt => {
            self.tima_interrupt_state = .normal;
            self.tima = self.tma;
            self.interrupts.request(.timer);
        },
    }
}

pub inline fn readTima(self: *Self) u8 {
    return self.tima;
}

pub inline fn writeTima(self: *Self, val: u8) void {
    self.tima = val;
}

pub inline fn writeTma(self: *Self, val: u8) void {
    self.tma = val;
}

pub inline fn readTma(self: *Self) u8 {
    return self.tma;
}

pub inline fn writeTac(self: *Self, val: u8) void {
    self.tac = val;

    const enable_bit = util.fromMask(u1, val, 0b100);
    self.tima_enabled = if (enable_bit == 1) true else false;

    const clock_bits = util.fromMask(u2, val, 0b11);
    switch (clock_bits) {
        0b00 => self.tima_every_mcycles = 256,
        0b01 => self.tima_every_mcycles = 4,
        0b10 => self.tima_every_mcycles = 16,
        0b11 => self.tima_every_mcycles = 64,
    }
}

pub inline fn readTac(self: *Self) u8 {
    return self.tac;
}

// pub fn tick(self: *Self, elapsed_t_cycles: usize, interrupts: *Interrupts) void {
//     // add the elapsed cycles to the accumulators
//     self.div_accumulator += elapsed_t_cycles;
//
//     // div - inc every 256 T-cycles
//     while (self.div_accumulator >= self.div_every_t) {
//         self.incDiv();
//         self.div_accumulator -= self.div_every_t;
//     }
//
//     // tima - only if enabled
//     if (self.tima_enabled) {
//         self.tima_accumulator += elapsed_t_cycles;
//         // tima - inc every X T-cycles, depending on TAC
//         while (self.tima_accumulator >= self.tima_every_t) {
//             self.incTima();
//             self.tima_accumulator -= self.tima_every_t;
//         }
//     }
//
//     self.processTimaState(interrupts);
// }

pub fn tickOneMCycle(self: *Self) void {
    self.div_accumulator_mcycles += 1;

    while (self.div_accumulator_mcycles >= self.div_every_mcycle) {
        self.incDiv();
        self.div_accumulator_mcycles -= self.div_every_mcycle;
    }

    if (self.tima_enabled) {
        self.tima_accumulator_mcycles += 1;
        while (self.tima_accumulator_mcycles >= self.tima_every_mcycles) {
            self.incTima();
            self.tima_accumulator_mcycles -= self.tima_every_mcycles;
        }
    }

    self.processTimaState();
}
