const cors = require('cors');
const { createClient } = require('@supabase/supabase-js');

const corsMiddleware = cors({
  methods: ['POST', 'OPTIONS'],
  origin: true,
});

function runMiddleware(req, res, middleware) {
  return new Promise((resolve, reject) => {
    middleware(req, res, (result) => {
      if (result instanceof Error) {
        reject(result);
        return;
      }

      resolve(result);
    });
  });
}

function sendJson(res, statusCode, payload) {
  res.status(statusCode);
  res.setHeader('Content-Type', 'application/json; charset=utf-8');
  res.end(JSON.stringify(payload));
}

function getSupabaseClient() {
  const supabaseUrl = process.env.SUPABASE_URL;
  const supabaseServiceRoleKey = process.env.SUPABASE_SERVICE_ROLE_KEY;

  if (!supabaseUrl || !supabaseServiceRoleKey) {
    throw new Error('Supabase environment variables are not configured.');
  }

  return createClient(supabaseUrl, supabaseServiceRoleKey, {
    auth: {
      persistSession: false,
    },
  });
}

function parseRequestBody(req) {
  if (!req.body) {
    return {};
  }

  if (typeof req.body === 'string') {
    return JSON.parse(req.body);
  }

  return req.body;
}

module.exports = async function uploadHandler(req, res) {
  await runMiddleware(req, res, corsMiddleware);

  if (req.method === 'OPTIONS') {
    res.status(204).end();
    return;
  }

  if (req.method !== 'POST') {
    res.setHeader('Allow', 'POST, OPTIONS');
    sendJson(res, 405, { error: 'Method Not Allowed' });
    return;
  }

  let body;
  try {
    body = parseRequestBody(req);
  } catch (error) {
    sendJson(res, 400, { error: `Invalid JSON body: ${error.message}` });
    return;
  }

  const hash = typeof body.hash === 'string' ? body.hash.trim() : '';
  const timestamp = typeof body.timestamp === 'string' ? body.timestamp.trim() : '';
  const latitude = body.latitude;
  const longitude = body.longitude;
  const accuracy = body.accuracy;

  if (!hash || !timestamp || latitude == null || longitude == null || accuracy == null) {
    sendJson(res, 400, {
      error: 'Missing required fields: hash, timestamp, latitude, longitude, accuracy.',
    });
    return;
  }

  try {
    const supabase = getSupabaseClient();
    const { data, error } = await supabase
      .from('stamps')
      .upsert(
        {
          hash,
          timestamp,
          latitude: String(latitude),
          longitude: String(longitude),
          accuracy: String(accuracy),
        },
        { onConflict: 'hash' }
      )
      .select()
      .single();

    if (error) {
      sendJson(res, 500, { error: error.message });
      return;
    }

    sendJson(res, 200, {
      ok: true,
      stamp: data,
    });
  } catch (error) {
    sendJson(res, 500, {
      error: error.message,
    });
  }
};
