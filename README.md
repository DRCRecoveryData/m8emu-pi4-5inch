# M8 Headless on Raspberry Pi 4 + 5" DSI Screen

Native ARM64 build of [m8emu](https://github.com/karimkfoure/m8emu) v0.3.0
running fullscreen on a Raspberry Pi 4 with a 5-inch DSI panel.

![Platform](https://img.shields.io/badge/platform-Raspberry%20Pi%204-red)
![Arch](https://img.shields.io/badge/arch-aarch64-blue)
![Version](https://img.shields.io/badge/m8emu-v0.3.0-green)

---

## Overview

This project packages `m8emu` — a headless M8 Tracker emulator with a
native AOT (ahead-of-time) execution engine — for the Raspberry Pi 4
with a 5-inch DSI display. It runs the official Dirtywave M8 Headless
firmware (6.5.2C) at full speed using the KMS/DRM display backend, with
audio routed to the 3.5 mm headphone jack.

### What works

- ✅ Fullscreen rendering on the 5" DSI panel (`card1-DSI-1`)
- ✅ Audio through the 3.5 mm headphone jack (`card 0: bcm2835 Headphones`)
- ✅ Native AOT engine (`libm8aot.so`) at **~3× realtime** on a Pi 4
- ✅ Headless firmware 6.5.2C (SHA-256 verified at build time)
- ✅ Autoplay demo via `--play`
- ✅ Interactive control from a physical TTY or any gamepad

### Known limitations

- ⚠️ Keyboard input over SSH is not supported (libinput requires a
  logind seat — see [Controls](#controls)).
- ⚠️ HDMI audio is not configured (default is the headphone jack).
- ⚠️ Screen rotation is untested on this panel.

---

## Directory layout
