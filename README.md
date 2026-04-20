# Was Wirkt Wirklich

Evidenzbasierte medizinische Patientenartikel – erstellt von KI, geprüft von Fachärzten.

**Live:** https://waswirktwirklich.com

## Tech Stack

- **Astro 6** – Static Site Generator
- **Tailwind CSS 4** – Styling
- **Markdown** – Artikel-Content (Content Collections)
- **Vercel** – Hosting & Deployment

## Projektstruktur

```
src/
  content/artikel/     ← Artikel als Markdown-Dateien
  layouts/             ← Base Layout (Header, Footer, SEO)
  components/          ← Wiederverwendbare Komponenten
  pages/               ← Seiten (Startseite, Artikel, Fachgebiete, Impressum)
  styles/              ← Globale CSS-Styles
```

## Neuen Artikel hinzufügen

1. Neue `.md`-Datei in `src/content/artikel/` erstellen
2. Frontmatter ausfüllen:

```yaml
---
title: "Artikeltitel"
slug: "artikel-slug"
date: "2026-04-10"
category: "Fachgebiet"
excerpt: "Kurzbeschreibung"
reviewed: false
---
```

3. Markdown-Inhalt darunter schreiben
4. Commit und Push – Vercel deployt automatisch

## Entwicklung

```bash
npm install
npm run dev      # Lokaler Dev-Server
npm run build    # Produktions-Build
npm run preview  # Build-Vorschau
```

## Deployment

Automatisch über Vercel bei jedem Push auf `main`.
