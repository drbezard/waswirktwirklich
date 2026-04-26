/**
 * Tägliche Sync der Master-Prompts aus Supabase ins Repo.
 *
 * Läuft via GitHub Action (sync-prompts.yml). Holt jede Zeile aus prompts-Tabelle,
 * schreibt sie als Markdown-Datei nach prompts/<key>.md mit YAML-Frontmatter.
 *
 * Wenn sich Inhalt geändert hat → der Workflow committet + pusht.
 */

import { writeFileSync, readFileSync, existsSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const PROMPTS_DIR = join(__dirname, '..', 'prompts');

const PROJECT_REF = process.env.SUPABASE_PROJECT_REF;
const ACCESS_TOKEN = process.env.SUPABASE_ACCESS_TOKEN;

if (!PROJECT_REF || !ACCESS_TOKEN) {
  console.error('SUPABASE_PROJECT_REF und SUPABASE_ACCESS_TOKEN müssen gesetzt sein.');
  process.exit(1);
}

async function query(sql) {
  const res = await fetch(`https://api.supabase.com/v1/projects/${PROJECT_REF}/database/query`, {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${ACCESS_TOKEN}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({ query: sql }),
  });
  if (!res.ok) throw new Error(`Supabase API: ${res.status} ${await res.text()}`);
  return res.json();
}

const rows = await query('SELECT key, title, description, body, version, updated_at FROM public.prompts ORDER BY key;');

console.log(`Gefunden: ${rows.length} Prompts`);

let changedCount = 0;

for (const row of rows) {
  const filePath = join(PROMPTS_DIR, `${row.key}.md`);

  const frontmatter = [
    '---',
    `key: ${row.key}`,
    `title: ${JSON.stringify(row.title)}`,
    row.description ? `description: ${JSON.stringify(row.description)}` : null,
    `version: ${row.version}`,
    `updated_at: ${row.updated_at}`,
    `synced_at: ${new Date().toISOString()}`,
    '---',
    '',
  ].filter(Boolean).join('\n');

  const content = `${frontmatter}\n${row.body}\n`;

  let existing = '';
  if (existsSync(filePath)) {
    existing = readFileSync(filePath, 'utf8');
  }

  // Nur Body vergleichen — synced_at ändert sich immer, das soll keinen Commit auslösen
  const existingBody = existing.split('---\n').slice(2).join('---\n').trim();
  const newBody = row.body.trim();

  if (existingBody !== newBody) {
    writeFileSync(filePath, content);
    console.log(`✓ ${row.key} (v${row.version})`);
    changedCount++;
  } else {
    console.log(`⊙ ${row.key} (unverändert)`);
  }
}

console.log(`\nFertig: ${changedCount} von ${rows.length} Prompts geändert.`);
