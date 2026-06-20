const Self = @This();
const util = @import("util.zig");
const std = @import("std");
const Interrupts = @import("Interrupts.zig");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

// 1 M-cycle = 4 dots = 4 clock ticks
// Screen pixel dim = 160 x 144
// 1 frame = 154 scanlines
// Scanlines = 1 horizontal line = 456 dots
// 0-143   scanlines = visible
// 144-153 scanlines = VBlank

interrupts: *Interrupts,

vram: [8192]u8 = @splat(0),
oam: [160]u8 = @splat(0),
framebuf: [160 * 144]u8 = @splat(0),

// Registers (addr $FF40 through $FF4B)
lcdc: Lcdc = Lcdc.fromByte(0), // LCD control
stat: Stat = Stat.fromByte(0), // LCD status and STAT interrupt
scy: u8 = 0, // Background scroll Y
scx: u8 = 0, // Background scroll X
ly: u8 = 0, // Current scanline number (0-153)
lyc: u8 = 0, // LY compare value
dma: u8 = 0, // OAM DMA start register
bgp: u8 = 0, // BG and Window palette
obp0: u8 = 0, // object palette 0
obp1: u8 = 0, // object palette 1
wy: u8 = 0, // window y position
wx: u8 = 0, // window x position plus 7

mode: PpuMode,
line_dot: u16 = 0, // position within the current scanline (0-455)
frame_ready: bool = false,
prev_stat_line: bool = false,

pub const PpuMode = enum(u2) {
    hblank_0 = 0, // also reports this when PPU is disable
    vblank_1 = 1,
    oam_scan_2 = 2,
    drawing_3 = 3,
};

pub const Lcdc = packed struct(u8) {
    bg_window_enable: bool = false, // bit 0
    obj_enable: bool = false,
    obj_size: ObjSize = .size_8x8,
    bg_tile_map_area: TileMapArea = .mem_9800_9bff,
    bg_tile_data_area: TileDataArea = .mem_8800_97ff,
    window_enable: bool = false,
    window_tile_map_area: TileMapArea = .mem_9800_9bff,
    lcd_ppu_enabled: bool = false, // bit 7

    pub const ObjSize = enum(u1) {
        size_8x8 = 0,
        size_8x16 = 1,

        pub fn height(self: ObjSize) u8 {
            return switch (self) {
                .size_8x8 => 8,
                .size_8x16 => 16,
            };
        }
    };
    pub const TileMapArea = enum(u1) {
        mem_9800_9bff = 0,
        mem_9c00_9fff = 1,

        pub fn start(self: TileMapArea) u16 {
            return switch (self) {
                .mem_9800_9bff => 0x9800,
                .mem_9c00_9fff => 0x9c00,
            };
        }
    };
    pub const TileDataArea = enum(u1) {
        mem_8800_97ff = 0,
        mem_8000_8fff = 1,

        pub fn start(self: TileDataArea) u16 {
            return switch (self) {
                .mem_8800_97ff => 0x8800,
                .mem_8000_8fff => 0x8000,
            };
        }
    };

    pub fn fromByte(byte: u8) Lcdc {
        return @bitCast(byte);
    }

    pub fn toByte(self: Lcdc) u8 {
        return @bitCast(self);
    }
};

pub const Stat = packed struct(u8) {
    mode: PpuMode = .hblank_0, // bits 0-1
    lyc_eq_ly: bool = false,
    mode0_select: bool = false,
    mode1_select: bool = false,
    mode2_select: bool = false,
    lyc_select: bool = false,
    unused: u1 = 0,

    pub fn fromByte(byte: u8) Stat {
        return @bitCast(byte);
    }

    pub fn toByte(self: Stat) u8 {
        return @bitCast(self);
    }
};

pub fn init(interrupts: *Interrupts) Self {
    return Self{
        .mode = .oam_scan_2,
        .interrupts = interrupts,
    };
}

pub fn writeLcdc(self: *Self, byte: u8) void {
    const old_lcdc = self.lcdc;
    const now_lcdc = Lcdc.fromByte(byte);
    self.lcdc = now_lcdc;

    if (old_lcdc.lcd_ppu_enabled and !now_lcdc.lcd_ppu_enabled) {
        self.disableLcd();
    } else if (!old_lcdc.lcd_ppu_enabled and now_lcdc.lcd_ppu_enabled) {
        self.enableLcd();
    }
}

pub fn readLcdc(self: *Self) u8 {
    return self.lcdc.toByte();
}

pub fn writeStat(self: *Self, byte: u8) void {
    self.stat = Stat.fromByte(byte & 0b1111000);
    self.checkStatInterrupt();
}

pub fn readStat(self: *Self) u8 {
    const stat_interrupt_cond = self.stat.toByte() & 0b1111000;
    const lyc_eq_ly = @intFromBool(self.lyc == self.ly);
    const ppu_mode = @intFromEnum(self.mode);
    return stat_interrupt_cond | (@as(u8, lyc_eq_ly) << 2) | ppu_mode;
}

/// See here for the dots and modes: https://gbdev.io/pandocs/Rendering.html#ppu-modes
/// Lines 0-143 are visible
pub fn stepVisibleLine(self: *Self) void {
    self.line_dot += 1;

    if (self.line_dot == 80) {
        self.setMode(.drawing_3);
        return;
    }

    if (self.line_dot == 252) {
        self.renderBlankLine();
        self.setMode(.hblank_0);
        return;
    }

    if (self.line_dot == 456) {
        self.line_dot = 0;
        self.ly += 1;

        if (self.ly == 144) {
            self.setMode(.vblank_1);
            self.interrupts.request(.vblank);
        } else {
            self.setMode(.oam_scan_2);
        }

        // Part of the STAT line includes checking ly==lyc, so check here
        // since self.ly is incremented in this block
        self.checkStatInterrupt();
    }
}

/// Lines 144-153 are VBlank
pub fn stepVblankLine(self: *Self) void {
    self.line_dot += 1;
    if (self.line_dot == 456) {
        self.line_dot = 0;
        self.ly += 1;

        if (self.ly == 154) {
            self.ly = 0;
            self.mode = .oam_scan_2;
            self.frame_ready = true;
        }
    }
}

/// Steps the PPU for 1 dot. There are 4 dots in 1 M-cycle.
pub fn stepDot(self: *Self) void {
    if (!self.lcdc.lcd_ppu_enabled) {
        return;
    }

    if (self.ly < 144) {
        self.stepVisibleLine();
    } else {
        self.stepVblankLine();
    }
}

/// Steps the PPU for 1 M-cycle
pub fn step(self: *Self) void {
    for (0..4) |_| {
        self.stepDot();
    }
}

pub fn disableLcd(self: *Self) void {
    self.ly = 0;
    self.line_dot = 0;
    self.mode = .hblank_0;
    self.frame_ready = false;
}

pub fn enableLcd(self: *Self) void {
    self.ly = 0;
    self.line_dot = 0;
    self.mode = .oam_scan_2;
    self.frame_ready = false;
}

pub fn isVramAccessible(self: *Self) bool {
    // As long as the PPU is disabled, VRAM is accessible
    if (!self.lcdc.lcd_ppu_enabled) return true;
    // If the PPU is enabled, then check that it's not mode 3
    return self.mode != .drawing_3;
}

pub fn isOamAccessible(self: *Self) bool {
    // As long as the PPU is disabled, OAM is accessible
    if (!self.lcdc.lcd_ppu_enabled) return true;
    // If the PPU is enabled, then check that it's not mode 2 or 3
    return self.mode != .oam_scan_2 and self.mode != .drawing_3;
}

pub fn readVram(self: *Self, addr: u16) u8 {
    if (!self.isVramAccessible()) return 0xFF;
    return self.vram[addr - 0x8000];
}

pub fn writeVram(self: *Self, addr: u16, val: u8) void {
    if (!self.isVramAccessible()) return;
    self.vram[addr - 0x8000] = val;
}

pub fn readOam(self: *Self, addr: u16) u8 {
    if (!self.isOamAccessible()) return 0xFF;
    return self.oam[addr - 0xFE00];
}

pub fn writeOam(self: *Self, addr: u16, val: u8) void {
    if (!self.isOamAccessible()) return;
    self.oam[addr - 0xFE00] = val;
}

pub fn readLy(self: *Self) u8 {
    return self.ly;
}

pub fn readLyc(self: *Self) u8 {
    return self.lyc;
}

pub fn writeLyc(self: *Self, val: u8) void {
    self.lyc = val;
    self.checkStatInterrupt();
}

/// The various STAT interrupt sources (modes 0-2 and LYC=LY) have their state (inactive=low and active=high) logically ORed into a shared “STAT interrupt line” if their respective enable bit is turned on. A STAT interrupt will be triggered by a rising edge (transition from low to high) on the STAT interrupt line.
/// More details: https://gbdev.io/pandocs/Interrupt_Sources.html#int-48--stat-interrupt
pub fn getStatLine(self: *Self) bool {
    const lyc_eq_ly = self.ly == self.lyc and self.stat.lyc_eq_ly;
    const mode0 = self.mode == .hblank_0 and self.stat.mode0_select;
    const mode1 = self.mode == .vblank_1 and self.stat.mode1_select;
    const mode2 = self.mode == .oam_scan_2 and self.stat.mode2_select;
    return lyc_eq_ly or mode0 or mode1 or mode2;
}
/// Requests an interrupt on a rising edge on the STAT line
/// Call it:
/// - after mode changes
/// - after LY changes
/// - after LYC changes
/// - after STAT enable bits are written
/// - after LCD enable state changes
pub fn checkStatInterrupt(self: *Self) void {
    const now_stat_line = self.getStatLine();
    if (!self.prev_stat_line and now_stat_line) {
        self.interrupts.request(.lcd);
    }
    self.prev_stat_line = now_stat_line;
}

fn setMode(self: *Self, mode: PpuMode) void {
    self.mode = mode;
    self.checkStatInterrupt();
}

fn renderBlankLine(self: *Self) void {
    if (self.ly >= 144) return; // not visible
    for (0..160) |x| {
        self.framebuf[self.ly * 160 + x] = 0;
    }
}
test "Stat tests" {
    var ppu = Self.init();
    ppu.writeLcdc(0b10000000); // trigger the falling edge on ppu enable
    ppu.writeLcdc(0);
    try expectEqual(ppu.ly, 0);
    try expectEqual(ppu.line_dot, 0);
    try expect(@as(PpuMode, @enumFromInt(ppu.readStat() & 0b11)) == .hblank_0);

    ppu.writeLcdc(0x80);
    try expect(ppu.ly == 0);
    try expect(ppu.line_dot == 0);
    try expect(@as(PpuMode, @enumFromInt(ppu.readStat() & 0b11)) == .oam_scan_2);

    ppu.writeLy(10);
    ppu.writeLyc(10);
    try expect((ppu.readStat() & 0b100) != 0);
    ppu.writeLyc(11);
    try expect((ppu.readStat() & 0b100) == 0);
}
