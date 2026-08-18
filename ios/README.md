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

## Shipping to TestFlight

`.github/workflows/testflight.yml` archives, signs and uploads to App Store
Connect. It is **manual only** — run it from the Actions tab — because each run
consumes a build number.

It needs an Apple Developer Program membership, and eight pieces of
configuration. Everything below is a repository **secret** except
`IOS_BUNDLE_ID`, which is a repository **variable** (it isn't sensitive).

| Name | What it is | Where it comes from |
| --- | --- | --- |
| `IOS_BUNDLE_ID` *(variable)* | e.g. `com.kadendippe.epapernecklace` | You choose it, then register it as an App ID in the developer portal |
| `APPLE_TEAM_ID` | 10-character team ID | developer.apple.com → Membership |
| `BUILD_CERTIFICATE_BASE64` | Apple Distribution cert **with private key**, as a base64 `.p12` | See below |
| `P12_PASSWORD` | password you set when exporting the `.p12` | You choose it |
| `PROVISIONING_PROFILE_BASE64` | base64 of an App Store provisioning profile | Portal → Profiles → new "App Store Connect" profile for your App ID → download → `base64 -i profile.mobileprovision \| pbcopy` |
| `KEYCHAIN_PASSWORD` | any random string | You choose it; it only protects a throwaway keychain on the runner |
| `APPSTORE_API_KEY_ID` | 10-character key ID | App Store Connect → Users and Access → Integrations → App Store Connect API |
| `APPSTORE_API_ISSUER_ID` | UUID shown above the key list | Same page |
| `APPSTORE_API_PRIVATE_KEY` | the whole `.p8` file contents, `-----BEGIN…` and all | Downloaded once when you create the key — Apple never shows it again |

### Getting the `.p12`

With a Mac: Xcode → Settings → Accounts → Manage Certificates → create an Apple
Distribution certificate, then in Keychain Access right-click it → Export as
`.p12`. Then `base64 -i cert.p12 | pbcopy`.

Without a Mac, using openssl anywhere:

```
openssl req -new -newkey rsa:2048 -nodes -keyout key.pem -out request.csr
# upload request.csr at developer.apple.com → Certificates → +  (Apple Distribution)
# download the resulting distribution.cer, then:
openssl x509 -in distribution.cer -inform DER -out cert.pem -outform PEM
openssl pkcs12 -export -inkey key.pem -in cert.pem -out cert.p12
base64 -i cert.p12
```

Guard `key.pem` and the `.p8` — both are credentials, and neither belongs in
this repository.

### First run

Expect it to need a round or two of fixes. Signing pipelines rarely work first
time, and none of this has been exercised: I wrote it without an Apple account
to test against. The likeliest snags are the certificate type not matching
`CODE_SIGN_IDENTITY`, or the App ID not existing yet in the portal. The archive
log is uploaded as an artifact on both success and failure.

Once a build is processed (a few minutes), it appears in TestFlight for
internal testers with no review needed.

## Debug logging over ntfy

A TestFlight build has no debugger attached, so `print()` is invisible.
`Support/Telemetry.swift` writes every line to the unified log and, if a topic
is configured, batches them and posts one message per operation to
[ntfy.sh](https://ntfy.sh).

Pick a long random topic name first. It is the *only* access control ntfy's
public server offers — anyone who knows it can read your logs and post to them.

**Building in CI** (the usual case, since TestFlight builds come from the
workflow): add the topic as a repository secret named `NTFY_TOPIC`, under
Settings → Secrets and variables → Actions. The workflow writes the plist
before building. Nothing to do locally, and the topic never enters the repo.

**Building locally in Xcode:** copy the example and fill in the same topic —

```
cp ios/Telemetry.example.plist ios/EPaperNecklace/EPaperNecklace/Telemetry.plist
```

That path is gitignored; this repository is public.

Either way, read the logs from the ntfy iOS app (subscribe to the topic), from
   `https://ntfy.sh/<topic>` in any browser, or from a terminal:

   ```
   curl -s https://ntfy.sh/<topic>/json                    # live stream
   curl -s "https://ntfy.sh/<topic>/json?poll=1&since=1h"  # recent history
   ```

With no topic configured — no secret in CI, no local plist — remote posting is
off and nothing leaves the device.

One consequence of the CI route worth knowing: the topic is baked into the app
bundle, so anyone who gets hold of the build can extract it. For a debug channel
carrying packet counts and status bytes that is a fair trade, but don't reuse
the topic for anything you'd mind a stranger reading or posting to.

A clean transfer is about 16 lines in one message: the negotiated MTU and
resulting packet count, the raw status byte after START and END, every tenth
chunk, and the outcome. Chunk logging is sampled because at an unnegotiated
23-byte MTU the transfer is 276 packets. ntfy.sh only caches messages for a
limited window, so treat it as a live channel rather than an archive; the
unified log keeps the same lines on the device regardless.

## Pitfalls

Two known ways this can behave oddly, both of them cases where the logs either
mislead or say nothing at all. Worth reading before concluding something is
broken.

### MTU negotiation is unverified

The chunk size is whatever `maximumWriteValueLength(for: .withoutResponse)`
reports, which CoreBluetooth defines as ATT_MTU − 3. What that number actually
is depends on a negotiation between iOS and NimBLE that neither of us has
watched happen, and it changes the transfer by a factor of twenty-five:

| ATT_MTU | chunk | packets for 5,512 bytes |
| --- | --- | --- |
| 23 (never negotiated up) | 20 | 276 |
| 185 (common on iOS) | 182 | 31 |
| 517 (NimBLE maximum) | 514 | 11 |

**What you'd see.** The first telemetry line of every transfer reports it:

```
transfer: 5512 bytes, chunk 182 (withoutResponse 182, withResponse 512), 31 packets
```

If `chunk` is 20, the MTU never grew. The transfer still works, but it takes far
longer, the progress ring crawls, and you are 276 round trips away from an
answer instead of 31 — which also makes a chunk timeout much more likely to bite
somewhere in the middle.

**What to do.** That's a firmware-side fix: NimBLE has its own maximum, set with
`NimBLEDevice::setMTU()`, and the peripheral has to accept a larger exchange. It
is not something the app can force.

Note also that `withResponse` typically reports 512 regardless, because iOS will
happily split a larger write into a queued long write. Taking the smaller of the
two is what keeps chunks at true ATT_MTU − 3; if that clamp were removed, iOS
could send a long write that the firmware isn't expecting.

### A crash or force-quit loses the remote log

Telemetry batches lines in memory and posts them once, at the end of the
operation. If the app is killed between `begin` and `flush` — a crash, or you
swiping it away mid-transfer — that batch dies with it and **nothing reaches
ntfy**.

**Why this misleads.** Silence is ambiguous. No message can mean the transfer
never started, *or* that it got a long way in and then the app died. A genuine
failure always produces an `upload failed` message, because every error path
unwinds through the flush and the timeouts guarantee an error eventually
arrives. So:

| what you see | what it means |
| --- | --- |
| `upload ok` | it worked |
| `upload failed` + error line | it failed, and the batch tells you where |
| nothing at all | the app died, or telemetry isn't configured |

**What to do.** The unified log on the phone still has every line, so nothing is
truly lost — `OSLogStore` can read it back on-device, or Console.app can from a
Mac. Before assuming a crash, check that the topic is actually configured: an
unset `NTFY_TOPIC` produces exactly the same silence.

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
