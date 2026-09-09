// @ts-check
import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';

// https://astro.build/config
export default defineConfig({
	integrations: [
		starlight({
			title: 'Rasterize',
			description: 'Documentation for Rasterize, a native macOS raster image editor.',
			logo: { src: './src/assets/rasterize-1024.png', alt: 'Rasterize' },
			favicon: '/favicon.png',
			// Boppa Llewyn theme. The @font-face rules load first so the families are
			// declared before custom.css asks for them.
			customCss: ['./src/fonts/font-face.css', './src/styles/custom.css'],
			head: [
				// The two faces above the fold. Only the `latin` subsets are preloaded;
				// `latin-ext` is fetched on demand by unicode-range.
				{
					tag: 'link',
					attrs: {
						rel: 'preload',
						href: '/fonts/IBMPlexSans-Variable-latin.woff2',
						as: 'font',
						type: 'font/woff2',
						crossorigin: 'anonymous',
					},
				},
				{
					tag: 'link',
					attrs: {
						rel: 'preload',
						href: '/fonts/CormorantGaramond-Variable-latin.woff2',
						as: 'font',
						type: 'font/woff2',
						crossorigin: 'anonymous',
					},
				},
				{ tag: 'link', attrs: { rel: 'apple-touch-icon', href: '/apple-touch-icon.png' } },
			],
			// `useStarlightUiThemeColors` is what makes the code-block chrome (frame,
			// copy button, borders) follow the theme tokens instead of the syntax theme.
			expressiveCode: {
				themes: ['github-dark-default', 'github-light'],
				useStarlightUiThemeColors: true,
				styleOverrides: {
					borderRadius: '4px',
					borderColor: 'var(--sl-color-hairline-light)',
				},
			},
			// The four places the token layer cannot reach; everything else in the
			// design is done from src/styles/custom.css.
			components: {
				SiteTitle: './src/components/SiteTitle.astro',
				ThemeSelect: './src/components/ThemeSelect.astro',
				PageTitle: './src/components/PageTitle.astro',
				Hero: './src/components/Hero.astro',
			},
			sidebar: [
				{
					label: 'Guides',
					items: [
						// Each item here is one entry in the navigation menu.
						{ slug: 'guides/example' },
					],
				},
				{
					label: 'Reference',
					items: [{ autogenerate: { directory: 'reference' } }],
				},
			],
		}),
	],
});
