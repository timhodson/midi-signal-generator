# 0013 — Performance: fine-grained UI updates, visuals only when visible, change-driven synth sync

- **Status:** accepted
- **Date:** 2026-11-12

## Context

The app felt laggy: sliders and the synth editor responded only after a wait. `msg-app --profile <section>`
(below) measured the app, release build with five hosted synths, at 36–106% of a core depending
on the page. Sampling (`sample <pid>`) showed the main thread mostly idle. The time went on
the engine thread, in dictionary hashing and `ParamSpec` copies inside `AUHostSink.applyParams`.

## Findings and decisions

1. **The synth host scanned every param, every tick.** Each 5 ms tick it checked all ~470 hosted-synth
   params, and each check looked up and copied the spec: roughly 100k dictionary operations a second, which
   also delayed whatever else the engine queue had to do. Now:
   - `ParamStore` keeps **effective values cached** (recomputed on `set` / `setOffsets`), so `value(_:)`
     is one lookup;
   - it keeps a **change log**; `AUHostSink` reads it from its own cursor and only touches params that changed.
   CLI with five synths: ~24% → ~7% of a core.
2. **Every control re-rendered on every status update** (10 Hz, plus each drag event), because all
   controls read from one dictionary that was replaced each time. With 470 controls and preset pickers
   of up to 641 entries, that was most of the UI cost. Now each param has an observable `ParamCell`
   (base, effective), and each control observes only its own cell. Idle re-renders: 10–66/s → 0.
   Local edits win over in-flight status updates for 0.4 s, so sliders don't jump back.
3. **Visuals only run when they can be seen.** `WindowVisibility` watches occlusion, miniaturise and
   app hide. While hidden, every `TimelineView` pauses and the engine publishes status at 1 Hz instead of 10 Hz.
   Scrolling pages use `LazyVStack` so offscreen visuals aren't built. Hero piano rolls run at 24 fps,
   small lanes and keyboards at 12. App hidden: 25% → 7%.
4. **Open Editor shows a spinner.** Out-of-process plugin views take a moment to arrive over XPC.
   That delay is the plugin's, but the button now responds immediately.

| Release build, 5 synths | before | after |
|---|---|---|
| CLI (no UI) | ~24% | ~7% |
| App hidden | 25% | 7% |
| App, Overview | 36% | 16% |
| App, Generators | 52% | 33% |
| App, Instruments | 106% | 30% |

## Measuring

```sh
swift build -c release
B=$(swift build -c release --show-bin-path)
$B/msg-app --scene scenes/audiokit-hosted.json --source synthetic --profile generators --seconds 8 [--hidden] [--drag]
```

It prints control re-renders/s, visual frames/s and CPU as a percentage of one core. Run the app as a release build
(`swift run -c release msg-app`); a debug build runs our code unoptimised and is much heavier.
