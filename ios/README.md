# Tiny Gallery — iOS companion app

[![iOS build](https://github.com/Kaden-Dippe/EPaperKeyChain/actions/workflows/ios-build.yml/badge.svg?branch=claude/epaper-necklace-ios-app-g2f3dq)](https://github.com/Kaden-Dippe/EPaperKeyChain/actions/workflows/ios-build.yml)

Native SwiftUI app for the ESP32 e-paper necklace in this repository. It picks
or snaps a photo, crops it to the panel's exact aspect ratio, Atkinson-dithers
it to the panel's ink colours, packs it into the 5,512 byte payload the
firmware expects, and streams it over BLE.

Open `EPaperNecklace/EPaperNecklace.xcodeproj` in Xcode 16 or newer, set your
signing team, and run on a real device — CoreBluetooth doesn't work in the
Simulator.

- Deployment target: iOS 16.0
- No third-party dependencies
- Bundle identifier placeholder: `com.example.EPaperNecklace`

The project uses Xcode 16 file-system-synchronized groups, so new files added
under `EPaperNecklace/` are picked up automatically without editing
`project.pbxproj`.

## Layout

```
EPaperNecklace/
  App/        EPaperNecklaceApp.swift, AppModel.swift   flow + state
  Panel/      PanelSpec.swift, InkColor.swift           hardware constants, palettes
  Imaging/    PanelRenderer, AtkinsonDitherer,          crop → scale → dither → pack
              PixelPacker, ImagePipeline
  BLE/        NecklaceProtocol, NecklaceBLEManager,     the transfer state machine
              NecklaceError
  UI/         ContentView, CropView, StatusHeaderView,  SwiftUI screens
              PaletteToggle, TransferOverlay, CameraPicker, Theme
  Support/    UIImage+Normalized.swift
```

## Image pipeline

1. **Crop** — `CropView` locks the crop window to 212:104 (or 104:212 when the
   user frames portrait). Pinch to zoom, drag to reposition; the photo always
   covers the window, so nothing is letterboxed.
2. **Scale and rotate** — `PanelRenderer.makePanelRaster` crops, applies a
   quarter turn for portrait framing, and downsamples to exactly 212 × 104 in a
   single Core Graphics pass with high-quality interpolation. Portrait shots
   can turn either way (`Top points right` / `Top points left`).
3. **Dither** — `AtkinsonDitherer` diffuses 1/8 of the quantisation error to
   each of six neighbours and discards the remaining 2/8, which is what keeps
   edges crisp. Palette matching happens in YCbCr with chroma weighted 2× (see
   the note in `InkColor.swift`): in plain RGB, mid grey sits almost exactly
   between black, white and red, and flat grey areas pick up ~10% stray red
   pixels. With the chroma weighting that drops to zero while genuinely warm
   tones still map to red.
4. **Pack** — `PixelPacker` writes 4 pixels per byte, most significant bits
   first, `black = 0b00`, `white = 0b01`, `red = 0b10`. Always 2 bits per pixel
   regardless of the palette toggle, so the file is always 5,512 bytes. 212
   pixels is 53 whole bytes, so rows need no padding.

Everything after the crop runs off the main thread and reruns whenever the
palette toggle flips, so the preview is always exactly what the necklace will
display.

## Testing and tuning the dithering

`tools/verify_pipeline.py` is a reference port of the dithering and packing —
the same algorithm the app ships, in Python, so you can change a constant and
see the result in a second instead of a build-and-deploy cycle. Standard
library only, except `--image`, which wants `pip install pillow`.

```
python3 tools/verify_pipeline.py                        # regression self-test
python3 tools/verify_pipeline.py --sweep                # compare chroma weights
python3 tools/verify_pipeline.py --image photo.jpg      # dither a real photo
```

The self-test runs synthetic fields (grey ramp, flat grey, saturated red, a
warm brick tone) through the real algorithm and asserts the properties the
firmware and the eye depend on: payload is always 5,512 bytes, Classic never
emits red, pack/unpack round-trips, neutral grey picks up *no* red ink, and
saturated red still comes out fully red. It exits non-zero when one breaks, so
it works as a pre-commit check.

`--image` writes `preview.png` (magnified, nearest-neighbour) and optionally
the raw payload via `--payload out.bin`, which you can diff against the file
the ESP32 actually saved. Its crop, rotate and downsample mirror the app, but
scaling goes through Pillow's Lanczos filter rather than Core Graphics, so a
photo can differ by a pixel here and there; the dithering and packing are
exact.

To tune: change `CHROMA_WEIGHT` (or the ink values, or the `ATKINSON` matrix)
at the top of the script, rerun, then copy the number you settled on into the
Swift file named in the comment beside it. The two are meant to stay in sync.

## BLE transfer

| Step | Direction | Bytes |
| --- | --- | --- |
| START | app → control | `0xAA` |
| status | control → app (notify) | `0x01` OK / `0x02` ERROR / `0x03` BUSY |
| chunks | app → image | payload sliced to ATT_MTU − 3, write **with response** |
| END | app → control | `0xBB` |
| status | control → app (notify) | `0x01` OK |

- Scanning filters on the service UUID and double-checks the advertised name
  (`Epaper Keychain`).
- The app subscribes to notifications on the control characteristic before the
  connection is reported as ready, so START can never go out over a connection
  that isn't listening for the reply.
- Chunk size comes from `maximumWriteValueLength(for: .withoutResponse)`, which
  CoreBluetooth defines as ATT_MTU − 3, clamped by the `.withResponse` limit so
  iOS never turns a chunk into a queued long write.
- Image chunks are paced purely by the ATT-level write response — there is no
  application-level ACK on the image characteristic and the app does not
  subscribe to it.
- Timeouts: 5 s for a control status reply, 10 s for a chunk's write response,
  15 s to find the device, 20 s for connect + discovery + subscribe.
- A disconnect mid-transfer fails everything in flight with a clear message and
  resets the app to idle.

## Firmware notes

The app is written against the protocol in `Image_Transfer_Protocol.txt` and the
UUIDs in `src/main.cpp`. Two mismatches with the firmware as it stands today:

1. **Status byte values.** `src/CustomCallbacks.h` currently replies `0xCC` for
   OK and `0xDD` for ERROR, with no distinct BUSY code. `NecklaceProtocol.Status`
   accepts both those and the `0x01/0x02/0x03` values from the spec, so the app
   works either way; delete the two legacy cases once the firmware moves over.
2. **Characteristic setup.** `src/main.cpp` creates both characteristics with
   `createCharacteristic(UUID)` and never attaches
   `ControlCharacteristicCallbacks` / `ImageCharacteristicCallbacks`. Without
   the `NOTIFY` property on the control characteristic (and `WRITE` on both) and
   those callbacks installed, the firmware won't receive commands or send
   status bytes, and the app will time out waiting for the reply to START.
