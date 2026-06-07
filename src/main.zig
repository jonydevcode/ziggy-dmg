const std = @import("std");
const sdl = @import("sdl");
const Renderer = @import("Renderer.zig");
const RGBA = @import("SdlGpu.zig").RGBA;
const config = @import("config.zig");
const Perf = @import("Perf.zig");
const rom = @import("rom.zig");
const Cpu = @import("Cpu.zig");
const input = @import("input.zig");
const Frametime = @import("Frametime.zig");
const Memory = @import("Memory.zig");
const Interrupts = @import("Interrupts.zig");
const Timers = @import("Timers.zig");

const display_enabled = false;

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
    var timers = Timers.init();
    var interrupts = Interrupts.init();
    var memory = Memory.init(rom_bytes, &interrupts, &timers);
    var cpu = Cpu.init(allocator, rng, &memory, &interrupts, &timers);
    defer cpu.deinit();

    // Gameboy Doctor log file
    var buf: [4096]u8 = undefined;
    var fixedwriter = std.Io.Writer.fixed(&buf);
    try fixedwriter.print("{s}.log.txt", .{std.fs.path.basename(args[1])});
    const log_path = fixedwriter.buffered();
    var log_file = try std.Io.Dir.cwd().createFile(init.io, log_path, .{ .truncate = true });
    defer log_file.close(init.io);
    var write_buf: [4096]u8 = undefined;
    var file_writer = log_file.writer(init.io, &write_buf);
    const writer = &file_writer.interface;

    // Gameboy Doctor setup (https://github.com/robert/gameboy-doctor)
    cpu.registers.a = 0x01;
    cpu.registers.f = 0xB0;
    cpu.registers.b = 0x00;
    cpu.registers.c = 0x13;
    cpu.registers.d = 0x00;
    cpu.registers.e = 0xD8;
    cpu.registers.h = 0x01;
    cpu.registers.l = 0x4D;
    cpu.registers.sp = 0xFFFE;
    cpu.registers.pc = 0x0100;
    try cpu.writeState(writer);

    // PPU
    var fake_screen = [_]u2{3} ** (config.screen.height * config.screen.width);
    const palette = config.palette;

    // renderer
    var frame_buf = [_]RGBA{Renderer.black} ** (config.screen.height * config.screen.width);
    var renderer: Renderer = if (display_enabled) try Renderer.init(
        config.window.width,
        config.window.height,
        config.window.pixel_size,
        config.screen.width,
        config.screen.height,
        &frame_buf,
    ) else undefined;
    defer if (display_enabled) {
        renderer.deinit();
    };

    var frametime = Frametime.init();
    var next_frame_time: u64 = sdl.SDL_GetTicksNS();
    var display_changed = false;
    var done = false;
    var perf = Perf{};
    var t_cycles: usize = 0;

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
        while (t_cycles <= config.cpu.cycles_per_frame) {
            const step_result = cpu.step();
            switch (step_result.new_state) {
                .running => {},
                .halted => done = true,
                .stopped => done = true,
            }

            display_changed = step_result.display_changed;
            t_cycles += step_result.t_cycles_used;

            timers.tick(t_cycles, cpu.interrupts);

            try cpu.writeState(writer);
        }
        // Save the balance for the next round
        t_cycles %= config.cpu.cycles_per_frame;
        perf.cpu_steps_ns += perf.lap();

        if (display_enabled) {
            // Present the screen at the target fps
            if (display_changed) {
                for (&fake_screen) |*p| {
                    p.* = rng.uintAtMost(u2, 3);
                }
                try renderer.paint(&fake_screen, &palette);
                display_changed = false;
                perf.renderer_ns += perf.lap();
            }
        }

        perf.frames += 1;

        // Deadline based timer
        next_frame_time += frametime.getNextFrameDurationNs();
        const sleep_ns = next_frame_time -| sdl.SDL_GetTicksNS();
        if (sleep_ns > 0)
            sdl.SDL_DelayNS(sleep_ns);
    }

    // print performance metrics
    std.debug.print("Per frame performance metrics in ns\n", .{});
    std.debug.print("Frames:     {d}\n", .{perf.frames});
    std.debug.print("PollEvent:  {d}\n", .{perf.poll_ns / perf.frames});
    std.debug.print("CPU steps:  {d}\n", .{perf.cpu_steps_ns / perf.frames});
    std.debug.print("Renderer:   {d}\n", .{perf.renderer_ns / perf.frames});
    // std.debug.print("Timers:     {d}\n", .{perf.timers_ns / perf.cycles});
    // std.debug.print("Audio tick: {d}\n", .{perf.audio_tick_ns / perf.cycles});
}
