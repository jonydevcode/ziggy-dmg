//! Represents all forms of memory on the gameboy including RAM and VRAM.
//! Does not include registers.
//! See https://gbdev.io/pandocs/Memory_Map.html
const Self = @This();
const std = @import("std");
const config = @import("config.zig");
const Interrupts = @import("Interrupts.zig");
const Timers = @import("Timers.zig");
const util = @import("util.zig");
const Cartridge = @import("Cartridge.zig");

// rom: []const u8,
cartridge: *Cartridge,
wram: [config.cpu.ram_size]u8 = @splat(0),
vram: [config.cpu.vram_size]u8 = @splat(0),
oam: [config.cpu.oam_size]u8 = @splat(0),
hram: [config.cpu.hram_size]u8 = @splat(0),
extram: [config.cpu.extram_size]u8 = @splat(0),

interrupts: *Interrupts,
timers: *Timers,

io_unused: [128]u8 = @splat(0),

pub fn init(cartridge: *Cartridge, interrupts: *Interrupts, timers: *Timers) Self {
    return Self{
        .cartridge = cartridge,
        .interrupts = interrupts,
        .timers = timers,
    };
}

/// Does a read off the 16-bit address bus
pub fn read(self: *Self, addr: u16) u8 {
    self.timers.tickOneMCycle();
    if (0x0000 <= addr and addr <= 0x3FFF) {
        // 16 KiB ROM bank 00
        return self.cartridge.read(addr);
    } else if (0x4000 <= addr and addr <= 0x7FFF) {
        // 16 KiB ROM Bank 01–NN
        return self.cartridge.read(addr);
    } else if (0x8000 <= addr and addr <= 0x9FFF) {
        // 8 KiB Video RAM (VRAM)
        return self.vram[addr - 0x8000];
    } else if (0xA000 <= addr and addr <= 0xBFFF) {
        // 8 KiB External RAM
        return self.extram[addr - 0xA000];
    } else if (0xC000 <= addr and addr <= 0xCFFF) {
        // 4 KiB Work RAM (WRAM)
        return self.wram[addr - 0xC000];
    } else if (0xD000 <= addr and addr <= 0xDFFF) {
        // 4 KiB Work RAM (WRAM)
        return self.wram[addr - 0xC000];
    } else if (0xE000 <= addr and addr <= 0xFDFF) {
        // Echo RAM (mirror of C000–DDFF)
        // All reads and writes to this range have the same effect as reads and writes to C000-DDFF.
        return self.wram[addr - 0xE000];
    } else if (0xFE00 <= addr and addr <= 0xFE9F) {
        // Object attribute memory (OAM)
        // TODO: Implement OAM properly.
        return self.oam[addr - 0xFE00];
    } else if (0xFEA0 <= addr and addr <= 0xFEFF) {
        // Not Usable
        std.debug.panic("Not Usable address: {X}\n", .{addr});
    } else if (0xFF00 <= addr and addr <= 0xFF7F) {
        // I/O Registers
        switch (addr) {
            0xFF04 => return self.timers.readDiv(),
            0xFF05 => return self.timers.readTima(),
            0xFF06 => return self.timers.readTma(),
            0xFF07 => return self.timers.readTac(),
            0xFF0F => return self.interrupts.interrupt_flag,
            // For Gameboy Doctor
            0xFF44 => return 0x90,
            0xFF4D => return 0xFF, // KEY1 register is unavailable on DMG
            else => return self.io_unused[addr - 0xFF00],
        }
    } else if (0xFF80 <= addr and addr <= 0xFFFE) {
        // High RAM (HRAM)
        // TODO: Implement HRAM properly.
        return self.hram[addr - 0xFF80];
    } else if (0xFFFF <= addr and addr <= 0xFFFF) {
        // Interrupt Enable register (IE)
        return self.interrupts.interrupt_enable;
    }
    std.debug.panic("Invalid memory address: {X}\n", .{addr});
}

/// Does a write to the 16-bit address bus
pub fn write(self: *Self, addr: u16, val: u8) void {
    self.timers.tickOneMCycle();
    if (0x0000 <= addr and addr <= 0x7FFF) {
        self.cartridge.write(addr, val);
    } else if (0x8000 <= addr and addr <= 0x9FFF) {
        // 8 KiB Video RAM (VRAM)
        self.vram[addr - 0x8000] = val;
    } else if (0xA000 <= addr and addr <= 0xBFFF) {
        // 8 KiB External RAM
        self.extram[addr - 0xA000] = val;
    } else if (0xC000 <= addr and addr <= 0xCFFF) {
        // 4 KiB Work RAM (WRAM)
        self.wram[addr - 0xC000] = val;
    } else if (0xD000 <= addr and addr <= 0xDFFF) {
        // 4 KiB Work RAM (WRAM)
        self.wram[addr - 0xC000] = val;
    } else if (0xE000 <= addr and addr <= 0xFDFF) {
        // Echo RAM (mirror of C000–DDFF)
        // All reads and writes to this range have the same effect as reads and writes to C000-DDFF.
        self.wram[addr - 0xE000] = val;
    } else if (0xFE00 <= addr and addr <= 0xFE9F) {
        // Object attribute memory (OAM)
        // TODO: Implement OAM properly.
        self.oam[addr - 0xFE00] = val;
    } else if (0xFEA0 <= addr and addr <= 0xFEFF) {
        // Not Usable
        std.debug.panic("Not Usable address: {X}\n", .{addr});
    } else if (0xFF00 <= addr and addr <= 0xFF7F) {
        // I/O Registers
        switch (addr) {
            0xFF01 => std.debug.print("{c}", .{val}), // for blargg's test roms
            0xFF04 => self.timers.writeDiv(val),
            0xFF05 => self.timers.writeTima(val),
            0xFF06 => self.timers.writeTma(val),
            0xFF07 => self.timers.writeTac(val),
            0xFF0F => self.interrupts.interrupt_flag = val,
            else => self.io_unused[addr - 0xFF00] = val,
        }
    } else if (0xFF80 <= addr and addr <= 0xFFFE) {
        // High RAM (HRAM)
        // TODO: Implement HRAM properly.
        self.hram[addr - 0xFF80] = val;
    } else if (0xFFFF <= addr and addr <= 0xFFFF) {
        // Interrupt Enable register (IE)
        self.interrupts.interrupt_enable = val;
    }
}
