const std = @import("std");
const sdl = @import("sdl");
const controls = @import("controls.zig");
const Button = controls.Button;
const State = controls.State;

pub const InputResult = union(enum) {
    none,
    quit,
    reset,
    game: Action,
};

pub const Action = struct {
    button: Button,
    state: State,
};

pub fn handleEvent(event: *sdl.SDL_Event) InputResult {
    switch (event.type) {
        sdl.SDL_EVENT_KEY_DOWN => return handleKeyEvent(event.key.scancode, .down),
        sdl.SDL_EVENT_KEY_UP => return handleKeyEvent(event.key.scancode, .up),
        else => {},
    }
    return .none;
}

pub fn handleKeyEvent(key_code: sdl.SDL_Scancode, state: State) InputResult {
    switch (key_code) {
        sdl.SDL_SCANCODE_ESCAPE => return .quit,
        sdl.SDL_SCANCODE_UP => return .{ .game = .{ .button = .up, .state = state } },
        sdl.SDL_SCANCODE_DOWN => return .{ .game = .{ .button = .down, .state = state } },
        sdl.SDL_SCANCODE_LEFT => return .{ .game = .{ .button = .left, .state = state } },
        sdl.SDL_SCANCODE_RIGHT => return .{ .game = .{ .button = .right, .state = state } },
        sdl.SDL_SCANCODE_X => return .{ .game = .{ .button = .a, .state = state } },
        sdl.SDL_SCANCODE_Z => return .{ .game = .{ .button = .b, .state = state } },
        sdl.SDL_SCANCODE_RETURN => return .{ .game = .{ .button = .start, .state = state } },
        sdl.SDL_SCANCODE_BACKSPACE => return .{ .game = .{ .button = .select, .state = state } },
        sdl.SDL_SCANCODE_F12 => return .reset,
        else => {},
    }
    return .none;
}
