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

/**
 * Verify SMS code with Aliyun API
 * Ensures all parameters match the send-sms.js request for consistency
 */
async function checkSmsVerifyCode(phoneNumber, code) {
  const client = createDypnsClient();
  
  // Match parameters with send-sms.js for consistency
  const verifyChannel = process.env.ALIBABA_CLOUD_VERIFY_CHANNEL || 'SMS';
  
  // Critical: Field name is "VerifyCode" (capital V and C), not "code" or "verifyCode"
  // This must match exactly with what Aliyun's CheckSmsVerifyCode expects
  const requestPayload = {
    phoneNumber,
    VerifyCode: code,  // CRITICAL: Capital V and C - Aliyun API strict requirement
    verifyChannel,
    // Do NOT include SchemeName if send-sms.js doesn't explicitly set it
    // This ensures parameter consistency between send and verify operations
  };

  console.log('[CheckSmsVerifyCode] Request payload:', {
    phoneNumber: phoneNumber.substring(0, 7) + '****',
    VerifyCode: '***',
    verifyChannel,
  });

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
    const errorMsg = bodyData?.message || '验证码校验失败';
    console.error('[CheckSmsVerifyCode] Failed:', errorMsg);
    throw new Error(errorMsg);
  }

  console.log('[CheckSmsVerifyCode] Success');
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
  
  if (!phoneNumber || phoneNumber.length < 11) {
    sendJson(res, 400, { error: '手机号格式不正确。' });
    return;
  }

  if (code.length !== 6 || !/^\d{6}$/.test(code)) {
    sendJson(res, 400, { error: '验证码格式不正确（必须为6位数字）。' });
    return;
  }

  try {
    // Step 1: Verify the SMS code with Aliyun API (with strict parameter matching)
    await checkSmsVerifyCode(phoneNumber, code);
    console.log(`[verify-sms] SMS code verified for phone: ${phoneNumber.substring(0, 7)}****`);
  } catch (error) {
    console.error(`[verify-sms] SMS verification failed:`, error.message);
    sendJson(res, 401, {
      ok: false,
      error: `验证码校验失败：${error.message || '请重试'}`,
    });
    return;
  }

  try {
    // Step 2: Create or fetch user in Supabase
    const { service, anon } = getSupabaseClients();
    const { email, password } = await ensureAuthUser(service, phoneNumber);
    
    console.log(`[verify-sms] User ensured for phone: ${phoneNumber.substring(0, 7)}****`);

    // Step 3: Sign in with the generated credentials
    const signInResult = await anon.auth.signInWithPassword({ email, password });

    if (signInResult.error || !signInResult.data?.session || !signInResult.data?.user) {
      console.error('[verify-sms] Sign-in failed:', signInResult.error?.message);
      sendJson(res, 500, {
        ok: false,
        error: signInResult.error?.message || '登录会话生成失败',
      });
      return;
    }

    const user = signInResult.data.user;
    const session = signInResult.data.session;
    const defaultRole = 'Free';

    console.log(`[verify-sms] Session created for user: ${user.id.substring(0, 8)}...`);

    // Step 4: Upsert user record in app_users table (non-critical)
    const { error: upsertError } = await service.from('app_users').upsert(
      {
        user_id: user.id,
        phone_number: phoneNumber,
        role: defaultRole,
        last_login_at: new Date().toISOString(),
      },
      { onConflict: 'user_id' },
    );
    
    if (upsertError) {
      console.warn('[verify-sms] app_users upsert warning (non-critical):', upsertError.message);
      // Keep login success even if app_users table is not yet migrated
    }

    // Step 5: Return success response with session
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

    console.log(`[verify-sms] Login successful for phone: ${phoneNumber.substring(0, 7)}****`);
  } catch (error) {
    console.error('[verify-sms] Supabase operation failed:', error.message);
    sendJson(res, 500, {
      ok: false,
      error: error.message || '服务器内部错误',
    });
  }
};
