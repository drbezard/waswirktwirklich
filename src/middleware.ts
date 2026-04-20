/**
 * Astro-Middleware: Auth-Prüfung für geschützte Bereiche.
 *
 * Läuft bei jedem SSR-Request. Statische Seiten werden nicht betroffen.
 * Fängt Fehler ab, um 500s zu vermeiden — lieber einloggen lassen als
 * eine Fehlerseite zeigen.
 */

import { defineMiddleware } from 'astro:middleware';
import { getSessionUser } from './lib/supabase/server';

const PROTECTED_PREFIXES = ['/arzt', '/admin'];

const PUBLIC_SUBROUTES = [
  '/arzt/login',
  '/arzt/callback',
  '/admin/login',
  '/admin/callback',
  '/admin/dev-login',
  '/auth/callback',
  '/auth/exchange',
  '/auth/logout',
];

export const onRequest = defineMiddleware(async (context, next) => {
  const { pathname } = context.url;

  // Auth-Endpunkte und Login-Seiten: Immer durchlassen
  if (PUBLIC_SUBROUTES.some((r) => pathname === r || pathname === r + '/')) {
    try {
      const user = await getSessionUser(context.request, context.cookies);
      context.locals.user = user ?? null;
    } catch (err) {
      console.error('[middleware] getSessionUser error on public route:', err);
      context.locals.user = null;
    }
    return next();
  }

  const needsAuth = PROTECTED_PREFIXES.some(
    (p) => pathname === p || pathname.startsWith(p + '/')
  );

  if (!needsAuth) {
    return next();
  }

  // Geschützter Bereich — Auth prüfen
  let user = null;
  try {
    user = await getSessionUser(context.request, context.cookies);
  } catch (err) {
    console.error('[middleware] getSessionUser error on protected route:', err);
    // Fehler → zum Login schicken statt 500 zeigen
  }

  if (!user) {
    const loginPath = pathname.startsWith('/admin') ? '/admin/login' : '/arzt/login';
    return context.redirect(`${loginPath}?next=${encodeURIComponent(pathname)}`);
  }

  if (pathname.startsWith('/admin') && user.role !== 'admin') {
    return context.redirect('/arzt');
  }

  context.locals.user = user;

  return next();
});
