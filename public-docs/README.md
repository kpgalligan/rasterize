# Rasterize docs

The public documentation site for Rasterize, built with [Astro](https://astro.build)
and [Starlight](https://starlight.astro.build).

## Commands

Run from `public-docs/`:

| Command | Action |
| :--- | :--- |
| `npm install` | Install dependencies |
| `npm run dev` | Start the dev server at `localhost:4321` |
| `npm run build` | Build the production site to `./dist/` |
| `npm run preview` | Preview the built site |
| `npm run astro ...` | Run CLI commands like `astro add`, `astro check` |

Pages are `.md`/`.mdx` files under `src/content/docs/`; each one is a route named
after its path. Images go in `src/assets/`, static files in `public/`.

## Theme

The site wears the **Boppa Llewyn** design system — warm-ebony neutrals with a
cream light surface, brass accent, Cormorant Garamond display type, IBM Plex
Sans/Mono, sharp corners and hairlines instead of shadows. The handoff it was
built from is in `../designs/design_handoff_starlight_theme/`.

| Where | What |
| :--- | :--- |
| `src/styles/custom.css` | The theme. Maps the `--bl-*` design tokens onto Starlight's `--sl-*` properties, then restyles the components the token layer cannot reach. Unlayered, so it wins over every Starlight cascade layer. |
| `src/fonts/font-face.css` | `@font-face` rules for the three families, split by `unicode-range`. |
| `public/fonts/` | Self-hosted WOFF2 (`latin` and `latin-ext` subsets from Google Fonts). Licences in `public/fonts/OFL.txt`. |
| `src/components/` | The four component overrides — `SiteTitle` (wordmark and version badge), `ThemeSelect` (two-state toggle), `PageTitle` (eyebrow and description), `Hero` (eyebrow). |
| `src/site.ts` | The version shown in the header badge. Keep in step with `CFBundleShortVersionString` in the repo's `project.yml`. |

Every page may set an `eyebrow` in its frontmatter — the mono uppercase label
above the title. Without one, a page uses the name of the sidebar group it sits in.

Prefer `custom.css` over a new component override: unlayered CSS reaches almost
everything, and each override is a copy of Starlight markup that has to be
re-checked on upgrade.
