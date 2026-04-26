import type { APIRoute } from 'astro';
import { getSupabaseAdminClient } from '../../../lib/supabase/admin';
import { requireManusAuth, requireNotPaused, jsonResponse, errorResponse } from '../../../lib/manus-auth';

export const prerender = false;

/**
 * POST /api/manus/upload-image
 *   Multipart-Upload eines Hero-Bildes zum Supabase-Storage-Bucket "article-images".
 *
 *   FormData:
 *     - slug:  string (Pflicht — Dateiname wird "<slug>.png")
 *     - file:  File (PNG, JPG oder WebP, max 5 MB)
 *
 *   Response 201:
 *     { url: "https://qyaivjcczncckifsrrps.supabase.co/storage/v1/object/public/article-images/<slug>.png",
 *       size_bytes: <n> }
 *
 *   Damit muss Manus KEINEN Service-Role-Key in seiner Sandbox haben — er
 *   schickt das Bild via Manus-Token an unseren Server, der nutzt dann intern
 *   den Service-Role-Key (in Vercel-Env) für den Storage-Upload.
 */

const MAX_BYTES = 5 * 1024 * 1024;
const ALLOWED = ['image/png', 'image/jpeg', 'image/webp'];

export const POST: APIRoute = async ({ request }) => {
  const auth = requireManusAuth(request);
  if (auth) return auth;

  const paused = await requireNotPaused();
  if (paused) return paused;

  let form: FormData;
  try {
    form = await request.formData();
  } catch {
    return errorResponse('Body muss multipart/form-data sein', 400);
  }

  const slug = String(form.get('slug') || '').trim();
  const file = form.get('file');

  if (!slug || !/^[a-z0-9-]+$/.test(slug)) {
    return errorResponse('slug muss kebab-case sein (a-z, 0-9, -)', 400);
  }
  if (!(file instanceof File)) {
    return errorResponse('Feld "file" fehlt oder ist keine Datei', 400);
  }
  if (file.size > MAX_BYTES) {
    return errorResponse(`Datei zu groß: ${file.size} bytes (max ${MAX_BYTES})`, 413);
  }
  if (!ALLOWED.includes(file.type)) {
    return errorResponse(`Mime-Type nicht erlaubt: ${file.type}. Erlaubt: ${ALLOWED.join(', ')}`, 415);
  }

  const ext = file.type === 'image/png' ? 'png' : file.type === 'image/jpeg' ? 'jpg' : 'webp';
  const targetPath = `${slug}.${ext}`;

  const supabase = getSupabaseAdminClient();
  const buffer = Buffer.from(await file.arrayBuffer());

  const { error: uploadError } = await supabase.storage
    .from('article-images')
    .upload(targetPath, buffer, { contentType: file.type, upsert: true });

  if (uploadError) {
    return errorResponse(`Upload fehlgeschlagen: ${uploadError.message}`, 500);
  }

  const { data: pub } = supabase.storage.from('article-images').getPublicUrl(targetPath);

  return jsonResponse(
    {
      url: pub.publicUrl,
      path: targetPath,
      size_bytes: file.size,
      content_type: file.type,
    },
    201
  );
};
