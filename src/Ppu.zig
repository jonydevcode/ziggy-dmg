const Self = @This();
const util = @import("util.zig");

vram: [8192]u8 = @splat(0),
oam: [160]u8 = @splat(0),

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

// 1 M-cycle = 4 dots = 4 clock ticks
// Screen pixel dim = 160 x 144
// 1 frame = 154 scanlines
// Scanlines = 1 horizontal line = 456 dots
// 0-143   scanlines = visible
// 144-153 scanlines = VBlank

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

pub fn init() Self {
    return Self{
        .mode = .oam_scan_2,
    };
}

pub fn writeLcdc(self: *Self, byte: u8) void {
    const old_lcdc = self.lcdc;
    self.lcdc = Lcdc.fromByte(byte);

    if (old_lcdc.lcd_ppu_enabled and !self.lcdc.lcd_ppu_enabled) {
        // TODO: stop the PPU
        self.ly = 0;
    } else if (!old_lcdc.lcd_ppu_enabled and self.lcdc.lcd_ppu_enabled) {}
}

pub fn readLcdc(self: *Self) u8 {
    return self.lcdc.toByte();
}

pub fn writeStat(self: *Self, byte: u8) void {
    self.stat = Stat.fromByte(byte & 0b1111000);
}

pub fn readStat(self: *Self) u8 {
    const val = self.stat.toByte() & 0b1111000;
    return val | (@as(u8, @intFromBool(self.lyc == self.ly)) << 2) | @intFromEnum(self.mode);
}

/// Lines 0-143 are visible
pub fn stepVisibleLine(self: *Self) void {
    self.line_dot += 1;

    if (self.line_dot == 80) {
        self.mode = .drawing_3;
        return;
    }

    if (self.line_dot == 252) {
        self.mode = .hblank_0;
        return;
    }

    if (self.line_dot == 456) {
        self.line_dot = 0;
        self.ly += 1;

        if (self.ly == 144) {
            self.mode = .vblank_1;
        } else {
            self.mode = .oam_scan_2;
        }
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
