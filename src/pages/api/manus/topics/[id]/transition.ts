import type { APIRoute } from 'astro';
import { getSupabaseAdminClient } from '../../../../../lib/supabase/admin';
import { requireManusAuth, requireNotPaused, jsonResponse, errorResponse } from '../../../../../lib/manus-auth';

export const prerender = false;

/**
 * POST /api/manus/topics/{id}/transition
 *   Body: { new_status: 'drafted'|'polished'|'published'|'discarded',
 *           notes?, draft_path?, article_slug? (bei publish), tags? (bei publish) }
 *
 * Erlaubte Übergänge:
 *   discovered → drafted, discarded
 *   drafted    → polished, drafted (zurückwerfen), discarded
 *   polished   → published, drafted (zurück an Manus), discarded
 *
 * Sonderfall publish:
 *   - Bei type=refresh wird die RPC publish_refresh() aufgerufen (revoked
 *     alte Verifikationen, Article-Counter hoch, Status auf published).
 *   - Bei type=new/revision: setzt article_slug, status=published, published_at.
 */

const ALLOWED_TRANSITIONS: Record<string, string[]> = {
  discovered: ['drafted', 'discarded'],
  drafted:    ['polished', 'drafted', 'discarded'],
  polished:   ['published', 'drafted', 'discarded'],
  published:  [],
  discarded:  [],
};

export const POST: APIRoute = async ({ request, params }) => {
  const auth = requireManusAuth(request);
  if (auth) return auth;

  const paused = await requireNotPaused();
  if (paused) return paused;

  const topicId = params.id;
  if (!topicId) return errorResponse('Topic-ID fehlt', 400);

  let body: any;
  try {
    body = await request.json();
  } catch {
    return errorResponse('Body muss JSON sein', 400);
  }

  const newStatus = body.new_status;
  if (!newStatus || typeof newStatus !== 'string') {
    return errorResponse('Feld "new_status" ist Pflicht', 400);
  }

  const supabase = getSupabaseAdminClient();

  // Aktuellen Topic laden für Übergangs-Check
  const { data: topic, error: loadErr } = await supabase
    .from('topics')
    .select('id, status, type, article_slug')
    .eq('id', topicId)
    .single();

  if (loadErr || !topic) {
    return errorResponse('Topic nicht gefunden', 404);
  }

  const allowed = ALLOWED_TRANSITIONS[topic.status] ?? [];
  if (!allowed.includes(newStatus)) {
    return errorResponse(
      `Übergang ${topic.status} → ${newStatus} nicht erlaubt. Möglich: ${allowed.join(', ') || '(keiner)'}`,
      400
    );
  }

  // Pre-Update-Felder mitschreiben (draft_path bei drafted, article_slug bei published)
  const update: any = {};
  if (newStatus === 'drafted' && body.draft_path) update.draft_path = body.draft_path;
  if (newStatus === 'published' && body.article_slug) update.article_slug = body.article_slug;

  if (Object.keys(update).length > 0) {
    const { error } = await supabase.from('topics').update(update).eq('id', topicId);
    if (error) return errorResponse(error.message, 500);
  }

  // Sonderfall: Refresh-Publish
  if (newStatus === 'published' && topic.type === 'refresh') {
    const { data: result, error } = await supabase.rpc('publish_refresh', {
      p_topic_id: topicId,
      p_actor_id: null,
    });
    if (error) return errorResponse(error.message, 500);
    return jsonResponse(result);
  }

  // Bei Publish von neuen Artikeln: Tags in articles übernehmen
  if (newStatus === 'published' && Array.isArray(body.tags) && body.tags.length > 0) {
    const slug = body.article_slug ?? topic.article_slug;
    if (slug) {
      await supabase.from('articles').update({ tags: body.tags }).eq('slug', slug);
    }
  }

  // Standard-Status-Wechsel via RPC (mit Audit)
  const { data: result, error } = await supabase.rpc('transition_topic_status', {
    p_topic_id: topicId,
    p_new_status: newStatus,
    p_actor_id: null,
    p_notes: body.notes ?? null,
  });

  if (error) return errorResponse(error.message, 500);
  return jsonResponse(result);
};
