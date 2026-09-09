# Handoff: Boppa Llewyn theme for the Rasterize Starlight docs

## Overview

`kpgalligan/rasterize` gained a public documentation section at `public-docs/`, built on
Astro + Starlight (`@astrojs/starlight ^0.42.0`, `astro ^7.2.10`). At the time of this
handoff it is the unmodified Starlight "Basics" starter: default content, default
Starlight blue/gray theme, `houston.webp` on the splash page, and no committed
`astro.config.mjs`.

This bundle themes it to the **Boppa Llewyn design system** — warm-ebony neutrals,
brass accent, Cormorant Garamond display type, IBM Plex Sans/Mono, sharp joinery
corners, hairlines instead of shadows. Both a dark surface and a cream light surface
are specified, so Starlight's theme toggle keeps working.

## About the design files

`starlight-custom.css` is **not** a design reference — it is the deliverable, production
CSS. Starlight exposes its whole visual design through `--sl-*` custom properties, so
the theme is a real token override file. Drop it in and register it.

`reference/Rasterize Docs Theme.dc.html` **is** a design reference — an HTML prototype
of the themed docs site (splash, guide, reference, mobile, both themes) used to design
and check the CSS. It hand-builds Starlight's layout with inline styles; do not port its
markup. It also depends on this design-system project's `_ds/…` token files and a
runtime `support.js` that are not in the bundle, so it will not render standalone —
open it in the design project if you need to see it. Everything it shows is described
below in words and values.

## Fidelity

**High-fidelity.** Colors, type sizes, spacing, radii, and motion are final and are
listed as exact values. The CSS in this bundle is the source of truth; where the
prototype and the CSS disagree, the CSS wins.

## What to do

1. Add `public-docs/src/styles/custom.css` = `starlight-custom.css` from this bundle.
2. Create `public-docs/astro.config.mjs` (snippet in `theme-notes.md` §1) registering it
   via `customCss`, plus the Expressive Code options — `useStarlightUiThemeColors: true`
   is what makes code-block chrome follow the tokens.
3. Copy the five WOFF2 files from the design system's `assets/fonts/` into
   `public-docs/public/fonts/` and add `src/fonts/font-face.css` (§2 of the notes).
4. Build the component overrides in `theme-notes.md` §4 — the seven things the token
   layer cannot reach.
5. Replace the starter assets and copy (see Loose ends, §5 of the notes).

No new dependencies. No Tailwind — the theme is plain CSS, unlayered so it wins over
every Starlight cascade layer.

## Screens / views

The prototype shows four; all four are stock Starlight layouts, restyled. No layout
markup changes are required for any of them.

### 1. Splash (`src/content/docs/index.mdx`, `template: splash`)

- **Purpose**: docs landing page.
- **Layout**: header 60px sticky; hero section max-width 1120px, padding `112px 24px
  96px`, two-column grid `minmax(0,1fr) 300px`, gap 64px, vertically centered; hairline
  divider; "Next steps" section padding `80px 24px 144px`, two-column card grid, gap
  20px, right column offset 48px down (Starlight's `stagger`).
- **Components**:
  - Mono eyebrow above the h1: 12px IBM Plex Mono 500, uppercase, `letter-spacing
    .08em`, brass, 20px below.
  - h1 "Welcome to Starlight" — Cormorant Garamond 500, `clamp(52px,7vw,88px)`,
    line-height 1.06, tracking −0.005em, `--sl-color-white`.
  - Tagline "Congrats on setting up a new Starlight project!" — Plex Sans 19px/1.5,
    `--sl-color-gray-2`, max-width 44ch.
  - Primary action "Example Guide" + `arrow-right` 16px: brass `#F2C14E` background,
    ink `#101915` text, weight 500, padding `11px 22px`, radius 4px; hover `#E0AB33`.
  - Minimal action "Read the Starlight docs" + `external-link` 15px: accent-colored
    text, no background.
  - `houston.webp` 300px wide, right-aligned.
  - Five cards, `.card`: `--sl-color-gray-6` fill, 1px `--sl-color-hairline-light`
    border, radius 4px, **no shadow**, padding 24px; h3 Cormorant 24px; body Plex Sans
    14px/1.55 `--sl-color-gray-2`; inline `code` on `--sl-color-bg-inline-code`,
    radius 2px, 13px mono.

### 2. Guide page (`guides/example.md`)

- **Layout**: three columns — sidebar 280px, content (centered, max-width
  `--sl-content-width` = 680px, padding `56px 24px 144px`), ToC 224px.
- **Sidebar**: `--sl-color-bg-sidebar` fill, 1px right hairline, padding `32px 16px`,
  28px between groups. Group labels ("Guides", "Reference") 12px mono 500 uppercase
  `.08em`, `--sl-color-gray-3`. Links 14px, `--sl-color-gray-2`, padding `6px 8px`,
  radius 4px; hover `--sl-color-gray-6` fill + `--sl-color-white`; current page brass
  fill, ink text, weight 600.
- **Content**: mono eyebrow ("Guides"), h1 52px Cormorant, description 17px/1.5
  `--sl-color-gray-2`, hairline rule, body 15px/1.55, h2 38px Cormorant.
- **Aside** (note): full 1px border in `--sl-color-blue` (teal), background
  `--sl-color-blue-low`, radius 4px, padding `16px 20px`; title 12px mono uppercase
  `.08em` in `--sl-color-blue-high`; **no left accent bar, no icon** — both removed
  from Starlight's default.
- **Code block**: `.frame` 1px hairline border, radius 4px, overflow hidden;
  figcaption `--sl-color-gray-6` fill with bottom hairline, title 12px mono uppercase;
  `pre` padding 16px, 13px/1.7 mono. One `<div>` per line (newlines between sibling
  elements are unreliable in the prototype's template engine — not an issue in real
  Starlight).
- **ToC**: "On this page" 12px mono uppercase `--sl-color-gray-3`; 1px left hairline
  rail; items 13px, 14px inset; active item 2px brass left border and
  `--sl-color-white` text.

### 3. Reference page (`reference/example.md`)

Same chrome as the guide. Adds:

- **Table**: `border-collapse: collapse`, width 100%, 14px. `th` 12px mono uppercase
  `.08em` `--sl-color-gray-3`; every cell padding `10px 12px`, bottom hairline only —
  no vertical rules, no zebra. Command cells carry `white-space: nowrap` so tokens like
  `npm install` never break mid-token.
- **Aside** (caution): same box as note, in ember `#F4653F` / `--sl-color-orange-low`.

### 4. Mobile (390px)

- Header 56px: `menu` button, app icon 24px, wordmark 19px Cormorant, spacer, `search`
  and theme buttons. All controls 32×32 with a 1px hairline border and 2px radius.
  **Note for implementation**: 32px is below the 44px minimum touch target — give the
  real header controls a 44px hit area (padding or `::before` expansion) even though the
  visual box stays 32px.
- Mobile ToC bar 48px: `--sl-color-bg-sidebar` fill, bottom hairline, `chevron-right`
  15px, "On this page" 14px, current section as a mono uppercase 11px label at the end.
- Content padding `28px 18px 56px`; h1 40px; description 16px/1.5.

## Interactions & behavior

- **Theme toggle**: switches `data-theme` between absent (dark) and `light` on `<html>`.
  Starlight's own `ThemeSelect` already does this; the override in §4 of the notes only
  reduces it from three options to two, since the system has exactly two surfaces.
- **Hover**: surfaces lighten one step (`gray-6` → `gray-7`), borders step up
  (`hairline-light` → `gray-4`), links go accent → `accent-high` and gain an underline,
  primary buttons darken brass → `#E0AB33`.
- **Press**: darken further. Nothing scales, shrinks, or bounces.
- **Focus**: `box-shadow: 0 0 0 2px var(--sl-color-bg), 0 0 0 4px var(--sl-color-accent)`
  with `outline: none` and 2px radius. Never removed.
- **Transitions**: `background-color`, `border-color`, `color` only, 120ms
  `cubic-bezier(0.2,0.8,0.2,1)`; 200ms for overlays. `prefers-reduced-motion` collapses
  all durations to ~0.
- **Responsive**: Starlight's own breakpoints are unchanged. Display type steps up at
  `min-width: 50em` (h1 42px → 52px, h2 30px → 38px).
- No scroll-triggered reveals, parallax, or looping motion anywhere.

## State management

None beyond what Starlight already owns: the theme preference (`localStorage`, handled
by Starlight), sidebar/ToC disclosure state, and the Pagefind search modal. The
prototype's screen tabs and theme button are harness controls, not product features.

## Design tokens

Copied verbatim from the design system; `starlight-custom.css` declares them as
`--bl-*` and maps them onto `--sl-*`.

**Neutrals (dark)**
| Token | Value | Used for |
| --- | --- | --- |
| `--bl-bg-0` | `oklch(0.16 0.011 70)` | page background, header |
| `--bl-bg-1` | `oklch(0.195 0.012 70)` | sidebar, cards, code frames |
| `--bl-bg-2` | `oklch(0.23 0.013 70)` | inline code, hover fill |
| `--bl-bg-3` | `oklch(0.275 0.014 70)` | overlays, kbd |
| `--bl-line-1` | `oklch(0.32 0.015 72)` | hairlines |
| `--bl-line-2` | `oklch(0.43 0.018 75)` | hairline hover |
| `--bl-fg-1` | `oklch(0.94 0.014 88)` | headings |
| `--bl-fg-2` | `oklch(0.74 0.02 82)` | body |
| `--bl-fg-3` | `oklch(0.57 0.018 78)` | muted, eyebrow labels |

**Accents**
| Token | Value | Note |
| --- | --- | --- |
| `--bl-brass` | `#F2C14E` | umbrella brand accent, dark surfaces only |
| `--bl-brass-strong` | `#E0AB33` | primary button hover |
| `--bl-brass-dim` / `-faint` | `oklch(0.3 0.05 84)` / `oklch(0.225 0.028 84)` | tinted surfaces |
| `--bl-brass-deep` | `#8A6410` | **links on cream** — brass itself is ~1.4:1 on cream and fails |
| `--bl-brass-deeper` | `#5C4208` | link hover on cream |
| `--bl-brass-pale` | `#F7E9C5` | accent-low on cream |
| `--bl-ember` | `#F4653F` | Rasterize product accent; `caution` asides |
| `--bl-teal` | `#1F8564` | `note` / `tip`-adjacent asides, success |
| `--bl-danger` | `oklch(0.63 0.14 25)` | `danger` asides |

**Cream surfaces**: `--bl-cream #FBF8F1`, `--bl-cream-1 #F4EFE2`,
`--bl-cream-2 #EAE3D2`, `--bl-ink #101915`, body text `#40483F`, muted `#6B7268`,
hairline `rgba(16,25,21,0.14)`.

**Aside hue map**: note → teal, tip → brass, caution → ember, danger → danger red.

**Type**
- Display: Cormorant Garamond variable, weight 500, tracking −0.005em, line-height 1.06.
- Body/UI: IBM Plex Sans variable — 15px/1.55 body, 14px in cards and tables, 13px min.
- Mono: IBM Plex Mono 400/500 — 12px uppercase `.08em` eyebrows, code 13px, kbd 11px.
- Scale in use: h1 52px (42px under 50em), h2 38px, h3 28px, h4 21px, h5 17px.

**Spacing**: 4px base — 4 / 8 / 12 / 16 / 24 / 32 / 48 / 64 / 96 / 144. Sections breathe
at 96–144px; hero pads 112px top. Container 1120px + 24px gutter. Prose measure 680px.
Card grids gap 20px.

**Radii**: 2px inputs, badges, kbd, focus ring; 4px buttons, cards, asides, code frames;
8px dialogs and the mobile device frame. Pill only for `Tag` and `Switch`. App icons
carry a 22.6% squircle in the artwork.

**Shadows**: overlays only — `0 1px 2px rgba(0,0,0,.4)` tooltips,
`0 4px 16px rgba(0,0,0,.45)` toasts, `0 16px 48px rgba(0,0,0,.55)` dialogs. Cards get a
hairline and no shadow; this is a hard rule.

**Motion**: 120ms hover, 200ms toggles/overlays, `cubic-bezier(0.2,0.8,0.2,1)`.

**Transparency**: exactly one use — the sticky header at `--sl-color-bg` 85% with
`backdrop-filter: blur(12px)`. Scrim is flat `rgba(10,9,8,0.65)`.

## Assets

| Asset | Source | Status |
| --- | --- | --- |
| `reference/assets/rasterize-1024.png` | design system `assets/app-icons/` | ship it; use as logo and favicon source. Never recolor or crop. |
| Fonts (5 × WOFF2) | design system `assets/fonts/` | copy into `public-docs/public/fonts/`. Google Fonts (OFL) picks, not licensed brand type. |
| `houston.webp` | Starlight starter, `public-docs/src/assets/` | placeholder — replace with the app icon. |
| `public/favicon.svg` | Starlight starter | replace with the design system's `assets/favicon.svg`. |
| UI icons | Lucide 0.469.0, `stroke-width: 1.75` | flagged substitution, not a brand asset. Starlight's own icon set is fine inside Starlight components; don't add a third set. |

No app screenshots exist in any source, so any app-window frame stays an empty
bordered frame with a mono placeholder label. Do not invent app UI.

## Files

| File | What it is |
| --- | --- |
| `starlight-custom.css` | the theme. Goes to `public-docs/src/styles/custom.css`. |
| `theme-notes.md` | config snippets, `@font-face` block, the seven component overrides, and open loose ends. |
| `reference/Rasterize Docs Theme.dc.html` | design reference prototype (won't render standalone — see above). |
| `reference/assets/rasterize-1024.png` | app icon used in the prototype header. |

Source read for the token mapping: `packages/starlight/style/props.css` and
`asides.css` in the Starlight package (read via the `touchlab/starlight` fork).
