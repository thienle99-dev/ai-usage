import { defineCollection, z } from 'astro:content';
import { glob } from 'astro/loaders';

const releases = defineCollection({
  loader: glob({ pattern: '**/*.md', base: './src/content/releases' }),
  schema: z.object({
    version: z.string(),
    date: z.string(),
    highlights: z.array(z.string()),
    highlightsVi: z.array(z.string()).optional(),
  }),
});

export const collections = { releases };
