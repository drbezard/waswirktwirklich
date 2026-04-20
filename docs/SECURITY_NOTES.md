# Security Notes

Dokumentiert bekannte Sicherheitsthemen und Entscheidungen.

## Bekannte npm-Vulnerabilities

### path-to-regexp ReDoS (GHSA-9wv6-86v2-598j)

**Status**: Bekannt, Risiko akzeptiert für diese Anwendung.

**Paket**: `@vercel/routing-utils` → `path-to-regexp` (transitive Abhängigkeit via `@astrojs/vercel`)

**Was es ist**: Regex Denial of Service — ein Angreifer könnte eine extrem lange oder hinterhältig konstruierte URL schicken, die den Regex-Parser lange beschäftigt.

**Warum für uns nicht kritisch**:
- Die betroffene Funktion wird nur beim Build benutzt (Vercel generiert Routing-Config), nicht bei jedem Request
- Wir haben keine User-steuerbaren URLs, die durch path-to-regexp laufen
- Vercel's Infrastruktur hat zusätzliche Schutzmechanismen (Request-Timeouts, Rate Limiting)

**Wann neu bewerten**: Wenn `@vercel/routing-utils` ein Upstream-Update bekommt, das die Abhängigkeit ersetzt.

**Quellen**:
- https://github.com/advisories/GHSA-9wv6-86v2-598j

## Secret-Handling

- **`SUPABASE_SERVICE_ROLE_KEY`** ist NIEMALS im Browser-Bundle
- Umgebungsvariablen auf Vercel sind verschlüsselt
- Nach jedem Chat-Austausch von Keys ROTIEREN wir sie in Supabase
- `.env.local` ist in `.gitignore`

## Auth-Sicherheit

- Magic Links sind zeitlich begrenzt (1 Stunde, Supabase-default)
- Session-Cookies: httpOnly, Secure, SameSite=Lax
- CSRF-Schutz: Astro's Middleware prüft Origin-Header bei POST
- Admin-Aktionen loggen IP-Adresse in `audit_log`

## Datenbank-Sicherheit

- Row-Level Security auf **allen** Tabellen aktiv
- Kritische Aktionen (verify, revoke, assign) über SECURITY DEFINER-Funktionen
- Audit-Log ist append-only (keine UPDATE/DELETE-Policies)
- Service-Role-Key nur auf Server verwendet, nie im Client

## DSGVO

- Supabase-Region: EU (Frankfurt)
- Daten-Minimierung: Nur notwendige Felder
- Recht auf Löschung: implementiert via Admin-Funktion (anonymisiert Audit-Einträge statt zu löschen, wegen §257 HGB Aufbewahrungspflicht bei Zahlungsdaten)
- AV-Verträge: Supabase (signiert im Dashboard), Stripe (später)
