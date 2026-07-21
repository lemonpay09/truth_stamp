const { createClient } = require('@supabase/supabase-js');

function sendJson(res, statusCode, payload) {
  res.status(statusCode);
  res.setHeader('Content-Type', 'application/json; charset=utf-8');
  res.setHeader('Cache-Control', 'no-store');
  res.end(JSON.stringify(payload));
}

function getSupabaseClient() {
  const supabaseUrl = process.env.SUPABASE_URL;
  const supabaseServiceRoleKey = process.env.SUPABASE_SERVICE_ROLE_KEY;

  if (!supabaseUrl || !supabaseServiceRoleKey) {
    throw new Error('Supabase environment variables are not configured.');
  }

  return createClient(supabaseUrl, supabaseServiceRoleKey, {
    auth: { persistSession: false },
  });
}

function normalizeHash(queryValue) {
  if (Array.isArray(queryValue)) {
    return queryValue[0]?.trim() || '';
  }
  return typeof queryValue === 'string' ? queryValue.trim() : '';
}

module.exports = async function lookupHandler(req, res) {
  if (req.method !== 'GET') {
    res.setHeader('Allow', 'GET');
    sendJson(res, 405, { error: 'Method Not Allowed' });
    return;
  }

  const hash = normalizeHash(req.query?.hash);
  if (!hash) {
    sendJson(res, 400, { error: 'Missing hash.' });
    return;
  }

  try {
    const supabase = getSupabaseClient();
    const { data, error } = await supabase
      .from('stamps')
      .select('hash, timestamp, latitude, longitude, accuracy, created_at, thumbnail_base64, heatmap_base64, metadata_score, forgery_score, conclusion')
      .eq('hash', hash)
      .maybeSingle();

    if (error) {
      sendJson(res, 500, { error: error.message });
      return;
    }

    if (!data) {
      sendJson(res, 404, { found: false });
      return;
    }

    sendJson(res, 200, { found: true, stamp: data });
  } catch (error) {
    sendJson(res, 500, { error: error.message });
  }
};
