const Self = @This();
const Interrupts = @import("Interrupts.zig");
const config = @import("config.zig");
const util = @import("util.zig");

const cycles_limit = config.cpu.cycles_per_frame;

// This register is incremented at a rate of 16384Hz (every 256 T-cycles).
// Writing any value to this register resets it to $00. Additionally, this
// register is reset when executing the stop instruction, and only begins
// ticking again once stop mode ends.
div: u8 = 0,

// This timer is incremented at the clock frequency specified by the TAC
// register ($FF07). When the value overflows (exceeds $FF) it is reset
// to the value specified in TMA (FF06) and an interrupt is requested, as
// described below.
tima: u8 = 0,

// When TIMA overflows, it is reset to the value in this register and an
// interrupt is requested.
tma: u8 = 0,

// bit01 = Clock select
// bit2 = Enable
tac: u8 = 0,

// internal:
last_cpu_t_cycles: usize = 0,
div_enabled: bool = true,
div_accumulator: usize = 0,
div_every_t: usize = 256,
tima_accumulator: usize = 0,
tima_enabled: bool = false,
tima_every_t: usize = 0,
tima_interrupt_state: TimaInterruptState = .normal,

pub const TimaInterruptState = enum {
    normal,
    armed,
    pending_interrupt,
};

pub fn init() Self {
    return Self{};
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
        // next inc will overflow
        // self.tima = self.tma; // wrong, see https://gbdev.io/pandocs/Timer_Obscure_Behaviour.html#relation-between-timer-and-divider-register
        self.tima = 0x00;
        // interrupts.request(.timer);
        self.tima_interrupt_state = .armed;
    } else {
        self.tima += 1;
    }
}

pub fn processTimaState(self: *Self, interrupts: *Interrupts) void {
    switch (self.tima_interrupt_state) {
        .normal => {},
        .armed => self.tima_interrupt_state = .pending_interrupt,
        .pending_interrupt => {
            self.tima_interrupt_state = .normal;
            self.tima = self.tma;
            interrupts.request(.timer);
        },
    }
}

pub inline fn readTima(self: *Self) u8 {
    return self.tima;
}

pub inline fn writeTima(self: *Self, val: u8) void {
    self.tima = val;
}

pub inline fn readTma(self: *Self) u8 {
    return self.tma;
}

pub inline fn writeTma(self: *Self, val: u8) void {
    self.tma = val;
}

pub inline fn writeTac(self: *Self, val: u8) void {
    self.tac = val;

    const enable_bit = util.fromMask(u1, val, 0b100);
    self.tima_enabled = if (enable_bit == 1) true else false;

    const clock_bits = util.fromMask(u2, val, 0b11);
    switch (clock_bits) {
        0b00 => self.tima_every_t = 256 * 4,
        0b01 => self.tima_every_t = 4 * 4,
        0b10 => self.tima_every_t = 16 * 4,
        0b11 => self.tima_every_t = 64 * 4,
    }
}

pub inline fn readTac(self: *Self) u8 {
    return self.tac;
}

pub fn tick(self: *Self, cpu_t_cycles: usize) void {
    const elapsed_t_cycles = (cpu_t_cycles + cycles_limit - self.last_cpu_t_cycles) % cycles_limit;
    self.last_cpu_t_cycles = cpu_t_cycles;

    // add the elapsed cycles to the accumulators
    self.div_accumulator += elapsed_t_cycles;

    // div - inc every 256 T-cycles
    while (self.div_accumulator >= self.div_every_t) {
        self.incDiv();
        self.div_accumulator -= self.div_every_t;
    }

    // tima - only if enabled
    if (self.tima_enabled) {
        self.tima_accumulator += elapsed_t_cycles;
        // tima - inc every X T-cycles, depending on TAC
        while (self.tima_accumulator >= self.tima_every_t) {
            self.incTima();
            self.tima_accumulator -= self.tima_every_t;
        }
    }
}
