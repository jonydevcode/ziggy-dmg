const Self = @This();
const std = @import("std");
const sdl = @import("sdl");
const sdlx = @import("sdlx.zig");

pub const RGBA = packed struct(u32) { r: u8, g: u8, b: u8, a: u8 };

const MSL_VERT_PATH = "shaders/shader.vert.msl";
const MSL_FRAG_PATH = "shaders/shader.frag.msl";
const MSL_VERT_ENTRY = "FullscreenVS";
const MSL_FRAG_ENTRY = "EmuFS";
const SPIRV_VERT_PATH = "shaders/shader.vert.spv";
const SPIRV_FRAG_PATH = "shaders/shader.frag.spv";
const SPIRV_VERT_ENTRY = "main";
const SPIRV_FRAG_ENTRY = "main";
const DXIL_VERT_PATH = "shaders/shader.vert.dxil";
const DXIL_FRAG_PATH = "shaders/shader.frag.dxil";
const DXIL_VERT_ENTRY = "main";
const DXIL_FRAG_ENTRY = "main";

fn loadShader(
    gpu: *sdl.SDL_GPUDevice,
    path: [:0]const u8,
    entry_point: [:0]const u8,
    format: sdl.SDL_GPUShaderFormat,
    stage: sdl.SDL_GPUShaderStage,
    samplers: u32,
) !*sdl.SDL_GPUShader {
    var size: usize = 0;
    const raw = sdl.SDL_LoadFile(path, &size) orelse return error.ShaderLoadFileFailed;
    defer sdl.SDL_free(raw);

    const code: []const u8 = @as([*]const u8, @ptrCast(raw))[0..size];

    const create_info = sdl.SDL_GPUShaderCreateInfo{
        .code = code.ptr,
        .code_size = code.len,
        .entrypoint = entry_point,
        .format = format,
        .stage = stage,
        .num_samplers = samplers,
    };
    const shader = sdl.SDL_CreateGPUShader(gpu, &create_info) orelse return error.CreateGPUShaderFailed;
    return shader;
}

fn logBasicInfo(gpu: *sdl.SDL_GPUDevice) !void {
    const gpu_driver = sdl.SDL_GetGPUDeviceDriver(gpu) orelse return sdlx.die("SDL_GetGPUDeviceDriver");
    std.debug.print("SDL_GPU backend: {s}\n", .{std.mem.span(gpu_driver)});

    std.debug.print("Supported shader formats:", .{});
    const supported_formats = sdl.SDL_GetGPUShaderFormats(gpu);
    // vulkan
    if (supported_formats & sdl.SDL_GPU_SHADERFORMAT_SPIRV != 0) {
        std.debug.print(" SPIR-V", .{});
    }
    // metal
    if (supported_formats & sdl.SDL_GPU_SHADERFORMAT_MSL != 0) {
        std.debug.print(" MSL", .{});
    }
    // d3d12 (sm 6.0)
    if (supported_formats & sdl.SDL_GPU_SHADERFORMAT_DXIL != 0) {
        std.debug.print(" DXIL", .{});
    }
    // d3d12 (sm 5.1)
    if (supported_formats & sdl.SDL_GPU_SHADERFORMAT_DXBC != 0) {
        std.debug.print(" DXBC", .{});
    }
    std.debug.print("\n", .{});
}

window: *sdl.SDL_Window,
gpu: *sdl.SDL_GPUDevice,
frame_tex: *sdl.SDL_GPUTexture,
upload: *sdl.SDL_GPUTransferBuffer,
nearest: *sdl.SDL_GPUSampler,
pipeline: *sdl.SDL_GPUGraphicsPipeline,
framebuffer: []RGBA,
frame_width: u32,
frame_height: u32,
vertex_shader: *sdl.SDL_GPUShader,
fragment_shader: *sdl.SDL_GPUShader,
is_framebuffer_dirty: bool = false,

pub fn init(
    window: *sdl.SDL_Window,
    comptime frame_width: u32,
    comptime frame_height: u32,
    framebuffer: *[frame_width * frame_height]RGBA,
) !Self {
    const gpu = sdl.SDL_CreateGPUDevice(
        sdl.SDL_GPU_SHADERFORMAT_SPIRV | sdl.SDL_GPU_SHADERFORMAT_MSL | sdl.SDL_GPU_SHADERFORMAT_DXIL,
        false, // debug flag
        null,
    ) orelse return sdlx.die("SDL_CreateGPUDevice");
    try logBasicInfo(gpu);

    try sdlx.check(
        "SDL_ClaimWindowForGPUDevice",
        sdl.SDL_ClaimWindowForGPUDevice(gpu, window),
    );

    const present_mode: sdl.SDL_GPUPresentMode = if (sdl.SDL_WindowSupportsGPUPresentMode(gpu, window, sdl.SDL_GPU_PRESENTMODE_MAILBOX))
        sdl.SDL_GPU_PRESENTMODE_MAILBOX
    else if (sdl.SDL_WindowSupportsGPUPresentMode(gpu, window, sdl.SDL_GPU_PRESENTMODE_IMMEDIATE))
        sdl.SDL_GPU_PRESENTMODE_IMMEDIATE
    else
        sdl.SDL_GPU_PRESENTMODE_VSYNC;

    try sdlx.check("", sdl.SDL_SetGPUSwapchainParameters(
        gpu,
        window,
        sdl.SDL_GPU_SWAPCHAINCOMPOSITION_SDR,
        present_mode,
    ));

    const ShaderConfig = struct {
        shader_format: sdl.SDL_GPUShaderFormat,
        vertex_path: [:0]const u8,
        fragment_path: [:0]const u8,
        vertex_entry: [:0]const u8,
        fragment_entry: [:0]const u8,
    };

    const supported_formats = sdl.SDL_GetGPUShaderFormats(gpu);
    const shader_config: ShaderConfig = if (supported_formats & sdl.SDL_GPU_SHADERFORMAT_MSL != 0)
        ShaderConfig{
            .shader_format = sdl.SDL_GPU_SHADERFORMAT_MSL,
            .vertex_path = MSL_VERT_PATH,
            .vertex_entry = MSL_VERT_ENTRY,
            .fragment_path = MSL_FRAG_PATH,
            .fragment_entry = MSL_FRAG_ENTRY,
        }
    else if (supported_formats & sdl.SDL_GPU_SHADERFORMAT_SPIRV != 0)
        ShaderConfig{
            .shader_format = sdl.SDL_GPU_SHADERFORMAT_SPIRV,
            .vertex_path = SPIRV_VERT_PATH,
            .fragment_path = SPIRV_FRAG_PATH,
            .vertex_entry = SPIRV_VERT_ENTRY,
            .fragment_entry = SPIRV_FRAG_ENTRY,
        }
    else if (supported_formats & sdl.SDL_GPU_SHADERFORMAT_DXIL != 0)
        ShaderConfig{
            .shader_format = sdl.SDL_GPU_SHADERFORMAT_DXIL,
            .vertex_path = DXIL_VERT_PATH,
            .fragment_path = DXIL_FRAG_PATH,
            .vertex_entry = DXIL_VERT_ENTRY,
            .fragment_entry = DXIL_FRAG_ENTRY,
        }
    else
        return error.NoSupportedShaderFormat;

    const frame_tex = sdl.SDL_CreateGPUTexture(
        gpu,
        &sdl.SDL_GPUTextureCreateInfo{
            .type = sdl.SDL_GPU_TEXTURETYPE_2D,
            .format = sdl.SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM,
            .usage = sdl.SDL_GPU_TEXTUREUSAGE_SAMPLER,
            .width = frame_width,
            .height = frame_height,
            .layer_count_or_depth = 1,
            .num_levels = 1,
            .sample_count = sdl.SDL_GPU_SAMPLECOUNT_1,
        },
    ) orelse return sdlx.die("SDL_CreateGPUTexture");

    const upload = sdl.SDL_CreateGPUTransferBuffer(
        gpu,
        &sdl.SDL_GPUTransferBufferCreateInfo{
            .usage = sdl.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD,
            .size = frame_width * frame_height * @sizeOf(RGBA),
        },
    ) orelse return sdlx.die("SDL_CreateGPUTransferBuffer");

    const nearest = sdl.SDL_CreateGPUSampler(
        gpu,
        &sdl.SDL_GPUSamplerCreateInfo{
            .min_filter = sdl.SDL_GPU_FILTER_NEAREST,
            .mag_filter = sdl.SDL_GPU_FILTER_NEAREST,
            .mipmap_mode = sdl.SDL_GPU_SAMPLERMIPMAPMODE_NEAREST,
            .address_mode_u = sdl.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE,
            .address_mode_v = sdl.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE,
            .address_mode_w = sdl.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE,
        },
    ) orelse return sdlx.die("SDL_CreateGPUSampler");

    const vs = try loadShader(
        gpu,
        shader_config.vertex_path,
        shader_config.vertex_entry,
        shader_config.shader_format,
        sdl.SDL_GPU_SHADERSTAGE_VERTEX,
        0,
    );
    const fs = try loadShader(
        gpu,
        shader_config.fragment_path,
        shader_config.fragment_entry,
        shader_config.shader_format,
        sdl.SDL_GPU_SHADERSTAGE_FRAGMENT,
        1,
    );

    // Create the graphics pipeline
    const color_target = sdl.SDL_GPUColorTargetDescription{
        .format = sdl.SDL_GetGPUSwapchainTextureFormat(gpu, window),
    };
    const pipeline = sdl.SDL_CreateGPUGraphicsPipeline(
        gpu,
        &sdl.SDL_GPUGraphicsPipelineCreateInfo{
            .vertex_shader = vs,
            .fragment_shader = fs,
            .primitive_type = sdl.SDL_GPU_PRIMITIVETYPE_TRIANGLELIST,
            .rasterizer_state = .{
                .fill_mode = sdl.SDL_GPU_FILLMODE_FILL,
                .cull_mode = sdl.SDL_GPU_CULLMODE_NONE,
                .front_face = sdl.SDL_GPU_FRONTFACE_COUNTER_CLOCKWISE,
            },
            .target_info = .{
                .color_target_descriptions = &color_target,
                .num_color_targets = 1,
            },
        },
    ) orelse return sdlx.die("SDL_CreateGPUGraphicsPipeline");

    return Self{
        .window = window,
        .gpu = gpu,
        .frame_tex = frame_tex,
        .upload = upload,
        .nearest = nearest,
        .pipeline = pipeline,
        .framebuffer = framebuffer[0..],
        .frame_width = frame_width,
        .frame_height = frame_height,
        .fragment_shader = fs,
        .vertex_shader = vs,
    };
}

pub fn deinit(self: *Self) void {
    sdl.SDL_ReleaseGPUGraphicsPipeline(self.gpu, self.pipeline);
    sdl.SDL_ReleaseGPUShader(self.gpu, self.fragment_shader);
    sdl.SDL_ReleaseGPUShader(self.gpu, self.vertex_shader);
    sdl.SDL_ReleaseGPUSampler(self.gpu, self.nearest);
    sdl.SDL_ReleaseGPUTransferBuffer(self.gpu, self.upload);
    sdl.SDL_ReleaseGPUTexture(self.gpu, self.frame_tex);
    sdl.SDL_ReleaseWindowFromGPUDevice(self.gpu, self.window);
    sdl.SDL_DestroyGPUDevice(self.gpu);
}

pub fn markFramebufferDirty(self: *Self) void {
    self.is_framebuffer_dirty = true;
}

pub fn present(self: *Self) !void {
    // Command buffer is like a GPU "to-do list".
    // First, we "write down" the commands on this to-do list.
    const cmd = sdl.SDL_AcquireGPUCommandBuffer(self.gpu) orelse return sdlx.die("SDL_AcquireGPUCommandBuffer");

    if (self.is_framebuffer_dirty) {
        // Copy the 64x32 internal buffer to an upload buffer.
        // `upload` is SDL_CreateGPUTransferBuffer created earlier.
        const dst = sdl.SDL_MapGPUTransferBuffer(self.gpu, self.upload, true) orelse return sdlx.die("SDL_MapGPUTransferBuffer");
        _ = sdl.SDL_memcpy(dst, self.framebuffer.ptr, self.framebuffer.len * @sizeOf(RGBA));
        sdl.SDL_UnmapGPUTransferBuffer(self.gpu, self.upload);

        // Record a GPU copy operation into the command buffer
        // i.e. copy the image bytes from `upload` into `frame_tex`.
        const copy = sdl.SDL_BeginGPUCopyPass(cmd);
        sdl.SDL_UploadToGPUTexture(
            copy,
            &sdl.SDL_GPUTextureTransferInfo{
                .transfer_buffer = self.upload,
                .pixels_per_row = self.frame_width,
                .rows_per_layer = self.frame_height,
            },
            &sdl.SDL_GPUTextureRegion{
                .texture = self.frame_tex,
                .w = self.frame_width,
                .h = self.frame_height,
                .d = 1,
            },
            true,
        );
        sdl.SDL_EndGPUCopyPass(copy);
        self.is_framebuffer_dirty = false;
    }

    // Acquire the next window image to draw into, also known as the
    // `swapchain` texture. This is like the next blank page that will become
    // visible in the window
    var maybe_swapchain: ?*sdl.SDL_GPUTexture = null;
    var out_w: u32 = 0;
    var out_h: u32 = 0;
    try sdlx.check("SDL_AcquireGPUSwapchainTexture", sdl.SDL_AcquireGPUSwapchainTexture(
        cmd,
        self.window,
        &maybe_swapchain,
        &out_w,
        &out_h,
    ));
    if (maybe_swapchain) |swapchain| {
        // If a window image was acquired, record the draw commands.
        const pass = sdl.SDL_BeginGPURenderPass(
            cmd,
            &sdl.SDL_GPUColorTargetInfo{
                .texture = swapchain,
                .clear_color = sdl.SDL_FColor{ .r = 0, .g = 0, .b = 0, .a = 1 },
                .load_op = sdl.SDL_GPU_LOADOP_CLEAR,
                .store_op = sdl.SDL_GPU_STOREOP_STORE,
            },
            1,
            null,
        );
        sdl.SDL_BindGPUGraphicsPipeline(pass, self.pipeline);
        sdl.SDL_BindGPUFragmentSamplers(
            pass,
            0,
            &sdl.SDL_GPUTextureSamplerBinding{
                .texture = self.frame_tex,
                .sampler = self.nearest,
            },
            1,
        );
        sdl.SDL_DrawGPUPrimitives(pass, 6, 1, 0, 0);
        sdl.SDL_EndGPURenderPass(pass);
    }

    // Submit the recorded GPU commands. After this, the CPU continues while the GPU
    // works asynchronously.
    sdlx.check("SDL_SubmitGPUCommandBuffer", sdl.SDL_SubmitGPUCommandBuffer(cmd)) catch {};
}

pub fn waitForGPUIdle(self: *Self) !void {
    try sdlx.check("SDL_WaitForGPUIdle", sdl.SDL_WaitForGPUIdle(self.gpu));
}
