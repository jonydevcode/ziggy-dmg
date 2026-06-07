const std = @import("std");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

/// Concatenates two u8 to form a u16.
pub inline fn concatU16(lo: u8, hi: u8) u16 {
    return (@as(u16, hi) << 8) | lo;
}

/// Concatenates two u4 to form a u8.
pub inline fn concatU8(lo: u4, hi: u4) u8 {
    return (@as(u8, hi) << 4) | lo;
}

/// Generates a bit mask of all 1's except for 0 at index.
///
/// Example: u8ClearMask(3) -> 0b11110111
pub inline fn u8ClearMask(index: u3) u8 {
    return ~(@as(u8, 1) << index);
}

/// Generates a bit mask of all 0's except for 1 at index.
///
/// Example: u8SetMask(3) -> 0b00001000
pub inline fn u8SetMask(index: u3) u8 {
    return @as(u8, 1) << index;
}

/// Get the bits given a particular mask.
pub inline fn fromMask(comptime T: type, val: anytype, comptime mask: @TypeOf(val)) T {
    comptime {
        switch (@typeInfo(T)) {
            .int => {},
            else => @compileError("T must be an int"),
        }
        switch (@typeInfo(@TypeOf(val))) {
            .int => {},
            else => @compileError("val must be an int"),
        }
        if (mask == 0) {
            @compileError("Invalid mask of 0");
        }
        if (@bitSizeOf(T) != @popCount(mask)) {
            @compileError("T does not have the same size as the bits in mask");
        }
    }
    return @as(T, @intCast((val & mask) >> @ctz(mask)));
}

test "concatU16" {
    try expectEqual(@as(u16, 0xFFFF), concatU16(0xFF, 0xFF));
    try expectEqual(@as(u16, 0x0F0A), concatU16(0x0A, 0x0F));
}

test "concatU8" {
    try expectEqual(@as(u8, 0xFF), concatU8(0xF, 0xF));
    try expectEqual(@as(u8, 0xFA), concatU8(0xA, 0xF));
}

test "u8ClearMask" {
    try expectEqual(@as(u8, 0b01111111), u8ClearMask(7));
    try expectEqual(@as(u8, 0b11111110), u8ClearMask(0));
    try expectEqual(@as(u8, 0b11101111), u8ClearMask(4));
}

test "u8SetMask" {
    try expectEqual(@as(u8, 0b10000000), u8SetMask(7));
    try expectEqual(@as(u8, 0b00000001), u8SetMask(0));
    try expectEqual(@as(u8, 0b00010000), u8SetMask(4));
}

test "fromMask" {
    try expectEqual(0b101, fromMask(u3, @as(u8, 0b1010_1010), 0b0000_1110));
}
