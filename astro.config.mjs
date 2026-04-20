// @ts-check
import { defineConfig } from 'astro/config';
import tailwindcss from '@tailwindcss/vite';
import sitemap from '@astrojs/sitemap';
import vercel from '@astrojs/vercel';

export default defineConfig({
  site: 'https://waswirktwirklich.com',
  // Hybrid mode: statische Seiten standardmäßig,
  // /arzt/* und /admin/* setzen per `export const prerender = false` auf SSR
  output: 'static',
  adapter: vercel({
    webAnalytics: { enabled: false },
    imageService: false,
  }),
  vite: {
    plugins: [tailwindcss()],
  },
  integrations: [sitemap({
    // Admin- und Arzt-Bereich aus Sitemap ausschließen
    filter: (page) =>
      !page.includes('/arzt/') &&
      !page.includes('/admin/') &&
      !page.includes('/auth/'),
  })],
});
