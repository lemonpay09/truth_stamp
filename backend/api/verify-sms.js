const cors = require('cors');
const crypto = require('crypto');
const OpenApi = require('@alicloud/openapi-client');
const Dypnsapi20170525 = require('@alicloud/dypnsapi20170525');
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

function parseRequestBody(req) {
  if (!req.body) return {};
  if (typeof req.body === 'string') return JSON.parse(req.body);
  return req.body;
}

function normalizePhone(input) {
  if (typeof input !== 'string') return '';
  return input.replace(/\s+/g, '').replace(/[^\d+]/g, '');
}

function createDypnsClient() {
  const accessKeyId = process.env.ALIBABA_CLOUD_ACCESS_KEY_ID;
  const accessKeySecret = process.env.ALIBABA_CLOUD_ACCESS_KEY_SECRET;
  if (!accessKeyId || !accessKeySecret) {
    throw new Error(
      'Missing ALIBABA_CLOUD_ACCESS_KEY_ID or ALIBABA_CLOUD_ACCESS_KEY_SECRET.',
    );
  }

  const config = new OpenApi.Config({
    accessKeyId,
    accessKeySecret,
    endpoint: process.env.ALIBABA_CLOUD_DYPNS_ENDPOINT || 'dypnsapi.aliyuncs.com',
  });

  const ClientClass = Dypnsapi20170525.default || Dypnsapi20170525;
  return new ClientClass(config);
}

async function invokeApi(client, preferredMethods, request) {
  for (const name of preferredMethods) {
    if (typeof client[name] === 'function') {
      return client[name](request);
    }
  }
  throw new Error(
    `No available API method found. Tried: ${preferredMethods.join(', ')}`,
  );
}

function getSupabaseClients() {
  const supabaseUrl = process.env.SUPABASE_URL;
  const serviceRole = process.env.SUPABASE_SERVICE_ROLE_KEY;
  const anonKey = process.env.SUPABASE_ANON_KEY;
  if (!supabaseUrl || !serviceRole || !anonKey) {
    throw new Error(
      'Missing SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY / SUPABASE_ANON_KEY.',
    );
  }

  const service = createClient(supabaseUrl, serviceRole, {
    auth: { persistSession: false },
  });
  const anon = createClient(supabaseUrl, anonKey, {
    auth: { persistSession: false },
  });
  return { service, anon };
}

function getPasswordForPhone(phoneNumber) {
  const pepper = process.env.PHONE_AUTH_PEPPER || 'truthstamp-phone-auth-pepper';
  const digest = crypto
    .createHmac('sha256', pepper)
    .update(phoneNumber)
    .digest('hex');
  return `${digest.substring(0, 28)}Aa1!`;
}

function emailForPhone(phoneNumber) {
  return `${phoneNumber}@sms.truthstamp.cn`;
}

async function ensureAuthUser(serviceClient, phoneNumber) {
  const email = emailForPhone(phoneNumber);
  const password = getPasswordForPhone(phoneNumber);

  try {
    await serviceClient.auth.admin.createUser({
      email,
      password,
      email_confirm: true,
      phone: phoneNumber,
      phone_confirm: true,
      user_metadata: {
        phoneNumber,
        authProvider: 'aliyun_sms',
      },
    });
  } catch (error) {
    const message = (error && error.message ? error.message : '').toLowerCase();
    if (!message.includes('already') && !message.includes('exists')) {
      throw error;
    }
  }

  return { email, password };
}

async function checkSmsVerifyCode(phoneNumber, code) {
  const client = createDypnsClient();
  const requestPayload = {
    phoneNumber,
    verifyCode: code,
    verifyChannel: process.env.ALIBABA_CLOUD_VERIFY_CHANNEL || 'SMS',
  };
  const CheckRequestClass =
    Dypnsapi20170525.CheckSmsVerifyCodeRequest ||
    (Dypnsapi20170525.default &&
      Dypnsapi20170525.default.CheckSmsVerifyCodeRequest);
  const request = CheckRequestClass
    ? new CheckRequestClass(requestPayload)
    : requestPayload;

  const response = await invokeApi(
    client,
    ['checkSmsVerifyCode', 'checkSmsVerifyCodeWithOptions'],
    request,
  );
  const bodyData = response?.body || response;
  const success = (bodyData?.code || '').toString().toUpperCase() === 'OK';
  if (!success) {
    throw new Error(bodyData?.message || '验证码校验失败');
  }
}

module.exports = async function verifySmsHandler(req, res) {
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

  const phoneNumber = normalizePhone(body.phoneNumber);
  const code = typeof body.code === 'string' ? body.code.trim() : '';
  if (!phoneNumber || phoneNumber.length < 11 || code.length !== 6) {
    sendJson(res, 400, { error: '手机号或验证码格式不正确。' });
    return;
  }

  try {
    await checkSmsVerifyCode(phoneNumber, code);
  } catch (error) {
    sendJson(res, 401, {
      ok: false,
      error: `验证码校验失败：${error.message || '请重试'}`,
    });
    return;
  }

  try {
    const { service, anon } = getSupabaseClients();
    const { email, password } = await ensureAuthUser(service, phoneNumber);
    const signInResult = await anon.auth.signInWithPassword({ email, password });

    if (signInResult.error || !signInResult.data?.session || !signInResult.data?.user) {
      sendJson(res, 500, {
        ok: false,
        error: signInResult.error?.message || '登录会话生成失败',
      });
      return;
    }

    const user = signInResult.data.user;
    const session = signInResult.data.session;
    const defaultRole = 'Free';

    const { error: upsertError } = await service.from('app_users').upsert(
      {
        user_id: user.id,
        phone_number: phoneNumber,
        role: defaultRole,
      },
      { onConflict: 'user_id' },
    );
    if (upsertError) {
      // Keep login success even if app_users table is not yet migrated.
      // The admin panel will still read auth.users.
    }

    sendJson(res, 200, {
      ok: true,
      session: {
        access_token: session.access_token,
        refresh_token: session.refresh_token,
        token_type: session.token_type,
        expires_in: session.expires_in,
      },
      user: {
        id: user.id,
        phoneNumber,
        role: defaultRole,
      },
    });
  } catch (error) {
    sendJson(res, 500, {
      ok: false,
      error: error.message || '服务器内部错误',
    });
  }
};
