# Ziggy-DMG - Game Boy Emulator in Zig

![No LLM Generation](https://img.shields.io/badge/LLM%20generation-none-brightgreen)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue)](./LICENSE)

An independent emulator written in Zig, compatible with Game Boy games. Uses SDL3 for display, inputs, and audio. Not affiliated with or endorsed by Nintendo. Game Boy is a trademark of Nintendo.

## AI Use Disclosure

The current contents of this repository were written **without** LLM/AI code generation. All AI usage in any form by contributors must be disclosed.

## Devlog

- **2026-06-20**: First visuals from the PPU seen on the SDL3 renderer.
- **2026-06-15**: Passed all tests in `mooneye-test-suite/acceptance/timer`.
- **2026-06-12**: Passed the full blargg's `cpu_instrs` test rom.
- **2026-06-08**: Fixed a bunch of CPU instruction bugs. Blargg's `cpu_instrs` individual test roms 03 to 11 now pass.
- **2026-06-07**: Implemented all CPU instructions. Implemented placeholder arrays for IO addresses. Interrupt registers can be set but no handling. Blargg's `cpu_instrs` individual test rom 01 passes!
- **2026-06-04**: Started dev. Copied the structure from CHIP-8 emulator, but switched to the game boy's 160 x 144 screen with a 4 colour palette.

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
- [Mooneye test suite](https://github.com/Gekkio/mooneye-test-suite)
- [dmg-acid2 test rom](https://github.com/mattcurrie/dmg-acid2)

## License

Distributed under the MIT License. See [LICENSE](./LICENSE) for more information.
