# prompts/

Spiegelung der Master-Prompts aus Supabase. **Wird automatisch täglich durch
`.github/workflows/sync-prompts.yml` aktualisiert.** Manuelle Edits hier sind
sinnlos — sie werden beim nächsten Sync überschrieben.

Quelle der Wahrheit: Tabelle `public.prompts` in Supabase. Bearbeitet wird über
`/admin/prompts/<key>` im Admin-Portal.

Versionsgeschichte:
- Audit-Log mit Diff: `public.prompt_history` (in Supabase, sichtbar im Admin)
- Git-Historie: dieser Ordner (jeder Sync = ein Commit)

Aktuelle Prompts:
- `manus_discovery.md` — wie Manus Themen findet
- `manus_drafting.md` — wie Manus Artikel-Drafts schreibt
- `claude_polishing.md` — wie Claude den Stil poliert (ohne Inhalt zu ändern)
- `manus_review_publish.md` — finaler Check + Veröffentlichung
