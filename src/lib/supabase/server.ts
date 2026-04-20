/**
 * Server-seitiger Supabase-Client für Astro SSR-Seiten.
 *
 * Astro's cookies API hat kein getAll(), deshalb parsen wir den Cookie-Header
 * direkt aus dem Request. Schreiben geht über AstroCookies.set().
 */

import { createServerClient, type CookieOptions } from '@supabase/ssr';
import type { AstroCookies } from 'astro';
import type { Database } from './types';

function getEnv() {
  const url = import.meta.env.PUBLIC_SUPABASE_URL;
  const anonKey = import.meta.env.PUBLIC_SUPABASE_ANON_KEY;

  if (!url || !anonKey) {
    console.error('[supabase] Missing environment variables:', {
      hasUrl: !!url,
      hasAnonKey: !!anonKey,
    });
    throw new Error(
      'PUBLIC_SUPABASE_URL und PUBLIC_SUPABASE_ANON_KEY müssen als Environment Variables gesetzt sein.'
    );
  }

  return { url, anonKey };
}

function parseCookieHeader(header: string | null): Array<{ name: string; value: string }> {
  if (!header) return [];
  return header
    .split(';')
    .map((c) => c.trim())
    .filter(Boolean)
    .map((c) => {
      const idx = c.indexOf('=');
      if (idx < 0) return { name: c, value: '' };
      const name = c.slice(0, idx).trim();
      const rawValue = c.slice(idx + 1).trim();
      let value = rawValue;
      try {
        value = decodeURIComponent(rawValue);
      } catch {
        value = rawValue;
      }
      return { name, value };
    });
}

export function createSupabaseServerClient(request: Request, cookies: AstroCookies) {
  const { url, anonKey } = getEnv();
  const parsedCookies = parseCookieHeader(request.headers.get('cookie'));

  return createServerClient<Database>(url, anonKey, {
    cookies: {
      getAll() {
        return parsedCookies;
      },
      setAll(cookiesToSet: Array<{ name: string; value: string; options: CookieOptions }>) {
        try {
          for (const { name, value, options } of cookiesToSet) {
            cookies.set(name, value, {
              ...options,
              httpOnly: true,
              sameSite: 'lax',
              secure: import.meta.env.PROD,
              path: '/',
            });
          }
        } catch (err) {
          console.error('[supabase] Cookie set error:', err);
        }
      },
    },
  });
}

export async function getSessionUser(request: Request, cookies: AstroCookies) {
  const supabase = createSupabaseServerClient(request, cookies);

  const { data: { user }, error: authError } = await supabase.auth.getUser();

  if (authError) {
    // AuthSessionMissingError ist normal wenn noch nicht eingeloggt
    if (!authError.message?.includes('session')) {
      console.error('[supabase] getUser error:', authError.message);
    }
    return null;
  }

  if (!user) return null;

  const { data: profile, error: profileError } = await supabase
    .from('profiles')
    .select('id, role, full_name, disabled_at')
    .eq('id', user.id)
    .single();

  if (profileError) {
    console.error('[supabase] profile query error:', profileError.message);
    return null;
  }

  if (!profile || profile.disabled_at) return null;

  return {
    id: user.id,
    email: user.email!,
    role: profile.role as 'doctor' | 'admin',
    fullName: profile.full_name,
    supabase,
  };
}

export type SessionUser = NonNullable<Awaited<ReturnType<typeof getSessionUser>>>;
