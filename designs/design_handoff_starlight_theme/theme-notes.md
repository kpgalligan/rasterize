# Boppa Llewyn × Starlight — implementation notes

Companion to `starlight-custom.css`. Everything below is what the token file alone
cannot reach.

## 1. Wiring

`public-docs` has no committed `astro.config.mjs`. When you add one:

```js
import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';

export default defineConfig({
  integrations: [
    starlight({
      title: 'Rasterize',
      customCss: ['./src/fonts/font-face.css', './src/styles/custom.css'],
      logo: { src: './src/assets/rasterize-1024.png', alt: 'Rasterize' },
      expressiveCode: {
        themes: ['github-dark-default', 'github-light'],
        useStarlightUiThemeColors: true,
        styleOverrides: { borderRadius: '4px', borderColor: 'var(--sl-color-hairline-light)' },
      },
    }),
  ],
});
```

`useStarlightUiThemeColors: true` is what makes code-block chrome (frame, copy
button, borders) follow the tokens instead of the syntax theme.

## 2. Fonts

Copy the five WOFF2 files out of the design system's `assets/fonts/` into
`public-docs/public/fonts/`, then add `src/fonts/font-face.css`:

```css
@font-face { font-family: 'Cormorant Garamond'; src: url('/fonts/CormorantGaramond-Variable.woff2') format('woff2'); font-weight: 300 700; font-style: normal; font-display: swap; }
@font-face { font-family: 'Cormorant Garamond'; src: url('/fonts/CormorantGaramond-Italic-Variable.woff2') format('woff2'); font-weight: 300 700; font-style: italic; font-display: swap; }
@font-face { font-family: 'IBM Plex Sans'; src: url('/fonts/IBMPlexSans-Variable.woff2') format('woff2'); font-weight: 100 700; font-stretch: 85% 100%; font-style: normal; font-display: swap; }
@font-face { font-family: 'IBM Plex Mono'; src: url('/fonts/IBMPlexMono-Regular.woff2') format('woff2'); font-weight: 400; font-style: normal; font-display: swap; }
@font-face { font-family: 'IBM Plex Mono'; src: url('/fonts/IBMPlexMono-Medium.woff2') format('woff2'); font-weight: 500; font-style: normal; font-display: swap; }
```

Preload the two that appear above the fold (Plex Sans, Cormorant roman) via a
`Head` override.

## 3. Decisions baked into the CSS

- **Accent is brass**, the umbrella brand colour, not Rasterize ember. Ember is
  kept for the `caution` aside so the product hue still appears on its own pages.
- **Brass on cream fails contrast** (about 1.4:1), so the light theme uses a
  darkened brass, `#8A6410`, for links and `#5C4208` for hover. Brass itself only
  appears on dark.
- **Aside hue map**: note → teal, tip → brass, caution → ember, danger → danger red.
- **Asides are redrawn** as a full hairline box with a mono uppercase title; the
  4px left accent bar and the aside icons are removed. A left-border accent stripe
  is on the design system's do-not list.
- **Heading sizes are pushed up** (h1 52px desktop) because Cormorant Garamond
  sits small on its em.
- **Content width is 680px**, the design system's prose measure, down from
  Starlight's 720px.

## 4. Component overrides still needed

The token file cannot reach these; each needs a file in
`src/components/` plus a `components: { … }` entry in the Starlight config.

| Override | Component | Why |
| --- | --- | --- |
| `SiteTitle` | `components/SiteTitle.astro` | Wordmark in Cormorant Garamond next to the 1024px app icon, plus the mono `v2.4.1` badge. Starlight's default renders the logo image and title text only. |
| `ThemeSelect` | `components/ThemeSelect.astro` | Default is a three-option select (auto/light/dark). The system has exactly two surfaces, so ship a two-state toggle — and drop the `auto` label copy, which is sentence-case-incompatible with the select's own markup. |
| `Search` | `components/Search.astro` | Search button and the Pagefind modal both need the 2px input radius, mono `⌘K` kbd, and the brass focus ring. Pagefind's own CSS variables (`--pagefind-ui-*`) are separate from `--sl-*` and must be set here. |
| `PageTitle` | `components/PageTitle.astro` | Adds the mono uppercase eyebrow above the h1 (section name from the sidebar group), which is the system's standard page opener. |
| `Footer` / `EditLink` | `components/Footer.astro` | Footer fine print is mono and factual; default footer is sans. Also where the "One-time purchase. Free updates within v2." line belongs. |
| `Head` | `components/Head.astro` | Font preloads and the `apple-touch-icon.png` from the design system's assets. |
| `Hero` | `components/Hero.astro` | Only if the splash hero should carry the app icon at 1024px instead of `houston.webp`, and the actions should be real design-system `Button`s. |

Two things deliberately **not** overridden: `Sidebar` (the default markup takes the
mono group labels and the brass current-page pill from CSS alone) and `TableOfContents`
(same).

## 5. Loose ends

- `public-docs/src/assets/houston.webp` and `public/favicon.svg` are still the
  Starlight starter assets. Replace with the Rasterize app icon and the design
  system's `assets/favicon.svg`.
- Content is still the starter's `Welcome to Starlight` / `Example Guide` /
  `Example Reference`. The mockup shows that copy verbatim, so page titles read
  as placeholders on purpose.
- Sentence case is a house rule the CSS cannot enforce. `Example Guide` and
  `Example Reference` should become `Example guide` and `Example reference`.
- Lucide is the flagged icon substitution. Starlight ships its own icon set;
  where the two disagree, Starlight's is fine inside its own components — do not
  mix a third set in.
