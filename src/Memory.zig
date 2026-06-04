//! Represents all forms of memory on the gameboy including RAM and VRAM.
//! Does not include registers.
//! See https://gbdev.io/pandocs/Memory_Map.html
const Self = @This();
const std = @import("std");
const config = @import("config.zig");

rom: []const u8,
ram: [config.cpu.ram_size]u8 = @splat(0),
vram: [config.cpu.vram_size]u8 = @splat(0),
oam: [config.cpu.oam_size]u8 = @splat(0),
hram: [config.cpu.hram_size]u8 = @splat(0),

pub fn init(rom: []const u8) Self {
    return Self{
        .rom = rom,
    };
}

/// Does a read off the 16-bit address bus
pub fn read(self: *Self, addr: u16) u8 {
    if (0x0000 <= addr and addr <= 0x3FFF) {
        // 16 KiB ROM bank 00
        return self.rom[addr];
    } else if (0x4000 <= addr and addr <= 0x7FFF) {
        // 16 KiB ROM Bank 01–NN
        std.debug.panic("Address range not implemented yet: {X}\n", .{addr});
    } else if (0x8000 <= addr and addr <= 0x9FFF) {
        // 8 KiB Video RAM (VRAM)
        std.debug.panic("Address range not implemented yet: {X}\n", .{addr});
    } else if (0xA000 <= addr and addr <= 0xBFFF) {
        // 8 KiB External RAM
        std.debug.panic("Address range not implemented yet: {X}\n", .{addr});
    } else if (0xC000 <= addr and addr <= 0xCFFF) {
        // 4 KiB Work RAM (WRAM)
        std.debug.panic("Address range not implemented yet: {X}\n", .{addr});
    } else if (0xD000 <= addr and addr <= 0xDFFF) {
        // 4 KiB Work RAM (WRAM)
        std.debug.panic("Address range not implemented yet: {X}\n", .{addr});
    } else if (0xE000 <= addr and addr <= 0xFDFF) {
        // Echo RAM (mirror of C000–DDFF)
        // All reads and writes to this range have the same effect as reads and writes to C000-DDFF.
        std.debug.panic("Address range not implemented yet: {X}\n", .{addr});
    } else if (0xFE00 <= addr and addr <= 0xFE9F) {
        // Object attribute memory (OAM)
        std.debug.panic("Address range not implemented yet: {X}\n", .{addr});
    } else if (0xFEA0 <= addr and addr <= 0xFEFF) {
        // Not Usable
        std.debug.panic("Not Usable address: {X}\n", .{addr});
    } else if (0xFF00 <= addr and addr <= 0xFF7F) {
        // I/O Registers
        std.debug.panic("Address range not implemented yet: {X}\n", .{addr});
    } else if (0xFF80 <= addr and addr <= 0xFFFE) {
        // High RAM (HRAM)
        std.debug.panic("Address range not implemented yet: {X}\n", .{addr});
    } else if (0xFFFF <= addr and addr <= 0xFFFF) {
        // Interrupt Enable register (IE)
        std.debug.panic("Address range not implemented yet: {X}\n", .{addr});
    }
    std.debug.panic("Invalid memory address: {X}\n", .{addr});
}

/// Does a write to the 16-bit address bus
pub fn write(self: *Self, addr: u16, val: u8) void {
    if (0x0000 <= addr and addr <= 0x3FFF) {
        // 16 KiB ROM bank 00
        std.debug.panic("Attempt to write to ROM address: {X}\n", .{addr});
    } else if (0x4000 <= addr and addr <= 0x7FFF) {
        // 16 KiB ROM Bank 01–NN
        std.debug.panic("Address range not implemented yet: {X}\n", .{addr});
    } else if (0x8000 <= addr and addr <= 0x9FFF) {
        // 8 KiB Video RAM (VRAM)
        std.debug.panic("Address range not implemented yet: {X}\n", .{addr});
    } else if (0xA000 <= addr and addr <= 0xBFFF) {
        // 8 KiB External RAM
        std.debug.panic("Address range not implemented yet: {X}\n", .{addr});
    } else if (0xC000 <= addr and addr <= 0xCFFF) {
        // 4 KiB Work RAM (WRAM)
        std.debug.panic("Address range not implemented yet: {X}\n", .{addr});
    } else if (0xD000 <= addr and addr <= 0xDFFF) {
        // 4 KiB Work RAM (WRAM)
        std.debug.panic("Address range not implemented yet: {X}\n", .{addr});
    } else if (0xE000 <= addr and addr <= 0xFDFF) {
        // Echo RAM (mirror of C000–DDFF)
        // All reads and writes to this range have the same effect as reads and writes to C000-DDFF.
        std.debug.panic("Address range not implemented yet: {X}\n", .{addr});
    } else if (0xFE00 <= addr and addr <= 0xFE9F) {
        // Object attribute memory (OAM)
        std.debug.panic("Address range not implemented yet: {X}\n", .{addr});
    } else if (0xFEA0 <= addr and addr <= 0xFEFF) {
        // Not Usable
        std.debug.panic("Not Usable address: {X}\n", .{addr});
    } else if (0xFF00 <= addr and addr <= 0xFF7F) {
        // I/O Registers
        std.debug.panic("Address range not implemented yet: {X}\n", .{addr});
    } else if (0xFF80 <= addr and addr <= 0xFFFE) {
        // High RAM (HRAM)
        std.debug.panic("Address range not implemented yet: {X}\n", .{addr});
    } else if (0xFFFF <= addr and addr <= 0xFFFF) {
        // Interrupt Enable register (IE)
        std.debug.panic("Address range not implemented yet: {X}\n", .{addr});
    }
    std.debug.panic("Invalid memory address: {X}\n", .{addr});
}
