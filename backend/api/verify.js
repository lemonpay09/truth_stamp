const { createClient } = require('@supabase/supabase-js');

function sendHtml(res, statusCode, html) {
  res.status(statusCode);
  res.setHeader('Content-Type', 'text/html; charset=utf-8');
  res.setHeader('Cache-Control', 'no-store');
  res.end(html);
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

function escapeHtml(value) {
  return String(value)
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#39;');
}

function normalizeHash(queryValue) {
  if (Array.isArray(queryValue)) {
    return queryValue[0]?.trim() || '';
  }

  return typeof queryValue === 'string' ? queryValue.trim() : '';
}

function renderPage({ title, accent, icon, headline, body, detailsCard }) {
  return `<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <meta name="theme-color" content="${accent}" />
  <title>${escapeHtml(title)}</title>
  <style>
    :root {
      color-scheme: light;
      --accent: ${accent};
      --bg: #0b1220;
      --panel: rgba(255, 255, 255, 0.92);
      --text: #0f172a;
      --muted: #475569;
      --border: rgba(148, 163, 184, 0.24);
      --shadow: 0 24px 80px rgba(2, 6, 23, 0.22);
    }
    * { box-sizing: border-box; }
    body {
      margin: 0;
      min-height: 100vh;
      font-family: Inter, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
      background:
        radial-gradient(circle at top, rgba(34, 197, 94, 0.22), transparent 35%),
        linear-gradient(180deg, #f8fafc 0%, #e2e8f0 100%);
      color: var(--text);
      display: grid;
      place-items: center;
      padding: 24px;
    }
    .shell {
      width: min(920px, 100%);
      background: var(--panel);
      border: 1px solid var(--border);
      border-radius: 28px;
      box-shadow: var(--shadow);
      overflow: hidden;
      backdrop-filter: blur(14px);
    }
    .hero {
      padding: 28px;
      background: linear-gradient(135deg, ${accent} 0%, #0f172a 100%);
      color: white;
      display: flex;
      gap: 18px;
      align-items: center;
    }
    .icon {
      width: 72px;
      height: 72px;
      flex: 0 0 72px;
      border-radius: 22px;
      background: rgba(255, 255, 255, 0.14);
      display: grid;
      place-items: center;
      box-shadow: inset 0 0 0 1px rgba(255, 255, 255, 0.15);
    }
    .hero h1 {
      margin: 0;
      font-size: clamp(1.5rem, 3vw, 2.25rem);
      line-height: 1.15;
    }
    .hero p {
      margin: 8px 0 0;
      opacity: 0.92;
      line-height: 1.6;
    }
    .content {
      padding: 28px;
      display: grid;
      gap: 18px;
    }
    .card {
      border: 1px solid var(--border);
      border-radius: 22px;
      background: white;
      padding: 20px;
    }
    .grid {
      display: grid;
      grid-template-columns: repeat(2, minmax(0, 1fr));
      gap: 14px;
    }
    .item {
      padding: 16px;
      border-radius: 18px;
      background: #f8fafc;
      border: 1px solid #e2e8f0;
    }
    .label { color: var(--muted); font-size: 0.9rem; margin-bottom: 8px; }
    .value { font-weight: 700; word-break: break-word; }
    .map {
      display: inline-flex;
      align-items: center;
      gap: 8px;
      margin-top: 14px;
      color: ${accent};
      font-weight: 700;
      text-decoration: none;
    }
    .footer {
      color: var(--muted);
      font-size: 0.92rem;
      line-height: 1.6;
    }
    .error-title {
      color: #b91c1c;
    }
    @media (max-width: 640px) {
      .hero, .content { padding: 20px; }
      .grid { grid-template-columns: 1fr; }
      .hero { align-items: flex-start; }
    }
  </style>
</head>
<body>
  <main class="shell">
    <section class="hero">
      <div class="icon">${icon}</div>
      <div>
        <h1>${escapeHtml(headline)}</h1>
        <p>${escapeHtml(body)}</p>
      </div>
    </section>
    <section class="content">
      ${detailsCard}
    </section>
  </main>
</body>
</html>`;
}

function successIcon() {
  return `
    <svg width="34" height="34" viewBox="0 0 24 24" fill="none" aria-hidden="true">
      <path d="M12 2L4.5 5.5V11C4.5 16.05 7.98 20.74 12 22C16.02 20.74 19.5 16.05 19.5 11V5.5L12 2Z" fill="rgba(255,255,255,0.18)"/>
      <path d="M9.5 12.1L11.2 13.8L14.9 10.1" stroke="#ffffff" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"/>
    </svg>`;
}

function errorIcon() {
  return `
    <svg width="34" height="34" viewBox="0 0 24 24" fill="none" aria-hidden="true">
      <path d="M12 2L2.8 20h18.4L12 2Z" fill="rgba(255,255,255,0.18)"/>
      <path d="M12 8.2v5.2" stroke="#ffffff" stroke-width="2.2" stroke-linecap="round"/>
      <circle cx="12" cy="16.6" r="1.1" fill="#ffffff"/>
    </svg>`;
}

function renderSuccessPage(stamp, hash) {
  const latitude = stamp.latitude;
  const longitude = stamp.longitude;
  const mapUrl = `https://www.google.com/maps/search/?api=1&query=${encodeURIComponent(`${latitude},${longitude}`)}`;

  const detailsCard = `
    <div class="card">
      <div class="grid">
        <div class="item">
          <div class="label">指纹 Hash</div>
          <div class="value">${escapeHtml(hash)}</div>
        </div>
        <div class="item">
          <div class="label">精准时间</div>
          <div class="value">${escapeHtml(stamp.timestamp)}</div>
        </div>
        <div class="item">
          <div class="label">纬度</div>
          <div class="value">${escapeHtml(latitude)}</div>
        </div>
        <div class="item">
          <div class="label">经度</div>
          <div class="value">${escapeHtml(longitude)}</div>
        </div>
        <div class="item">
          <div class="label">定位精度</div>
          <div class="value">${escapeHtml(stamp.accuracy)} m</div>
        </div>
        <div class="item">
          <div class="label">存证时间</div>
          <div class="value">${escapeHtml(stamp.created_at)}</div>
        </div>
      </div>
      <a class="map" href="${escapeHtml(mapUrl)}" target="_blank" rel="noreferrer">打开 GPS 地图链接 →</a>
    </div>
    <div class="card footer">
      这份报告显示该影像已与时空元数据完成云端存证校验。你可以核对时间、坐标和哈希是否一致。
    </div>`;

  return renderPage({
    title: 'Truth Stamp - 时空真实性报告',
    accent: '#16a34a',
    icon: successIcon(),
    headline: '时空真实性报告',
    body: '该防伪指纹已在云端查验通过，以下是对应的存证信息。',
    detailsCard,
  });
}

function renderNotFoundPage(hash) {
  const detailsCard = `
    <div class="card">
      <div class="item" style="background:#fef2f2;border-color:#fecaca;">
        <div class="label error-title">未查到此防伪指纹</div>
        <div class="value">Hash: ${escapeHtml(hash || '-')}</div>
      </div>
    </div>
    <div class="card footer">
      请确认二维码是否完整，或检查该指纹是否已成功上传云端。
    </div>`;

  return renderPage({
    title: 'Truth Stamp - 未查到指纹',
    accent: '#dc2626',
    icon: errorIcon(),
    headline: '未查到此防伪指纹',
    body: '云端存证库中没有找到对应记录。',
    detailsCard,
  });
}

module.exports = async function verifyHandler(req, res) {
  if (req.method !== 'GET') {
    res.setHeader('Allow', 'GET');
    sendHtml(res, 405, renderNotFoundPage(''));
    return;
  }

  const hash = normalizeHash(req.query?.hash);
  if (!hash) {
    sendHtml(res, 400, renderNotFoundPage(''));
    return;
  }

  try {
    const supabase = getSupabaseClient();
    const { data, error } = await supabase
      .from('stamps')
      .select('hash, timestamp, latitude, longitude, accuracy, created_at')
      .eq('hash', hash)
      .maybeSingle();

    if (error) {
      sendHtml(
        res,
        500,
        renderPage({
          title: 'Truth Stamp - 查询失败',
          accent: '#dc2626',
          icon: errorIcon(),
          headline: '查询失败',
          body: '云端存证查询发生异常，请稍后再试。',
          detailsCard: `
            <div class="card footer">
              ${escapeHtml(error.message)}
            </div>`,
        })
      );
      return;
    }

    if (!data) {
      sendHtml(res, 404, renderNotFoundPage(hash));
      return;
    }

    sendHtml(res, 200, renderSuccessPage(data, hash));
  } catch (error) {
    sendHtml(
      res,
      500,
      renderPage({
        title: 'Truth Stamp - 查询失败',
        accent: '#dc2626',
        icon: errorIcon(),
        headline: '查询失败',
        body: '云端存证查询发生异常，请稍后再试。',
        detailsCard: `
          <div class="card footer">
            ${escapeHtml(error.message)}
          </div>`,
      })
    );
  }
};
