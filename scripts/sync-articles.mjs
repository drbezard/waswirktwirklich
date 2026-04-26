/**
 * Sync der Markdown-Artikel nach Supabase `articles`-Tabelle.
 *
 * Läuft automatisch vor jedem `astro build` (siehe package.json > scripts.build).
 * Liest alle Dateien aus src/content/artikel/*.md, parsed das Frontmatter und
 * upsertet slug/title/category/excerpt/image_url in public.articles.
 *
 * Best-effort: Fehler hier brechen den Build nicht ab — der Sync kann beim
 * nächsten Deploy nachziehen, solange die Markdown-Datei existiert.
 */

import { readFileSync, readdirSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import matter from 'gray-matter';
import { createClient } from '@supabase/supabase-js';

const __dirname = dirname(fileURLToPath(import.meta.url));
const ARTICLES_DIR = join(__dirname, '..', 'src', 'content', 'artikel');

const SUPABASE_URL = process.env.PUBLIC_SUPABASE_URL;
const SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;

if (!SUPABASE_URL || !SERVICE_ROLE_KEY) {
  console.warn('[sync-articles] PUBLIC_SUPABASE_URL oder SUPABASE_SERVICE_ROLE_KEY nicht gesetzt — Sync übersprungen.');
  process.exit(0);
}

const supabase = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, {
  auth: { persistSession: false, autoRefreshToken: false },
});

const files = readdirSync(ARTICLES_DIR).filter((f) => f.endsWith('.md'));
console.log(`[sync-articles] ${files.length} Markdown-Artikel gefunden.`);

const rows = [];
for (const file of files) {
  const raw = readFileSync(join(ARTICLES_DIR, file), 'utf8');
  const { data } = matter(raw);

  if (!data.slug || !data.title || !data.category) {
    console.warn(`[sync-articles] ${file}: slug/title/category fehlt, überspringe.`);
    continue;
  }

  if (data.draft === true) {
    console.log(`[sync-articles] ${file}: draft:true, nicht synchronisiert.`);
    continue;
  }

  rows.push({
    slug: String(data.slug),
    title: String(data.title),
    category: String(data.category),
    excerpt: data.excerpt ? String(data.excerpt) : null,
    image_url: data.image ? String(data.image) : null,
    tags: Array.isArray(data.tags) ? data.tags : null,
  });
}

if (rows.length === 0) {
  console.log('[sync-articles] Keine Zeilen zu syncen.');
  process.exit(0);
}

const { error } = await supabase
  .from('articles')
  .upsert(rows, { onConflict: 'slug' });

if (error) {
  console.warn(`[sync-articles] Upsert fehlgeschlagen: ${error.message} — Build läuft trotzdem weiter.`);
  process.exit(0);
}

console.log(`[sync-articles] ${rows.length} Artikel synchronisiert.`);
