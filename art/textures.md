# Skin textures: batch 1

Original textures for the hardware-style skin (roadmap: "A hardware-style skin"). They're
generated on the local ComfyUI and saved here as source art. The app draws all **lighting,
shadows, pointers, value arcs and text in code** on top of them. So every texture below asks for
**flat, even, shadowless light**: a picture of a knob with a highlight baked in would spin its
highlight when the knob turns.

Batch 1 is the minimum to judge the look on the Mixer page: a panel surface, a knob cap and
LCD glass. More (fader caps, LED lenses, a footer bar, the app icon) come after we've seen these.

## How to generate

- **Model:** Z-Image Turbo first (photographic material detail). FLUX.2 klein 4B is the
  alternative if a texture comes out too "rendered".
- **Settings:** the workflow's usual turbo settings (few steps, CFG ≈ 1). Turbo models mostly
  ignore negative prompts at CFG 1, so the "avoid" lines are worded into the prompts as well; use
  them as negative prompts only if the workflow runs CFG > 1.
- **Variants:** 4 seeds per texture. Save as PNG, named `<texture>-<seed>.png`, into `art/textures/raw/`.
- Record the seed, model and settings of each image you keep in the table at the bottom.

After generation, Claude processes the chosen ones (`art/textures/`): makes the panel seamless,
cuts the knob to a circle with transparency, sets the brightness to the values below, and checks
them at 1× and 2× in the app.

---

## 1. Panel surface (`panel`)

The background of every strip and section: dark charcoal, fine grain, a hint of use. It's tiled
across large areas, so it must be **featureless**: no scratches, logos or shapes the eye can pick
out when the texture repeats.

- **Size:** 1024 × 1024, square
- **Use:** tiled at 50% scale on Retina; sections are lighter or darker tints of it, bevels drawn in code
- **Target after processing:** average about `#2B2B2D` (sRGB), grain within ±4% brightness, no hue cast beyond a faint cool grey

**Prompt**

> Seamless tileable texture, top-down orthographic view of a flat sheet of matte charcoal-grey
> powder-coated steel, as used on the front panel of a vintage studio synthesizer. Very fine,
> even, uniform grain like fine sandpaper or toner powder, with extremely subtle variation in
> tone. Completely flat, evenly lit by soft diffuse light with no shadows, no highlights, no
> reflections, no vignette. No scratches, no dents, no screws, no edges, no text, no logos, no
> patterns or shapes. Neutral dark grey with a very slight cool tint. High detail, sharp focus,
> photographic material reference.

**Avoid (negative):** scratches, dust specks, stains, rust, edges, borders, text, logos, screws,
vignette, gradient, specular highlight, shadow, perspective, bokeh, blur, noise patterns, tiles, seams

**Variant to try if it's too plain:** replace "powder-coated steel" with "bead-blasted anodised
aluminium" (a slightly more metallic grain).

---

## 2. Knob cap (`knob-cap`)

The material on the top face of a knob, seen straight from above. The app scales it to each knob,
rotates it with the value, and draws the rim shading, drop shadow and the light pointer line
itself. So the cap must be **perfectly round, centred and radially symmetric**, with **no
pointer, notch or highlight**. Only the concentric "spun metal" rings should show, and they make
the rotation readable.

- **Size:** 1024 × 1024, the cap filling about 90% of the frame on plain black
- **Use:** cut to a circle with transparency; drawn at 40–90 pt; the pointer line and lighting in code
- **Target after processing:** cap face average about `#3A3A3D`, rings within ±6%, rim slightly darker

**Prompt**

> Product photograph shot straight down from directly above (orthographic top view) of the flat
> top face of a large black anodised aluminium synthesizer control knob. The top face is
> perfectly circular, perfectly centred, and radially symmetric, with fine concentric machined
> rings from metal spinning, like the face of a high-end audio knob. Dark graphite grey, matte
> satin finish. Lit by perfectly even, flat, diffuse light from all sides: no highlights, no
> reflections, no shadows, no shading gradient. No pointer line, no indicator dot, no notch, no
> markings, no numbers, no text, no logo. Isolated on a pure black background. Ultra sharp,
> high detail, macro photography.

**Avoid (negative):** pointer, indicator, notch, dot, line, numbers, scale, text, logo, side view,
perspective, tilt, oval, off-centre, specular highlight, glare, reflection, shadow, gradient
lighting, knurling on the face, fingerprints, dust

**Variant:** "brushed in a circular pattern" instead of "fine concentric machined rings" (softer
rings); or "soft-touch rubberised black" for a plainer, King-of-FM-like cap.

---

## 3. LCD glass (`lcd`)

The background of the green screen that shows the preset or scene name and the live "why did that
play" text. The text, pixel grid and any glow are drawn in code, so this is only the **glass and
backlight**: a dark olive-grey, faintly uneven backlight and the slight mottling of an old LCD.

- **Size:** 1536 × 512 (3:1), stretched to the screen's size, never tiled
- **Use:** under text drawn in a pale green; an inset bezel and inner shadow drawn in code
- **Target after processing:** average about `#1F2620`, the centre up to 8% brighter than the edges, a green-grey hue (not saturated)

**Prompt**

> Front view, perfectly straight on, of the screen of a blank vintage monochrome LCD
> display from a 1990s synthesizer, filling the entire frame edge to edge. Dark olive grey-green
> glass with a faint, soft, uneven backlight that is slightly brighter in the middle, and very
> subtle mottled patches and fine grain typical of old liquid-crystal panels. The screen is blank:
> no characters, no text, no numbers, no pixels lit, no icons. No bezel, no frame, no reflections
> of a room, no glare, no fingerprints. Flat, even, photographic, high detail.

**Avoid (negative):** text, letters, numbers, segments, icons, pixels lit, bezel, frame, border,
reflection, glare, fingerprints, scratches, perspective, bright green, neon, blue

**Variant:** "amber-grey" instead of "olive grey-green" for a warmer screen, to compare.

---

## Kept images

| Texture | File | Model | Seed | Steps / CFG | Notes |
|---|---|---|---|---|---|
| panel | | | | | |
| knob-cap | | | | | |
| lcd | | | | | |
