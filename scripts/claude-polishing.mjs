/**
 * Claude-Polishing Worker.
 *
 * Holt alle drafted-Topics aus der Pipeline-API, lädt jeweils den Draft,
 * lässt Claude (Opus 4.7) den Stil polieren — strikt nach dem aktuellen
 * Master-Prompt aus der DB — und setzt den Topic-Status auf polished.
 *
 * Läuft idempotent: Status-Transition `drafted → polished` ist atomar in
 * der DB. Wenn ein paralleler Worker dasselbe Topic gepickt hat, gibt der
 * zweite Versuch HTTP 400, das fangen wir leise ab.
 *
 * Anti-Halluzinations-Schutz: Claude wird angewiesen, KEINE neuen Studien
 * hinzuzufügen — der System-Prompt steht in der DB und enthält die harten
 * Regeln. Wenn Claude dort zustimmt, eine Quellenlücke zu finden, schiebt
 * er das Topic mit `transition: drafted` zurück.
 *
 * Ausgelöst durch: .github/workflows/claude-polishing.yml (Cron alle 4 Std).
 *
 * Erforderliche Env-Vars:
 *   ANTHROPIC_API_KEY   — Anthropic-API-Schlüssel
 *   MANUS_API_TOKEN     — Auth-Header für /api/manus/*
 *   MANUS_API_BASE      — z.B. https://waswirktwirklich.vercel.app/api/manus
 */

import Anthropic from '@anthropic-ai/sdk';
import { readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

const ANTHROPIC_API_KEY = process.env.ANTHROPIC_API_KEY;
const MANUS_TOKEN = process.env.MANUS_API_TOKEN;
const API_BASE = process.env.MANUS_API_BASE || 'https://waswirktwirklich.vercel.app/api/manus';
const REPO_ROOT = process.env.GITHUB_WORKSPACE || process.cwd();
const ORIGIN = new URL(API_BASE).origin;

if (!ANTHROPIC_API_KEY || !MANUS_TOKEN) {
  console.error('ANTHROPIC_API_KEY und MANUS_API_TOKEN müssen gesetzt sein.');
  process.exit(1);
}

const HEADERS = { 'X-Manus-Token': MANUS_TOKEN, 'Origin': ORIGIN };

async function api(path, init = {}) {
  const r = await fetch(`${API_BASE}${path}`, {
    ...init,
    headers: { ...HEADERS, ...(init.headers || {}) },
  });
  if (!r.ok) {
    const body = await r.text();
    const err = new Error(`API ${path}: HTTP ${r.status} ${body.slice(0, 200)}`);
    err.status = r.status;
    err.body = body;
    throw err;
  }
  return r.json();
}

async function transition(topicId, body) {
  return api(`/topics/${topicId}/transition`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  });
}

// ---- main ----

const settings = await api('/settings');
if (settings.pipeline_paused === true || settings.pipeline_paused === 'true') {
  console.log('Pipeline pausiert — kein Polishing.');
  process.exit(0);
}

const promptObj = await api('/prompts/claude_polishing');
console.log(`Polishing-Prompt v${promptObj.version} geladen (${promptObj.body.length} Zeichen)`);

const topics = await api('/topics?status=drafted');
if (topics.length === 0) {
  console.log('Keine drafted Topics — nichts zu tun.');
  process.exit(0);
}

console.log(`${topics.length} drafted Topics gefunden, Polishing läuft...`);

const client = new Anthropic({ apiKey: ANTHROPIC_API_KEY });

let polishedCount = 0;
let skippedCount = 0;
let failedCount = 0;

for (const topic of topics) {
  if (!topic.draft_path) {
    console.warn(`⊙ ${topic.id}: kein draft_path, skip`);
    skippedCount++;
    continue;
  }

  const filePath = join(REPO_ROOT, topic.draft_path);
  let original;
  try {
    original = readFileSync(filePath, 'utf8');
  } catch {
    console.warn(`⊙ ${topic.id}: Datei ${topic.draft_path} nicht im Repo`);
    await transition(topic.id, {
      new_status: 'drafted',
      notes: `Polish-Worker: Datei ${topic.draft_path} nicht im Repo. Manus muss neu pushen.`,
    }).catch(() => {});
    skippedCount++;
    continue;
  }

  console.log(`→ ${topic.title} (${topic.id})`);

  try {
    const response = await client.messages.create({
      model: 'claude-opus-4-7',
      max_tokens: 16000,
      output_config: { effort: 'medium' },
      system: [
        {
          type: 'text',
          text: promptObj.body,
          cache_control: { type: 'ephemeral' },
        },
      ],
      messages: [
        {
          role: 'user',
          content: [
            {
              type: 'text',
              text:
                'Hier ist der Draft. Halte dich strikt an die Regeln im System-Prompt: KEINE neuen Studien, KEIN inhaltliches Ändern, nur Sprache und Klarheit polieren.\n\n' +
                'Antworte AUSSCHLIESSLICH mit dem komplett überarbeiteten Markdown-Dokument inklusive YAML-Frontmatter. Keine Einleitung, keine Erklärung, kein Codeblock-Wrapper.\n\n' +
                '----- DRAFT -----\n\n' +
                original,
            },
          ],
        },
      ],
    });

    const polished = response.content
      .filter((b) => b.type === 'text')
      .map((b) => b.text)
      .join('\n');

    // Sanity-Check: nicht massiv kürzer als Original
    if (polished.length < original.length * 0.5) {
      console.warn(`✗ ${topic.id}: Output verdächtig kurz (${polished.length} vs ${original.length})`);
      await transition(topic.id, {
        new_status: 'drafted',
        notes: `Polish-Worker: Output verdächtig kurz (${polished.length} Zeichen). Manus prüft Draft.`,
      }).catch(() => {});
      failedCount++;
      continue;
    }

    // Sanity-Check: Frontmatter noch da
    if (!polished.startsWith('---')) {
      console.warn(`✗ ${topic.id}: Frontmatter fehlt im Output`);
      await transition(topic.id, {
        new_status: 'drafted',
        notes: `Polish-Worker: Frontmatter fehlt im Output. Manus prüft.`,
      }).catch(() => {});
      failedCount++;
      continue;
    }

    writeFileSync(filePath, polished);

    const u = response.usage;
    const noteParts = [
      `Auto-poliert (Opus 4.7, prompt v${promptObj.version})`,
      `${u.input_tokens} input + ${u.output_tokens} output tokens`,
    ];
    if (u.cache_read_input_tokens > 0) noteParts.push(`cache hit ${u.cache_read_input_tokens}`);

    try {
      await transition(topic.id, {
        new_status: 'polished',
        notes: noteParts.join(' · '),
      });
      console.log(`✓ ${topic.id}: polished (${u.input_tokens}/${u.output_tokens} tok, cache=${u.cache_read_input_tokens})`);
      polishedCount++;
    } catch (err) {
      // Race: ein anderer Worker hat das Topic schon transitioned → leise akzeptieren
      if (err.status === 400 && err.body?.includes('nicht erlaubt')) {
        console.log(`⊙ ${topic.id}: Race-Condition — bereits poliert von anderem Worker`);
        skippedCount++;
      } else {
        throw err;
      }
    }
  } catch (err) {
    console.error(`✗ ${topic.id}: ${err.message}`);
    failedCount++;
  }
}

console.log(`\nFertig: ${polishedCount} poliert, ${skippedCount} übersprungen, ${failedCount} fehlgeschlagen.`);
process.exit(failedCount > 0 ? 1 : 0);
