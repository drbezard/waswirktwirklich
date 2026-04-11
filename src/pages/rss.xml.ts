import rss from '@astrojs/rss';
import { getCollection } from 'astro:content';
import type { APIContext } from 'astro';

export async function GET(context: APIContext) {
  const articles = await getCollection('artikel');
  const sorted = articles.sort(
    (a, b) => new Date(b.data.date).getTime() - new Date(a.data.date).getTime()
  );

  return rss({
    title: 'Was Wirklich Wirkt',
    description: 'Evidenzbasierte medizinische Patientenartikel – erstellt von KI, geprüft von Fachärzten.',
    site: context.site!,
    items: sorted.map((article) => ({
      title: article.data.title,
      pubDate: new Date(article.data.date),
      description: article.data.excerpt,
      link: `/artikel/${article.data.slug}/`,
      categories: [article.data.category],
    })),
  });
}
