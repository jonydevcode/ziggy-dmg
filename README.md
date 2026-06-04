# Ziggy-DMG - Game Boy Emulator in Zig

![No LLM Generation](https://img.shields.io/badge/LLM%20generation-none-brightgreen)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue)](./LICENSE)

An independent emulator written in Zig, compatible with Game Boy games. Uses SDL3 for display, inputs, and audio. Not affiliated with or endorsed by Nintendo. Game Boy is a trademark of Nintendo.

## AI Use Disclosure

The current contents of this repository were written without LLM/AI code generation. All AI usage in any form by contributors must be disclosed.

## Getting Started

### Dependencies

- Zig 0.16
- [castholm/SDL](https://github.com/castholm/SDL)

### Installing

```bash
zig build
```

### Executing program

```bash
zig build run -- rom_file.gb
```

## Acknowledgments

- [zig](https://codeberg.org/ziglang/zig)
- [castholm/SDL](https://github.com/castholm/SDL)
- [gbdev.io](https://gbdev.io/)
- [Blargg's test roms](https://github.com/retrio/gb-test-roms)

## License

Distributed under the MIT License. See [LICENSE](./LICENSE) for more information.
