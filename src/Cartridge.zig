const Self = @This();
const std = @import("std");
const Dir = std.Io.Dir;
const mapper = @import("mapper.zig");

const rom_bank_size = mapper.rom_bank_size;
const ram_bank_size = mapper.ram_bank_Size;

allocator: std.mem.Allocator,
rom: []const u8,
ram: []u8,
map: mapper.Mapper,
rom_size: usize,
ram_size: usize,

pub fn init(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
) !Self {
    const rom = if (std.fs.path.isAbsolute(path)) blk: {
        const dir_name = std.fs.path.dirname(path) orelse return error.InvalidPath;
        const file_name = std.fs.path.basename(path);
        const dir = try Dir.openDirAbsolute(io, dir_name, .{});
        break :blk try Dir.readFileAlloc(dir, io, file_name, allocator, .unlimited);
    } else try Dir.readFileAlloc(Dir.cwd(), io, path, allocator, .unlimited);

    const map = getMapper(rom[0x147]);
    const rom_size = getRomSize(rom[0x148]);
    const ram_size = getRamSize(rom[0x149]);

    // std.debug.print("Detected\nrom_size = {d}\nram_size = {d}\n", .{ rom_size, ram_size });

    return Self{
        .allocator = allocator,
        .rom = rom,
        .map = map,
        .ram = try allocator.alloc(u8, ram_size),
        .rom_size = rom_size,
        .ram_size = ram_size,
    };
}

fn getMapper(byte: u8) mapper.Mapper {
    return switch (byte) {
        0x0 => mapper.Mapper{ .rom_only = .{} },
        0x1, 0x2, 0x3 => mapper.Mapper{ .mbc1 = .{} },
        // 0x5, 0x6 => return .mbc2,
        // 0x0F, 0x10, 0x11, 0x12, 0x13 => return .mbc3,
        // 0x19, 0x1A, 0x1B, 0x1C, 0x1D, 0x1E => return .mbc4,
        // 0x20 => return .mbc6,
        // 0x22 => return .mbc7,
        else => mapper.Mapper{ .rom_only = .{} },
    };
}

fn getRomSize(byte: u8) usize {
    return switch (byte) {
        0x00 => 2 * rom_bank_size,
        0x01 => 4 * rom_bank_size,
        0x02 => 8 * rom_bank_size,
        0x03 => 16 * rom_bank_size,
        0x04 => 32 * rom_bank_size,
        0x05 => 64 * rom_bank_size,
        0x06 => 128 * rom_bank_size,
        0x07 => 256 * rom_bank_size,
        0x08 => 512 * rom_bank_size,
        0x52 => 72 * rom_bank_size,
        0x53 => 80 * rom_bank_size,
        0x54 => 96 * rom_bank_size,
        else => std.debug.panic("Invalid 0x148 value: {X}", .{byte}),
    };
}

fn getRamSize(byte: u8) usize {
    return switch (byte) {
        0x0 => 0,
        0x2 => 1 * ram_bank_size,
        0x3 => 4 * ram_bank_size,
        0x4 => 16 * ram_bank_size,
        0x5 => 8 * ram_bank_size,
        else => std.debug.panic("Invalid 0x149 value: {X}", .{byte}),
    };
}

pub fn deinit(self: *Self) void {
    self.allocator.free(self.rom);
}

pub fn read(self: *Self, addr: u16) u8 {
    return self.map.read(addr, self.rom, self.ram);
}

pub fn write(self: *Self, addr: u16, val: u8) void {
    self.map.write(addr, val, self.rom, self.ram);
}
