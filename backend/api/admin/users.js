const cors = require('cors');
const jwt = require('jsonwebtoken');
const { createClient } = require('@supabase/supabase-js');

const corsMiddleware = cors({
  methods: ['GET', 'POST', 'OPTIONS'],
  origin: true,
});

const ROLE_OPTIONS = ['Free', 'Pro', 'Plus', 'Enterprise', 'Founder'];

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

function parseRequestBody(req) {
  if (!req.body) return {};
  if (typeof req.body === 'string') return JSON.parse(req.body);
  return req.body;
}

function getSupabaseServiceClient() {
  const supabaseUrl = process.env.SUPABASE_URL;
  const serviceRole = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!supabaseUrl || !serviceRole) {
    throw new Error('Missing SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY.');
  }
  return createClient(supabaseUrl, serviceRole, {
    auth: { persistSession: false },
  });
}

function getAdminConfig() {
  const password = process.env.ADMIN_PASSWORD;
  if (!password) {
    throw new Error('Missing ADMIN_PASSWORD.');
  }
  return {
    password,
    jwtSecret: process.env.ADMIN_JWT_SECRET || `${password}-truthstamp-admin`,
  };
}

function issueAdminToken() {
  const { jwtSecret } = getAdminConfig();
  return jwt.sign(
    {
      scope: 'admin',
      aud: 'truthstamp-admin',
    },
    jwtSecret,
    { expiresIn: '8h' },
  );
}

function verifyAdminToken(req) {
  const auth = req.headers.authorization || '';
  if (!auth.startsWith('Bearer ')) {
    throw new Error('Missing bearer token');
  }
  const token = auth.slice('Bearer '.length).trim();
  const { jwtSecret } = getAdminConfig();
  return jwt.verify(token, jwtSecret);
}

async function listUsers(service) {
  const { data: authData, error: authError } = await service.auth.admin.listUsers({
    page: 1,
    perPage: 1000,
  });
  if (authError) {
    throw authError;
  }
  const users = authData?.users || [];

  const { data: roleRows } = await service
    .from('app_users')
    .select('user_id, role, phone_number');
  const roleMap = new Map((roleRows || []).map((row) => [row.user_id, row]));

  return users.map((user) => {
    const roleRow = roleMap.get(user.id);
    return {
      userId: user.id,
      phoneNumber: roleRow?.phone_number || user.phone || '',
      registeredAt: user.created_at,
      role: roleRow?.role || 'Free',
    };
  });
}

async function updateUserRole(service, userId, role) {
  if (!ROLE_OPTIONS.includes(role)) {
    throw new Error(`Invalid role. Allowed: ${ROLE_OPTIONS.join(', ')}`);
  }
  if (typeof userId !== 'string' || !userId.trim()) {
    throw new Error('Missing userId');
  }

  const cleanUserId = userId.trim();
  const { data: authUserData, error: authUserError } =
    await service.auth.admin.getUserById(cleanUserId);
  if (authUserError || !authUserData?.user) {
    throw new Error(authUserError?.message || 'User not found in auth.users');
  }
  const phoneNumber = authUserData.user.phone || '';

  const { error: upsertError } = await service.from('app_users').upsert(
    {
      user_id: cleanUserId,
      phone_number: phoneNumber,
      role,
    },
    { onConflict: 'user_id' },
  );
  if (upsertError) {
    throw upsertError;
  }

  await service.auth.admin
    .updateUserById(cleanUserId, {
      user_metadata: {
        ...(authUserData.user.user_metadata || {}),
        role,
      },
    })
    .catch(() => {});
}

module.exports = async function adminUsersHandler(req, res) {
  await runMiddleware(req, res, corsMiddleware);

  if (req.method === 'OPTIONS') {
    res.status(204).end();
    return;
  }

  if (!['GET', 'POST'].includes(req.method)) {
    res.setHeader('Allow', 'GET, POST, OPTIONS');
    sendJson(res, 405, { error: 'Method Not Allowed' });
    return;
  }

  let body = {};
  if (req.method === 'POST') {
    try {
      body = parseRequestBody(req);
    } catch (error) {
      sendJson(res, 400, { error: `Invalid JSON body: ${error.message}` });
      return;
    }
  }

  try {
    if (req.method === 'POST' && body.action === 'login') {
      const { password } = getAdminConfig();
      if (body.adminPassword !== password) {
        sendJson(res, 401, { ok: false, error: '管理员密码错误' });
        return;
      }
      sendJson(res, 200, {
        ok: true,
        token: issueAdminToken(),
        roleOptions: ROLE_OPTIONS,
      });
      return;
    }

    verifyAdminToken(req);
    const service = getSupabaseServiceClient();

    if (req.method === 'GET') {
      const users = await listUsers(service);
      sendJson(res, 200, { ok: true, users, roleOptions: ROLE_OPTIONS });
      return;
    }

    if (req.method === 'POST' && body.action === 'updateRole') {
      await updateUserRole(service, body.userId, body.role);
      sendJson(res, 200, { ok: true });
      return;
    }

    sendJson(res, 400, { error: 'Unsupported action' });
  } catch (error) {
    sendJson(res, 500, { error: error.message || 'Internal Server Error' });
  }
};
