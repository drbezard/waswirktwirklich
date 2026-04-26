import { defineCollection, z } from 'astro:content';
import { glob } from 'astro/loaders';

const artikel = defineCollection({
  loader: glob({ pattern: '**/*.md', base: './src/content/artikel' }),
  schema: z.object({
    title: z.string(),
    slug: z.string(),
    date: z.string(),
    category: z.string(),
    excerpt: z.string(),
    image: z.string().optional(),
    draft: z.boolean().default(false),
    tags: z.array(z.string()).optional(),
    prompt: z.string().optional(),
    sources: z.array(z.string()).optional(),
    seoTitle: z.string().optional(),
    seoDescription: z.string().optional(),
  }),
});

export const collections = { artikel };
