#!/usr/bin/env node
/**
 * 同传 · 单文件服务端（零依赖，Node 18+）
 *
 * 职责只有两件：
 *   1. 托管 index.html 等静态文件
 *   2. /api/translate 反向代理到 DeepSeek —— 这样 API Key 留在服务器环境变量里，
 *      不会落到任何人的浏览器，别人拿到链接也烧不到你的额度。
 *
 * 启动：
 *   DEEPSEEK_API_KEY=sk-xxx PORT=8787 node server.js
 */

const http = require('http');
const fs = require('fs');
const path = require('path');
const os = require('os');
const { Readable } = require('stream');

const PORT = Number(process.env.PORT || 8787);
const KEY = (process.env.DEEPSEEK_API_KEY || '').trim();
const UPSTREAM = process.env.UPSTREAM || 'https://api.deepseek.com/chat/completions';
const ROOT = __dirname;

const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.js':   'text/javascript; charset=utf-8',
  '.css':  'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.png':  'image/png',
  '.svg':  'image/svg+xml',
  '.ico':  'image/x-icon',
  '.webmanifest': 'application/manifest+json',
};

function json(res, code, obj) {
  const body = JSON.stringify(obj);
  res.writeHead(code, {
    'Content-Type': 'application/json; charset=utf-8',
    'Content-Length': Buffer.byteLength(body),
    'Cache-Control': 'no-store',
    'Access-Control-Allow-Origin': '*',
  });
  res.end(body);
}

async function proxyTranslate(req, res) {
  if (!KEY) {
    return json(res, 500, {
      error: { message: '服务端没有配置 DEEPSEEK_API_KEY，请检查 systemd 或启动命令里的环境变量' },
    });
  }

  const chunks = [];
  for await (const c of req) chunks.push(c);
  const body = Buffer.concat(chunks).toString('utf8');

  let payload;
  try { payload = JSON.parse(body); }
  catch (e) { return json(res, 400, { error: { message: '请求体不是合法 JSON' } }); }

  // 只允许这两个模型，防止被当成通用代理刷别的模型
  if (payload.model !== 'deepseek-chat' && payload.model !== 'deepseek-reasoner') {
    payload.model = 'deepseek-chat';
  }

  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 60000);
  res.on('close', () => { controller.abort(); clearTimeout(timer); });

  let upstream;
  try {
    upstream = await fetch(UPSTREAM, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer ' + KEY,
        'Accept': 'text/event-stream',
      },
      body: JSON.stringify(payload),
      signal: controller.signal,
    });
  } catch (e) {
    clearTimeout(timer);
    return json(res, 502, { error: { message: '连不上 DeepSeek：' + e.message } });
  }

  clearTimeout(timer);

  const headers = {
    'Content-Type': upstream.headers.get('content-type') || 'text/event-stream; charset=utf-8',
    'Cache-Control': 'no-cache, no-transform',
    'Connection': 'keep-alive',
    // 关键：关掉 nginx 的缓冲，否则流式会被憋成一坨
    'X-Accel-Buffering': 'no',
    'Access-Control-Allow-Origin': '*',
  };
  res.writeHead(upstream.status, headers);

  if (!upstream.body) { res.end(); return; }

  // 逐块转发，保证前端拿到的是真流式
  try {
    const nodeStream = Readable.fromWeb(upstream.body);
    nodeStream.on('data', (c) => res.write(c));
    nodeStream.on('end', () => res.end());
    nodeStream.on('error', () => res.end());
  } catch (e) {
    try {
      const buf = Buffer.from(await upstream.arrayBuffer());
      res.end(buf);
    } catch (_) { res.end(); }
  }
}

// 只对外发这些扩展名。.env / 脚本 / 文档一律不发。
const ALLOW_EXT = new Set(['.html', '.css', '.png', '.svg', '.ico', '.webmanifest']);
// manifest 是 .json，单独放行；其它 json 一律不发
const ALLOW_NAME = new Set(['manifest.json']);
// 名字黑名单兜底（.js/.json 只放行 manifest，别的一律不放）
const DENY_NAME = new Set([
  'server.js', 'deploy.sh', 'start.command', 'tunnel.command',
  'readme.md', 'deploy.md', 'package.json', 'package-lock.json',
]);

function serveStatic(req, res) {
  let p = decodeURIComponent(req.url.split('?')[0]);
  if (p === '/' || p === '') p = '/index.html';

  // 任何以点开头的路径段（.env / .git / .DS_Store）直接拒绝
  const segs = p.split('/').filter(Boolean);
  if (segs.some(s => s.startsWith('.'))) {
    res.writeHead(404, { 'Content-Type': 'text/plain; charset=utf-8' }).end('not found');
    return;
  }

  const base = segs.length ? segs[segs.length - 1].toLowerCase() : '';
  const ext = path.extname(base).toLowerCase();
  if (DENY_NAME.has(base) || (!ALLOW_NAME.has(base) && !ALLOW_EXT.has(ext))) {
    res.writeHead(404, { 'Content-Type': 'text/plain; charset=utf-8' }).end('not found');
    return;
  }

  // 防目录穿越
  const file = path.normalize(path.join(ROOT, p));
  if (!file.startsWith(ROOT + path.sep) && file !== path.join(ROOT, 'index.html')) {
    res.writeHead(403).end('forbidden');
    return;
  }
  if (!fs.existsSync(file) || fs.statSync(file).isDirectory()) {
    res.writeHead(404, { 'Content-Type': 'text/plain; charset=utf-8' }).end('not found');
    return;
  }
  res.writeHead(200, {
    'Content-Type': MIME[ext] || 'application/octet-stream',
    'Cache-Control': ext === '.html' ? 'no-cache' : 'public, max-age=86400',
  });
  fs.createReadStream(file).pipe(res);
}

const server = http.createServer((req, res) => {
  const url = req.url.split('?')[0];

  if (url === '/api/health') {
    return json(res, 200, {
      proxy: KEY ? 'ok' : 'nokey',
      upstream: UPSTREAM,
      time: new Date().toISOString(),
    });
  }

  if (url === '/api/translate') {
    if (req.method === 'OPTIONS') {
      res.writeHead(204, {
        'Access-Control-Allow-Origin': '*',
        'Access-Control-Allow-Methods': 'POST, OPTIONS',
        'Access-Control-Allow-Headers': 'Content-Type, Authorization',
        'Access-Control-Max-Age': '86400',
      });
      return res.end();
    }
    if (req.method !== 'POST') return json(res, 405, { error: { message: '只接受 POST' } });
    return proxyTranslate(req, res);
  }

  if (req.method !== 'GET' && req.method !== 'HEAD') {
    return res.writeHead(405).end();
  }
  serveStatic(req, res);
});

function lanAddresses() {
  const out = [];
  const nets = os.networkInterfaces();
  for (const name of Object.keys(nets)) {
    for (const ni of nets[name] || []) {
      if (ni.family === 'IPv4' && !ni.internal) {
        out.push({ name, address: ni.address });
      }
    }
  }
  return out;
}

server.listen(PORT, '0.0.0.0', () => {
  const lans = lanAddresses();
  const line = '─'.repeat(56);

  console.log('');
  console.log(line);
  console.log('  同传服务已启动');
  console.log(line);
  console.log('  本机      http://localhost:' + PORT);
  if (lans.length) {
    for (const l of lans) {
      console.log('  局域网    http://' + l.address + ':' + PORT + '   (' + l.name + ')');
    }
  } else {
    console.log('  局域网    （没检测到非回环网卡，检查是否连着 Wi-Fi）');
  }
  console.log('');
  console.log('  DeepSeek  ' + (KEY ? '已配置 Key → 走服务器代理' : '未配置 Key → 前端需自己填'));
  console.log('  上游      ' + UPSTREAM);
  console.log(line);
  console.log('  iPhone 怎么打开：');
  console.log('   · 手机和这台电脑连同一个 Wi-Fi，直接用上面的局域网地址');
  console.log('     注意：http 下 iOS 可能不给语音识别。如果自检第 5 项不过，换下面两种。');
  console.log('   · 要 https：另开一个终端跑 ./tunnel.command（需先 brew install cloudflared）');
  console.log('     它会给你一个临时公网 https 链接，手机 4G 也能开。');
  console.log('   · 长期用：把整个目录传到服务器，bash deploy.sh --domain 你的域名');
  console.log(line);
  console.log('  先打开  /selftest.html  跑一遍自检，全绿再用。');
  console.log('');
});
