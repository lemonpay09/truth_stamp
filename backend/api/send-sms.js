const cors = require('cors');
const OpenApi = require('@alicloud/openapi-client');
const Dypnsapi20170525 = require('@alicloud/dypnsapi20170525');

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

module.exports = async function sendSmsHandler(req, res) {
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
  if (!phoneNumber || phoneNumber.length < 11) {
    sendJson(res, 400, { error: '手机号格式不正确。' });
    return;
  }

  try {
    const client = createDypnsClient();
    const signName = process.env.ALIBABA_CLOUD_SMS_SIGN_NAME;
    const templateCode = process.env.ALIBABA_CLOUD_SMS_TEMPLATE_CODE;
    const verifyChannel = process.env.ALIBABA_CLOUD_VERIFY_CHANNEL || 'SMS';

    const requestPayload = {
      phoneNumber,
      signName,
      templateCode,
      verifyChannel,
      ...(process.env.ALIBABA_CLOUD_SMS_EXPIRY
        ? { validTime: Number(process.env.ALIBABA_CLOUD_SMS_EXPIRY) }
        : {}),
    };

    const SendRequestClass =
      Dypnsapi20170525.SendSmsVerifyCodeRequest ||
      (Dypnsapi20170525.default &&
        Dypnsapi20170525.default.SendSmsVerifyCodeRequest);
    const request = SendRequestClass
      ? new SendRequestClass(requestPayload)
      : requestPayload;

    const response = await invokeApi(
      client,
      ['sendSmsVerifyCode', 'sendSmsVerifyCodeWithOptions'],
      request,
    );
    const bodyData = response?.body || response;
    const success = (bodyData?.code || '').toString().toUpperCase() === 'OK';
    if (!success) {
      sendJson(res, 502, {
        error: bodyData?.message || '验证码发送失败，请稍后重试。',
      });
      return;
    }

    sendJson(res, 200, {
      ok: true,
      message: '验证码发送成功',
      requestId: bodyData?.requestId || null,
    });
  } catch (error) {
    sendJson(res, 500, { error: error.message });
  }
};
