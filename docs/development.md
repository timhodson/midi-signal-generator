# Development

## Layout

```
Package.swift
Sources/
  Params/      ParamSpec, ParamStore, ModMatrix, Macro
  SignalBus/   SignalSample, SignalSource, SignalBus
  Music/       Harmony, Clock, Quantiser, Conductor, ActivityTracker, Generators
  Router/      VoiceConfig, VoiceRouter
  MIDIOut/     NoteScheduler, CompositeSink, CoreMIDISink, PrintSink
  AUHost/      AUHostSink: hosted Audio Unit instruments
  Sources/     NettopSource (+ parser), SyntheticSource
  Engine/      Engine (tick loop), Scene
  Runtime/     Session: one place that builds synths + MIDI + engine + source
  msg-spike/   CLI
  msg-app/     SwiftUI app
Tests/         Swift Testing suites per module
scenes/        default.json, ipad-network.json, audiokit-hosted.json
docs/          this folder; decisions/ holds the ADRs
```

## Build and run

```sh
swift build
.build/debug/msg-spike --help
.build/debug/msg-spike --source synthetic --dry-run        # no network or MIDI needed
.build/debug/msg-spike --dry-run                            # real traffic, print notes
.build/debug/msg-spike --list-params                        # every tunable value
.build/debug/msg-spike --set macro.faithfulness=0.8 --set harmony.scale=4 --verbose
```

## The app

```sh
swift run -c release msg-app --scene scenes/audiokit-hosted.json   # use release for real use (ADR 0013)
swift run msg-app --source synthetic                       # no network needed
# headless check: render every screen to PNGs and exit (no window appears)
swift run msg-app --scene scenes/audiokit-hosted.json --source synthetic --snapshot /tmp/msg-snap --seconds 10
# README screenshots: wider window, Studio skin, a variation applied, a panel open
swift run msg-app --scene SCENE --source synthetic --no-packets --snapshot DIR --seconds 25 --height 900 --width 1720 \
  --skin studio --randomise -flow.selected "panel:generators/drums" -tiles.generators.expanded drums
# add --sliders to render settings as sliders instead of knobs
# then: sips -s format jpeg -s formatOptions 82 --resampleWidth 1720 DIR/<page>.png --out docs/screenshots/<page>.jpg
```

Performance check (control re-renders, visual frames, CPU), see ADR 0013:
`$(swift build -c release --show-bin-path)/msg-app --source synthetic --profile generators --seconds 8`

## Tests

```sh
swift test
```

## Toolchain gotchas (Command Line Tools only, no Xcode)

> **This Mac now uses Xcode** (`xcode-select -p` → `/Applications/Xcode.app/…`), and plain
> `swift build` / `swift test` work. If `swift` says *"You have not agreed to the Xcode license
> agreements"*, run `sudo xcodebuild -license accept`. The rest of this section only applies to
> Command Line Tools–only installs.

**`swift build` fails on every package** with
`reference to member 'v15' cannot be resolved` or `Undefined symbols … PackageDescription.Package.__allocating_init`.
The CLT install has leftover Swift 5.10 `*.private.swiftinterface` files in
`/Library/Developer/CommandLineTools/usr/lib/swift/pm/ManifestAPI/PackageDescription.swiftmodule/`
(dated Feb 2024, older than the rest). The compiler picks them up instead of the current interface.

- **Permanent fix** (needs admin):

  ```sh
  sudo rm /Library/Developer/CommandLineTools/usr/lib/swift/pm/ManifestAPI/PackageDescription.swiftmodule/*.private.swiftinterface
  ```

  Reinstalling the Command Line Tools also fixes it.
- **No-sudo workaround:** copy `…/usr/lib/swift/pm` somewhere, delete the two
  `*.private.swiftinterface` files from the copy, and point SwiftPM at it:

  ```sh
  export SWIFTPM_CUSTOM_LIBS_DIR=/path/to/copied/pm
  ```

**`no such module 'Testing'` / `Library not loaded: @rpath/lib_TestingInterop.dylib`**:
SwiftPM doesn't add the CLT's Swift Testing paths. Pass them yourself:
`swift test -Xswiftc -F -Xswiftc $CLT/Frameworks -Xlinker -F -Xlinker $CLT/Frameworks -Xlinker -rpath -Xlinker $CLT/Frameworks -Xlinker -rpath -Xlinker $CLT/usr/lib`
with `CLT=/Library/Developer/CommandLineTools/Library/Developer`. With Xcode, plain `swift test` works.

## Conventions

- New behaviour? Declare its `ParamSpec`s first (ADR 0002). No magic numbers in the musical path.
- Generators emit `NoteIntent`s by role. They never pick channels, devices or exact timing.
- Engine state is confined to `Engine.queue`. Sources hop onto it.
- Record decisions as a new ADR in `docs/decisions/`.
