# GitHub-Workflows nachinstallieren

Beim ersten Push dieses Branches hat GitHub die zwei Workflow-Dateien abgelehnt,
weil mein Push-Token kein `workflow`-Scope hatte. Sie liegen daher hier
als Vorlage und müssen einmalig in `.github/workflows/` verschoben werden.

## Wie installieren

**Option A — über die GitHub-Weboberfläche** (einfachste, kein lokales Git nötig):

1. https://github.com/drbezard/waswirktwirklich/new/main/.github/workflows
2. Dateiname `sync-prompts.yml`, Inhalt aus `sync-prompts.yml` hier kopieren
3. Commit (direkt auf main oder als PR auf den Feature-Branch)
4. Wiederholen für `freshness-discovery.yml`

**Option B — lokal mit Ihrem eigenen Git** (Sie haben volle Rechte):

```
mkdir -p .github/workflows
mv docs/workflows-to-install/sync-prompts.yml .github/workflows/
mv docs/workflows-to-install/freshness-discovery.yml .github/workflows/
git add .github/workflows
git commit -m "ci: add sync-prompts + freshness-discovery workflows"
git push
```

## Was die Workflows tun

- **`sync-prompts.yml`** — täglich 03:30 UTC. Holt Master-Prompts aus Supabase
  via Management-API und schreibt sie nach `prompts/*.md`. Bei Änderungen
  → automatischer Commit.
- **`freshness-discovery.yml`** — monatlich am 1. um 02:00 UTC. Findet überfällige
  Artikel (`last_freshness_check < now() - 365 days`) und legt 1–2 Refresh-Topics
  an (max. 2 pro Lauf, damit der Pool nicht überflutet wird).

## Benötigte GitHub-Secrets/Vars

Bevor die Workflows laufen können:

- **Secret** `SUPABASE_ACCESS_TOKEN` — Personal Access Token aus Supabase Dashboard
  (https://supabase.com/dashboard/account/tokens). Hat lesenden + schreibenden
  Zugriff auf die Management-API.
- **Variable** `SUPABASE_PROJECT_REF` — `qyaivjcczncckifsrrps`. Setzen unter
  Repo Settings → Secrets and variables → Actions → Variables.
  (Alternativ als Secret, der Workflow kennt beide Quellen.)

Den ersten Sync-Prompts-Lauf kann man manuell triggern unter
Actions → Sync Master-Prompts → Run workflow → main.
