import { defineCollection, z } from 'astro:content';
import { docsLoader } from '@astrojs/starlight/loaders';
import { docsSchema } from '@astrojs/starlight/schema';

export const collections = {
	docs: defineCollection({
		loader: docsLoader(),
		schema: docsSchema({
			extend: z.object({
				/** Mono uppercase label above the page title. Falls back to the name of
				 *  the sidebar group the page sits in. */
				eyebrow: z.string().optional(),
			}),
		}),
	}),
};
