const std = @import("std");
const util = @import("util.zig");

pub const rom_bank_size = 16_384; // in bytes
pub const ram_bank_Size = 8_192; // in bytes

pub const Mapper = union(enum) {
    rom_only: RomOnly,
    mbc1: Mbc1,

    pub fn read(self: *const Mapper, addr: u16, rom: []const u8, ram: []const u8) u8 {
        return switch (self.*) {
            .rom_only => RomOnly.read(addr, rom),
            .mbc1 => |*mbc1| mbc1.read(addr, rom, ram),
        };
    }

    pub fn write(self: *Mapper, addr: u16, val: u8, rom: []const u8, ram: []const u8) void {
        switch (self.*) {
            .rom_only => RomOnly.write(addr),
            .mbc1 => |*mbc1| mbc1.write(addr, val, rom, ram),
        }
    }
};

pub const RomOnly = struct {
    pub fn read(addr: u16, rom: []const u8) u8 {
        return rom[addr];
    }

    pub fn write(addr: u16) void {
        _ = addr;
        // std.debug.print("Attemping to write to read-only ROM address {X}\n", .{addr});
    }
};

pub const Mbc1 = struct {
    // https://gbdev.io/pandocs/MBC1.html
    const BankingMode = enum { simple, advanced };

    // registers
    ram_enabled: bool = false,
    rom_bank: u7 = 0,
    ram_bank: u2 = 0,
    banking_mode: BankingMode = .simple,

    pub fn read(self: *const Mbc1, addr: u16, rom: []const u8, ram: []const u8) u8 {
        if (0x0000 <= addr and addr <= 0x3FFF) {
            switch (self.banking_mode) {
                .simple => return rom[addr],
                .advanced => {
                    const bank: usize = (@as(u7, self.ram_bank) << 5) + self.rom_bank;
                    return rom[bank * rom_bank_size + addr];
                },
            }
        } else if (0x4000 <= addr and addr <= 0x7FFF) {
            const offset = addr - 0x4000;
            // If the main 5-bit ROM banking register is 0, read it as 1.
            const real_rom_bank = if (self.rom_bank == 0) 1 else self.rom_bank;
            return rom[@as(usize, real_rom_bank) * rom_bank_size + offset];
        } else if (0xA000 <= addr and addr <= 0xBFFF) {
            const offset = addr - 0x4000;
            return if (self.ram_enabled)
                ram[@as(usize, self.ram_bank) * rom_bank_size + offset]
            else
                0xFF;
        }
        std.debug.panic("Invalid Mbc1 read at addr {X}", .{addr});
    }

    pub fn write(self: *Mbc1, addr: u16, val: u8, rom: []const u8, ram: []const u8) void {
        _ = rom;
        _ = ram;
        if (0x0000 <= addr and addr <= 0x1FFF) {
            // 0000–1FFF — RAM Enable (Write Only)
            const lower4 = util.fromMask(u4, val, 0b1111);
            self.ram_enabled = if (lower4 == 0xA) true else false;
        } else if (0x2000 <= addr and addr <= 0x3FFF) {
            // 2000–3FFF — ROM Bank Number (Write Only)
            const lower5 = util.fromMask(u5, val, 0b11111);
            // TODO: implement the smaller ROM (<5 bits) masking logic
            self.rom_bank = lower5;
        } else if (0x4000 <= addr and addr <= 0x5FFF) {
            // 4000–5FFF — RAM Bank Number
            //      — or — Upper Bits of ROM Bank Number (Write Only)
            self.ram_bank = util.fromMask(u2, val, 0b11);
            switch (self.banking_mode) {
                .simple => {},
                .advanced => {
                    self.rom_bank = (@as(u7, self.ram_bank) << 5) +
                        util.fromMask(u5, self.rom_bank, 0b11111);
                },
            }
        } else if (0x6000 <= addr and addr <= 0x7FFF) {
            // 6000–7FFF — Banking Mode Select (Write Only)
            const lower1 = util.fromMask(u1, val, 0b1);
            self.banking_mode = if (lower1 == 0) .simple else .advanced;
        }
    }
};
