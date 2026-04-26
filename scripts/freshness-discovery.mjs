/**
 * Monatlicher Lauf: findet Artikel, deren letzter Freshness-Check zu lange her ist,
 * und legt für jeden ein Refresh-Topic an.
 *
 * Läuft via GitHub Action (freshness-discovery.yml). Maximal 2 Topics pro Lauf,
 * damit der Pool nicht überflutet wird.
 */

const PROJECT_REF = process.env.SUPABASE_PROJECT_REF;
const ACCESS_TOKEN = process.env.SUPABASE_ACCESS_TOKEN;
const MAX_PER_RUN = 2;

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

// Setting holen: freshness_check_days
const settingsRows = await query(
  "SELECT value FROM public.settings WHERE key = 'freshness_check_days';"
);
const freshnessDays = parseInt(settingsRows[0]?.value ?? 365, 10);

console.log(`Freshness-Schwelle: ${freshnessDays} Tage`);

// Kandidaten finden: Artikel, die noch nie oder seit > freshnessDays Tagen geprüft wurden,
// und die nicht bereits ein offenes Refresh-Topic haben
const candidatesSql = `
  SELECT a.slug, a.title, a.last_freshness_check, a.refresh_count
  FROM public.articles a
  WHERE NOT EXISTS (
    SELECT 1 FROM public.topics t
    WHERE t.article_slug = a.slug
      AND t.type = 'refresh'
      AND t.status NOT IN ('published','discarded')
  )
  AND (
    a.last_freshness_check IS NULL
    OR a.last_freshness_check < now() - INTERVAL '${freshnessDays} days'
  )
  ORDER BY COALESCE(a.last_freshness_check, a.created_at) ASC
  LIMIT ${MAX_PER_RUN};
`;

const candidates = await query(candidatesSql);

if (candidates.length === 0) {
  console.log('Keine Artikel zur Auffrischung fällig.');
  process.exit(0);
}

console.log(`Lege ${candidates.length} Refresh-Topics an:`);

for (const a of candidates) {
  const insertSql = `
    INSERT INTO public.topics (title, description, source, type, status, article_slug, suggested_tags, notes)
    VALUES (
      ${JSON.stringify('Refresh: ' + a.title).replace(/"/g, "'")},
      ${JSON.stringify('Automatisch ausgelöste Aktualitäts-Prüfung.').replace(/"/g, "'")},
      'manus', 'refresh', 'discovered',
      ${JSON.stringify(a.slug).replace(/"/g, "'")},
      NULL,
      'Automatisch durch Freshness-Discovery angelegt.'
    )
    ON CONFLICT DO NOTHING
    RETURNING id, title;
  `;
  const result = await query(insertSql);
  if (result.length > 0) {
    console.log(`  ✓ ${a.slug}: Topic ${result[0].id}`);
  } else {
    console.log(`  ⊙ ${a.slug}: kein neues Topic (vielleicht race condition)`);
  }
}

console.log('Fertig.');
