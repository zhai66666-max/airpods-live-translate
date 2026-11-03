# 部署到阿里云（生活用那台服务器）

整件事只有三步：上传文件 → 起服务 → 配 https。

---

## 0. 先搞清楚一件事：https 从哪来

iPhone 上要能用，页面必须是 **https**（`localhost` 除外）。你有一台阿里云服务器，有三种情况：

| 你的情况 | 做法 | 备注 |
|---|---|---|
| **有已备案域名** | nginx + Let's Encrypt 免费证书 | 最顺，10 分钟搞定，见第 3 步 |
| **有域名但没备案** | 用 Cloudflare Tunnel，或换香港/海外节点 | 国内服务器绑未备案域名访问会被拦 |
| **只有公网 IP** | 先试 `http://IP:8787` 直接打开 | 有可能能跑（语音识别不走 getUserMedia），不行就必须上 https |

先按「有域名」写，其它两种情况在文末有补充。

---

## 1. 上传

在**你 Mac 上**执行（把路径和 IP 换成你的）：

```bash
cd ~/你的项目目录
rsync -avz --exclude '.env' airpods-live-translate/ root@你的服务器IP:/opt/tongchuan/
```

先在服务器上建好目录：

```bash
ssh root@你的服务器IP 'mkdir -p /opt/tongchuan'
```

---

## 2. 装 Node + 起服务

服务器上执行：

```bash
# Node 20（阿里云 Ubuntu/Debian 适用）
curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
apt install -y nodejs

node -v    # 要 18 以上
```

放 Key（**只存在于服务器**，不会进网页）：

```bash
cat > /etc/tongchuan.env <<'EOF'
DEEPSEEK_API_KEY=sk-你从platform.deepseek.com拿的key
PORT=8787
EOF
chmod 600 /etc/tongchuan.env
```

配 systemd，让它常驻 + 开机自启：

```bash
cat > /etc/systemd/system/tongchuan.service <<'EOF'
[Unit]
Description=Tongchuan live translation
After=network.target

[Service]
Type=simple
EnvironmentFile=/etc/tongchuan.env
ExecStart=/usr/bin/node /opt/tongchuan/server.js
Restart=always
RestartSec=3
User=root

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now tongchuan
systemctl status tongchuan --no-pager
```

验证：

```bash
curl -s localhost:8787/api/health
# 期望：{"proxy":"ok", ...}
```

看到 `"proxy":"ok"` 就说明 Key 已被服务端接管，网页端从此不用填 Key。

> 别忘了在**阿里云控制台 → 安全组**放行端口（如果走 nginx 就放 80/443；直连就放 8787）。

---

## 3. nginx + https

```bash
apt install -y nginx certbot python3-certbot-nginx
```

```bash
cat > /etc/nginx/sites-available/tongchuan <<'EOF'
server {
    listen 80;
    server_name 你的域名;

    location / {
        proxy_pass http://127.0.0.1:8787;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;

        # ↓↓↓ 这几行是同传能不能"流式吐字"的关键，删了会变成整段憋出来
        proxy_buffering off;
        proxy_cache off;
        proxy_set_header Connection '';
        chunked_transfer_encoding on;
        proxy_read_timeout 300s;
    }
}
EOF

ln -sf /etc/nginx/sites-available/tongchuan /etc/nginx/sites-enabled/
nginx -t && systemctl reload nginx

certbot --nginx -d 你的域名    # 一路回车，自动配好 https 并续期
```

成功后访问 `https://你的域名/api/health`，返回 `{"proxy":"ok"}` 即通。

---

## 4. iPhone 上收尾

1. Safari 打开 `https://你的域名`
2. 第一次点「开始同传」会问麦克风/听写权限 → **允许**
3. 「设置 → Siri 与搜索」确认 **Siri 已开启**（关掉的话语音识别会直接报错，这是 iOS 的硬性要求）
4. 分享 → 加到主屏幕（图标会是那个青色对话气泡）

> 加到主屏幕后是当书签用、在 Safari 里打开——**不要**把它变成独立 App 模式，那种模式下 iOS 不开放语音识别。

---

## 5. 出门前调一下耳机

- AirPods 建议开 **通透模式**，别开全降噪：全降噪会把对方原声挡掉，你只能等翻译，容易抢话
- 手机放在你和对方之间，麦克风那一端朝对方（AirPods 麦克风波束朝你的嘴，隔 1 米外会明显衰减）
- 面对面大概 **1 米内**最稳

---

## 附：没有备案域名怎么办

**方案 A：Cloudflare Tunnel（免费、免备案、给 https）**

```bash
curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -o /usr/local/bin/cloudflared
chmod +x /usr/local/bin/cloudflared
cloudflared tunnel login          # 浏览器里授权你的 CF 账号
cloudflared tunnel create tongchuan
cloudflared tunnel route dns tongchuan tc.你的域名.com
cloudflared tunnel run --url http://127.0.0.1:8787 tongchuan
```

缺点是国内访问 Cloudflare 会绕一圈，延迟多几十到一百毫秒。对你这个场景（本来就有 1 秒多延迟）影响不大，但不如直连。

**方案 B：只试 http**

直接 `http://你的公网IP:8787`。Safari 里如果语音识别能起来，就先用着；如果点了没反应，说明必须 https，回到方案 A 或上个域名。

---

## 排错速查

| 现象 | 原因 |
|---|---|
| 网页显示「本地直连」而不是「服务器代理」 | `api/health` 没通。`curl localhost:8787/api/health` 看是否 `"proxy":"ok"`；再看 nginx 是否把 `/api/` 也反代了 |
| 点开始没反应、不弹授权 | 主屏幕独立模式，或 Siri 没开 |
| 只能听到半句、剩下卡住 | nginx 开了 `proxy_buffering`，按第 3 步关掉 |
| 屏幕上冒出重复句 | 打开设置里的「回声防护」，或把耳机音量调小 |
| 翻译整段一次性蹦出来 | 服务端 `X-Accel-Buffering` 被 nginx 覆盖，检查上面那几行 |
