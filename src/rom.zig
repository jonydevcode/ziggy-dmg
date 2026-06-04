const std = @import("std");

bytes: std.ArrayList(u8),

/// Reads all the bytes from the named file. On success, caller owns returned buffer.
pub fn getBytes(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
) ![]const u8 {
    if (std.fs.path.isAbsolute(path)) {
        const dir_name = std.fs.path.dirname(path) orelse return error.InvalidPath;
        const file_name = std.fs.path.basename(path);
        const dir = try std.Io.Dir.openDirAbsolute(io, dir_name, .{});
        return try std.Io.Dir.readFileAlloc(dir, io, file_name, allocator, .unlimited);
    } else {
        return try std.Io.Dir.readFileAlloc(std.Io.Dir.cwd(), io, path, allocator, .unlimited);
    }
}
