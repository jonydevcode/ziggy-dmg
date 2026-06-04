const std = @import("std");
const sdl = @import("sdl");

pub const SdlError = error{
    SdlFailure,
};

/// Utility to help make good use of SDL_GetError()
pub fn check(comptime name: []const u8, ok: bool) SdlError!void {
    if (!ok) {
        std.log.err("{s} failed: {s}", .{ name, std.mem.span(sdl.SDL_GetError()) });
        return error.SdlFailure;
    }
}

pub fn die(comptime name: []const u8) SdlError {
    std.log.err("{s} failed: {s}", .{ name, std.mem.span(sdl.SDL_GetError()) });
    return error.SdlFailure;
}

pub fn printVersionToDebug() void {
    const version = sdl.SDL_GetVersion();
    const major = sdl.SDL_VERSIONNUM_MAJOR(version);
    const minor = sdl.SDL_VERSIONNUM_MINOR(version);
    const micro = sdl.SDL_VERSIONNUM_MICRO(version);
    std.debug.print("SDL version: {d}.{d}.{d}\n", .{ major, minor, micro });
    std.debug.print("SDL revision: {s}\n", .{sdl.SDL_GetRevision()});
}
