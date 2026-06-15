const Self = @This();
const std = @import("std");
const Interrupts = @import("Interrupts.zig");
const config = @import("config.zig");
const util = @import("util.zig");

const cycles_limit = config.cpu.cycles_per_frame;

div_visible: u8 = 0,
tima: u8 = 0,
tma: u8 = 0,
tac: u8 = 0,

// https://github.com/Ashiepaws/GBEDG/blob/master/timers/index.md
// Internally, the DIV register is a 16-bit counter which is incremented
// every single T-cycle, only the upper 8 bits are mapped to memory.
div: u16 = 0,

// internal:
tac_freq_bit_index: u4 = 0,
div_enabled: bool = true,
// div_accumulator_mcycles: usize = 0,
// div_every_mcycle: usize = 64,
// tima_accumulator_mcycles: usize = 0,
tac_tima_enabled: bool = false,
// tima_every_mcycles: usize = 0,
tima_interrupt_state: TimaInterruptState = .normal,

interrupts: *Interrupts,

// version 2 implementation

pub const TimaInterruptState = enum {
    normal,
    overflow_last_cycle,
    reloaded_last_cycle,
};

pub fn init(interrupts: *Interrupts) Self {
    return Self{ .interrupts = interrupts };
}

pub inline fn incDiv(self: *Self) void {
    if (self.div_enabled)
        self.div_visible +%= 1;
}

pub inline fn readDiv(self: *Self) u8 {
    return util.fromMask(u8, self.div, 0xFF00);
}

/// Writing any value to this register resets it to $00.
pub inline fn writeDiv(self: *Self, val: u8) void {
    _ = val;
    // any changes to div incur a falling edge detection
    const prev_cycle = self.calcEdge();
    self.div = 0;
    const this_cycle = self.calcEdge();
    if (prev_cycle == 1 and this_cycle == 0) {
        self.incTima();
    }
}

pub inline fn incTima(self: *Self) void {
    if (self.tima == 0xFF) {
        // see https://gbdev.io/pandocs/Timer_Obscure_Behaviour.html#relation-between-timer-and-divider-register
        self.tima = 0x00;
        self.tima_interrupt_state = .overflow_last_cycle;
    } else {
        self.tima += 1;
    }
}

pub fn processTimaState(self: *Self) void {
    switch (self.tima_interrupt_state) {
        .normal => {},
        .overflow_last_cycle => {
            self.tima = self.tma;
            self.interrupts.request(.timer);
            self.tima_interrupt_state = .reloaded_last_cycle;
        },
        .reloaded_last_cycle => {
            self.tima_interrupt_state = .normal;
        },
    }
}

pub inline fn readTima(self: *Self) u8 {
    return self.tima;
}

pub inline fn writeTima(self: *Self, val: u8) void {
    switch (self.tima_interrupt_state) {
        .normal => self.tima = val,
        // writing to TIMA after overflow (cycle A on pandocs) cancels the TMA reload and interrupt
        .overflow_last_cycle => {
            self.tima = val;
            self.tima_interrupt_state = .normal;
        },
        // writing to TIMA after a reload (cycle B on pandocs) does nothing
        .reloaded_last_cycle => {},
    }
}

pub inline fn readTma(self: *Self) u8 {
    return self.tma;
}

pub inline fn writeTma(self: *Self, val: u8) void {
    self.tma = val;

    // if TIMA was reloaded last cycle, then new TMA also goes in
    if (self.tima_interrupt_state == .reloaded_last_cycle) {
        self.tima = val;
    }
}

pub inline fn writeTac(self: *Self, val: u8) void {
    // any writes to TAC incur the falling edge detection
    const prev_cycle = self.calcEdge();

    self.tac = val;

    const enable_bit = util.fromMask(u1, val, 0b100);
    self.tac_tima_enabled = if (enable_bit == 1) true else false;

    const clock_bits = util.fromMask(u2, val, 0b11);
    switch (clock_bits) {
        0b00 => self.tac_freq_bit_index = 9,
        0b01 => self.tac_freq_bit_index = 3,
        0b10 => self.tac_freq_bit_index = 5,
        0b11 => self.tac_freq_bit_index = 7,
    }

    const this_cycle = self.calcEdge();
    if (prev_cycle == 1 and this_cycle == 0) {
        self.incTima();
    }
    // test
    // std.debug.print("writeTac({X}): tima_enabled={}, tima_mcycles={}\n", .{ val, enable_bit, self.tima_every_mcycles });
}

pub inline fn readTac(self: *Self) u8 {
    return self.tac;
}

fn calcEdge(self: *Self) u1 {
    const bit_from_div: u1 = if (self.div & (@as(u16, 1) << self.tac_freq_bit_index) != 0) 1 else 0;
    const and_result: u1 = if (bit_from_div & @intFromBool(self.tac_tima_enabled) != 0) 1 else 0;
    return bit_from_div & and_result;
}

pub fn tickOneMCycle(self: *Self) void {
    self.processTimaState();

    // See how to calculate the falling edge at
    // https://github.com/Ashiepaws/GBEDG/blob/master/timers/index.md#timer-operation
    const prev_cycle = self.calcEdge();
    self.div +%= 4; // 1 M cycle = 4 T cycles
    const this_cycle = self.calcEdge();

    if (prev_cycle == 1 and this_cycle == 0) {
        self.incTima();
    }
}
