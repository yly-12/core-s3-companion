# Pink-haired Madeline status animations

Each status is a four-frame, infinitely looping, transparent 48 x 48 GIF.
The corresponding RGBA PNG frames and high-resolution source strips are kept
alongside the previews for later firmware conversion.

| Agent state | Motion | Frame delay |
| --- | --- | ---: |
| `idle` | Breathing, blink, and breath puff | 280 ms |
| `running` | Four-step run cycle and dash streak | 120 ms |
| `authorization` | Raised key and pulsing sparkles | 220 ms |
| `reply` | One, two, three, then zero speech dots | 240 ms |
| `completed` | Crouch, hop, check sparkle, and landing | 160 ms |
| `cancelled` | Glance and pulsing orange X | 280 ms |
| `failed` | Tired breathing and broken-crystal pulse | 280 ms |

Directories:

- `gif/`: looping previews
- `frames/`: 48 x 48 RGBA PNG frames
- `strips/`: generated four-frame source strips

The GIFs and PNG frames are built with
`scripts/build_status_gifs.swift`, using a shared crop per animation and
nearest-neighbor scaling to keep frame anchors stable.

Firmware embeds the PNG frames in `src/renderer/StatusAnimationAssets.cpp` and
draws them at `(256, 77)`, placing the animation on the same row as the state
label with its right edge aligned to the screen content boundary at `x = 304`.
