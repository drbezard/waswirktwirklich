import type { APIRoute } from 'astro';
import { getSupabaseAdminClient } from '../../../lib/supabase/admin';
import { requireManusAuth, requireNotPaused, jsonResponse, errorResponse } from '../../../lib/manus-auth';

export const prerender = false;

/**
 * GET /api/manus/topics?status=discovered&limit=20
 *   Liefert Topics gefiltert nach Status (default: alle nicht-finalen)
 *
 * POST /api/manus/topics
 *   Legt neuen Topic an (source: 'manus' wenn nicht angegeben)
 *   Body: { title, description?, type?, article_slug?, source_url?, suggested_tags? }
 */

export const GET: APIRoute = async ({ request, url }) => {
  const auth = requireManusAuth(request);
  if (auth) return auth;

  const supabase = getSupabaseAdminClient();
  const status = url.searchParams.get('status');
  const type = url.searchParams.get('type');
  const limit = Math.min(parseInt(url.searchParams.get('limit') || '50'), 200);

  let q = supabase
    .from('topics')
    .select('id, title, description, source, type, status, article_slug, draft_path, suggested_tags, source_url, created_at, updated_at, notes')
    .order('created_at', { ascending: false })
    .limit(limit);

  if (status) q = q.eq('status', status);
  if (type) q = q.eq('type', type);

  const { data, error } = await q;
  if (error) return errorResponse(error.message, 500);
  return jsonResponse(data ?? []);
};

export const POST: APIRoute = async ({ request }) => {
  const auth = requireManusAuth(request);
  if (auth) return auth;

  const paused = await requireNotPaused();
  if (paused) return paused;

  let body: any;
  try {
    body = await request.json();
  } catch {
    return errorResponse('Body muss JSON sein', 400);
  }

  if (!body.title || typeof body.title !== 'string') {
    return errorResponse('Feld "title" ist Pflicht', 400);
  }

  const supabase = getSupabaseAdminClient();

  // Duplikat-Erkennung: ähnlicher Titel im offenen Pool?
  const { data: existing } = await supabase
    .from('topics')
    .select('id, title')
    .ilike('title', body.title)
    .not('status', 'in', '(published,discarded)')
    .limit(1);

  const duplicateOf = existing && existing.length > 0 ? existing[0].id : null;

  const insert = {
    title: body.title,
    description: body.description ?? null,
    source: body.source ?? 'manus',
    type: body.type ?? 'new',
    status: 'discovered',
    article_slug: body.article_slug ?? null,
    source_url: body.source_url ?? null,
    suggested_tags: body.suggested_tags ?? null,
    duplicate_of_id: duplicateOf,
    notes: duplicateOf ? `Duplikat-Verdacht zu Topic ${duplicateOf}` : null,
  };

  const { data, error } = await supabase
    .from('topics')
    .insert(insert)
    .select()
    .single();

  if (error) return errorResponse(error.message, 500);
  return jsonResponse(data, 201);
};
