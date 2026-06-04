const std = @import("std");
const sdl = @import("sdl");
const Renderer = @import("Renderer.zig");
const RGBA = @import("SdlGpu.zig").RGBA;
const config = @import("config.zig");
const Perf = @import("Perf.zig");
const rom = @import("rom.zig");
const Cpu = @import("Cpu.zig");
const input = @import("input.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var stderr_buf: [4096]u8 = undefined;
    var stderr = std.Io.File.stderr().writer(init.io, &stderr_buf);

    // cli args
    const args = try init.minimal.args.toSlice(allocator);
    defer allocator.free(args);
    if (args.len <= 1) {
        try stderr.interface.print("Usage: {s} ROM_FILE\n", .{std.fs.path.basename(args[0])});
        try stderr.interface.flush();
        return;
    }

    // random
    const seed: u64 = 12345;
    // Uncomment this line to make it truly random:
    // try init.io.randomSecure(std.mem.asBytes(&seed));
    var prng: std.Random.DefaultPrng = .init(seed);
    const rng = prng.random();

    // get the rom bytes
    const rom_path = args[1];
    const rom_bytes = rom.getBytes(init.io, allocator, rom_path) catch |err| switch (err) {
        error.FileNotFound => {
            try stderr.interface.print("File not found: {s}\n", .{std.fs.path.basename(args[1])});
            try stderr.interface.flush();
            return;
        },
        else => return err,
    };
    defer allocator.free(rom_bytes);

    // CPU
    var cpu = Cpu.init(allocator, rng, rom_bytes);
    defer cpu.deinit();

    // PPU
    const fake_screen = [_]u2{3} ** (config.screen.height * config.screen.width);
    const palette = config.palette;

    // renderer
    var frame_buf = [_]RGBA{Renderer.black} ** (config.screen.height * config.screen.width);
    var renderer = try Renderer.init(
        config.window.width,
        config.window.height,
        config.window.pixel_size,
        config.screen.width,
        config.screen.height,
        &frame_buf,
    );
    defer renderer.deinit();

    // audio
    // var audio = try Audio8.init();

    // const cpu_ns_per_cycle = 1_000_000_000 / cpu_hz;
    // const timer_ns_per_cycle = 1_000_000_000 / timer_hz;
    // var cpu_accumulator: u64 = 0;
    // var timer_accumulator: u64 = 0;
    // var fps_accumulator: u64 = 0;
    var next_frame_time: u64 = sdl.SDL_GetTicksNS();

    var display_changed = false;

    var done = false;

    var perf = Perf{};

    // Broad strategy:
    // 1. Step the CPU 70,224 times
    // 2. Render one frame
    // 3. Target config.window.target_fps (~59.73 fps) with a deadline delay
    while (!done) {
        perf.start();

        // Poll events
        var event: sdl.SDL_Event = undefined;
        while (sdl.SDL_PollEvent(&event)) {
            switch (event.type) {
                sdl.SDL_EVENT_QUIT => done = true,
                sdl.SDL_EVENT_KEY_DOWN, sdl.SDL_EVENT_KEY_UP => {
                    switch (input.handleEvent(&event)) {
                        .reset => {},
                        .quit => done = true,
                        .game => |action| {
                            _ = action;
                            // chip8.setKey(action.key, action.state);
                        },
                        .none => {},
                    }
                },
                else => {},
            }
        }

        perf.poll_ns += perf.lap();

        // Step the CPU
        var cycles: usize = 0;
        // TODO: Change step() to return the number of cycles used by that instruction
        while (cycles <= config.cpu.cycles_per_frame) : (cycles += 1) {
            const step_result = try cpu.step();
            perf.cpu_step_ns += perf.lap();
            display_changed = step_result.display_changed;
        }

        // Present the screen at the target fps
        if (display_changed) {
            try renderer.paint(&fake_screen, &palette);
            display_changed = false;
            perf.renderer_ns += perf.lap();
        }

        perf.cycles += 1;

        // Deadline based timer
        next_frame_time += config.window.target_frame_time_ns;
        const sleep_ns = next_frame_time -| sdl.SDL_GetTicksNS();
        if (sleep_ns > 0)
            sdl.SDL_DelayNS(sleep_ns);
    }

    // print performance metrics
    std.debug.print("Per cycle performance metrics in ns\n", .{});
    std.debug.print("Cycles:     {d}\n", .{perf.cycles});
    std.debug.print("PollEvent:  {d}\n", .{perf.poll_ns / perf.cycles});
    std.debug.print("CPU step:   {d}\n", .{perf.cpu_step_ns / perf.cycles});
    std.debug.print("Renderer:   {d}\n", .{perf.renderer_ns / perf.cycles});
    // std.debug.print("Timers:     {d}\n", .{perf.timers_ns / perf.cycles});
    // std.debug.print("Audio tick: {d}\n", .{perf.audio_tick_ns / perf.cycles});
}
