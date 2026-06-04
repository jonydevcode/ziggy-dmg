#version 450

layout(location = 0) in vec2 in_uv;
layout(location = 0) out vec4 out_color;
layout(set = 2, binding = 0) uniform sampler2D emu_screen;

void main()
{
    out_color = texture(emu_screen, in_uv);
}
