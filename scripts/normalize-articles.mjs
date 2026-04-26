/**
 * Format-Normalisierung der 15 Bestands-Artikel.
 *
 * Macht:
 *   1) Smart Quotes („" → " etc.) in HTML-Class-Attributen reparieren
 *   2) Tags ins Frontmatter setzen (kuratiertes Mapping unten)
 *
 * Inhaltliche Substanz wird NICHT angefasst — nur Struktur/Frontmatter.
 *
 * Usage:
 *   node scripts/normalize-articles.mjs
 */

import { readFileSync, writeFileSync, readdirSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import matter from 'gray-matter';

const __dirname = dirname(fileURLToPath(import.meta.url));
const ARTICLES_DIR = join(__dirname, '..', 'src', 'content', 'artikel');

// Kuratiertes Tag-Mapping pro Artikel-Slug
const TAGS_BY_SLUG = {
  'augenlaser-operation-was-die-studien-wirklich-zeigen': ['augenheilkunde','auge','operation'],
  'bandscheibenvorfall-op-vs-konservativ':                ['orthopaedie','ruecken','wirbelsaeule','operation'],
  'grauer-star-katarakt-op-linse-evidenz':                ['augenheilkunde','auge','operation'],
  'hyaluronsaeure-knie-arthrose-evidenz':                 ['orthopaedie','knie','arthrose','injektion','igel','placebo-kontrolliert'],
  'isotretinoin-akne-evidenz':                            ['dermatologie','akne','medikament'],
  'kreuzbandriss-op-physiotherapie-evidenz':              ['orthopaedie','knie','operation'],
  'meniskusriss-op-vs-physiotherapie':                    ['orthopaedie','knie','operation','placebo-kontrolliert'],
  'neurodermitis-cortison-angst-evidenz':                 ['dermatologie','medikament'],
  'protonenpumpenhemmer-langzeiteinnahme-evidenz':        ['innere-medizin','ppi','medikament'],
  'rueckenschmerzen-mrt-bildgebung-evidenz':              ['orthopaedie','ruecken','wirbelsaeule','screening'],
  'schulter-impingement-op-evidenz':                      ['orthopaedie','schulter','operation','placebo-kontrolliert'],
  'schulter-impingement-subakromiale-dekompression':      ['orthopaedie','schulter','operation','placebo-kontrolliert'],
  'statine-cholesterin-primaerpraevention-evidenz':       ['kardiologie','cholesterin','medikament','leitlinie'],
  'vitamin-d-supplementierung-evidenz':                   ['innere-medizin','vitamin-d','supplement','placebo-kontrolliert'],
  'vorhofflimmern-katheterablation-evidenz':              ['kardiologie','herz','operation'],
};

function fixSmartQuotesInHtml(text) {
  // Innerhalb von HTML-Tag-Attributen (class=, id=, src=, href=, alt=) curly → straight
  return text.replace(/(<[^>]*?(?:class|id|src|href|alt)=)([„"""])([^"""„]*?)([""""])/g,
    (_m, prefix, _open, content, _close) => `${prefix}"${content}"`);
}

const files = readdirSync(ARTICLES_DIR).filter((f) => f.endsWith('.md'));
let changedCount = 0;

for (const file of files) {
  const path = join(ARTICLES_DIR, file);
  const raw = readFileSync(path, 'utf8');
  const parsed = matter(raw);
  const slug = parsed.data.slug;

  const desiredTags = TAGS_BY_SLUG[slug];
  let changed = false;

  // 1) Tags setzen, wenn fehlen oder anders
  if (desiredTags && JSON.stringify(parsed.data.tags) !== JSON.stringify(desiredTags)) {
    parsed.data.tags = desiredTags;
    changed = true;
  }

  // 2) Smart Quotes in HTML-Tags reparieren
  const fixedContent = fixSmartQuotesInHtml(parsed.content);
  if (fixedContent !== parsed.content) {
    parsed.content = fixedContent;
    changed = true;
  }

  if (changed) {
    const out = matter.stringify(parsed.content, parsed.data);
    writeFileSync(path, out);
    console.log(`✓ ${file}`);
    changedCount++;
  } else {
    console.log(`⊙ ${file} (keine Änderungen)`);
  }
}

console.log(`\nFertig: ${changedCount} von ${files.length} Artikeln aktualisiert.`);
