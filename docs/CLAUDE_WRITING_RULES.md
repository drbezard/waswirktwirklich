# Claude-Schreibregeln

Diese Datei beschreibt, wie Claude in der Pipeline arbeitet. Claude hat **eine** Aufgabe:
Manus-Drafts sprachlich polieren, ohne Inhalt zu ändern.

## Die zentrale Regel

> **Claude darf in einem Draft KEINE Studie zitieren, ergänzen oder ändern, deren
> `id` nicht im YAML-Frontmatter unter `sources:` steht.**

Diese Regel ist nicht verhandelbar. Sie ist der Anti-Halluzinations-Schutz der Pipeline.
Manus hat Live-Recherche-Zugang und prüft DOIs vor dem Eintrag in `sources:`. Claude
hat keinen Live-Zugang und kann ohne diesen Schutz erfundene Quellen produzieren.

## Wann Claude läuft

Wenn ein Topic in Supabase Status `drafted` hat. Claude wird typischerweise lokal
(im Terminal über Claude Code) oder via API ausgelöst.

## Schritt 1 — Aktuellen Polishing-Prompt holen

**Vor jedem Polish-Lauf** holt Claude den aktuellen Prompt:

```
GET https://waswirktwirklich.com/api/manus/prompts/claude_polishing
Header: X-Manus-Token: <MANUS_API_TOKEN>
```

Antwort enthält Body, Version, Datum. Claude arbeitet **nach diesem Body**, nicht
nach Erinnerung. Wenn der Admin den Prompt im Editor geändert hat, wirkt das sofort.

## Schritt 2 — Draft-Datei laden

Pfad steht im Topic: `topic.draft_path` (z.B. `src/content/drafts/<slug>.md`).

Lese die Datei vollständig, parse Frontmatter und Body separat (gray-matter o.ä.).

## Schritt 3 — Polieren (was erlaubt ist)

- Lange Schachtelsätze in 2–3 kürzere zerlegen
- Wiederholungen entfernen
- Reihenfolge der Absätze anpassen, wenn der Lesefluss leidet
- Alarmistische / marketinghafte Formulierungen neutralisieren
- Übergänge zwischen Abschnitten glätten
- Fachbegriff-Erklärungen prüfen: kommt sie beim ersten Auftreten?
- Markdown/HTML-Korrektheit prüfen — jede `<div class="studie">` geschlossen, etc.
- Rechtschreibung, Kommata, Tippfehler

## Schritt 4 — Was Claude **nicht** tut

- **Keine** Studie hinzufügen, die nicht in `sources:` steht.
- **Keine** Studienzahlen ändern (Effektgrößen, Sample-Sizes, p-Werte), auch wenn
  einem Claude andere Zahlen aus dem Training bekannt sind.
- **Keine** Quellenliste erweitern oder kürzen.
- **Keine** inhaltlichen Empfehlungen umkippen oder relativieren.
- **Keine** Tags ändern.
- Frontmatter-Felder ausschließlich stilistisch anpassen: `excerpt`, `seoDescription`, `seoTitle`.
  Niemals: `title` (außer Tippfehler), `slug`, `date`, `category`, `image`, `tags`, `sources`, `prompt`, `draft`.

## Schritt 5 — Was bei Quellenlücken zu tun ist

Wenn Claude beim Polieren Folgendes bemerkt:

1. Eine Behauptung im Body referenziert keine Studie aus `sources:`.
2. Eine Studie wird zitiert, deren `id` nicht in `sources:` ist.
3. Eine DOI ist `doi_verified: false`, wird aber im Body zitiert.

→ Claude **darf nichts ergänzen**. Stattdessen:

```
POST https://waswirktwirklich.com/api/manus/topics/<id>/transition
Header: X-Manus-Token: <MANUS_API_TOKEN>
Body:   {"new_status": "drafted", "notes": "Quellenlücke: <konkret was fehlt>"}
```

Topic geht zurück auf `drafted`. Manus muss nachrecherchieren.

## Schritt 6 — Nach erfolgreichem Polish

1. Datei zurückschreiben nach `src/content/drafts/<slug>.md`.
2. Topic-Status setzen:

```
POST https://waswirktwirklich.com/api/manus/topics/<id>/transition
Header: X-Manus-Token: <MANUS_API_TOKEN>
Body:   {"new_status": "polished"}
```

3. Push via Git (Feature-Branch oder direkt nach Workflow-Setup).

## Stilrichtlinien

Studieren der existierenden 15 Artikel (`src/content/artikel/*.md`) zeigt den Ziel-Ton:

- Sachlich, präzise. Nicht polemisch.
- Direkt-kritisch: wenn die Evidenz schwach ist, sagen wir es ohne Abschwächung.
- Sie-Form, deutsch.
- Patienten als mündige Erwachsene behandeln, keine Bevormundung.
- Kein Marketing-Sprech, keine Superlative.
- Fachbegriffe beim ersten Auftreten in Klammern erklären.
- Bei Kontroversen beide Seiten darstellen.

## Verbotene Formulierungen

- „Revolutionär", „bahnbrechend", „durchbruchhaft"
- „Neue Studien zeigen…" ohne Studie zu nennen
- „Experten empfehlen…" ohne konkrete Leitlinie
- „Bis zu X% Erfolg" ohne Quelle
- „In klinischen Tests bewährt"
- „Schonend", „natürlich", wenn nicht durch Quelle belegt
- Heilsversprechen jeder Art

## Pause

Wenn `pipeline_paused: true` (`GET /api/manus/settings`): Claude macht nichts, loggt
nur die Pause. Die write-Endpoints würden eh mit 423 Locked antworten.

## Pflicht-Verständnis

Claude muss vor dem Polishen sicher sein, dass er die Regeln verstanden hat. Bei
Unsicherheit: in der Notiz transparent machen, lieber zurück an Manus geben als
spekulieren.
