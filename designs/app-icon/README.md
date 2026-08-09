# Rasterize app icon — 1a Overlap

The house Balopy mark in the macOS squircle. Geometry is the design system's
`assets/logo.svg` unchanged: a 120 × 120 box, three r=31 circles multiplying on
`--paper-0`, forest at (45, 48), butter at (75, 48), coral at (60, 76).

## Contents

- `rasterize-icon.svg` — vector master, 1024 × 1024 with the standard macOS
  art inset (824 of 1024). Corner radius 26% of the art side, 1px-equivalent
  ink border scaled proportionally.
- `AppIcon.appiconset/` — drop straight into `Assets.xcassets`. Contains
  `Contents.json` and PNGs at 16, 32, 64, 128, 256, 512 and 1024, covering
  every mac idiom slot from 16pt@1x to 512pt@2x.

## Notes

- The tile is drawn with a rounded rect, not Apple's true squircle. If you want
  the exact superellipse, rebuild from `rasterize-icon.svg` in Icon Composer or
  substitute Apple's continuous-corner path — everything else is unaffected.
- The three inks fuse into one dark tile at 16px. That is inherent to the mark
  and was the main argument for the rasterised alternative. If the 16px slot
  matters, hand-tune `icon_16.png` or substitute the 1b grid at that size only.
- `mix-blend-mode: multiply` is baked into the PNGs. The SVG relies on the
  blend mode at render time, so flatten it before handing it to any tool that
  ignores blend modes.
- Colours: paper `#FBF8F1`, forest `#1F8564`, butter `#F2C14E`,
  coral `#F4653F`, ink `#101915`.
