#!/usr/bin/env bash
# ============================================================
#  同传 · 阿里云服务器一键部署
#
#  用法（把整个目录传到服务器后，在服务器上 root 执行）：
#
#    bash deploy.sh                 # 纯 IP + HTTP，最快，先能用
#    bash deploy.sh 8080            # 指定端口
#    bash deploy.sh --domain tc.example.com   # 配 nginx + 免费 https 证书
#
#  重复执行是安全的：会覆盖文件、重建服务，不会重复建用户/装包。
# ============================================================
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="/opt/tongchuan"
ENV_FILE="/etc/tongchuan.env"
SVC="tongchuan"
PORT="8787"
DOMAIN=""

# ---------- 参数 ----------
while [ $# -gt 0 ]; do
  case "$1" in
    --domain) DOMAIN="${2:-}"; shift 2 ;;
    --domain=*) DOMAIN="${1#*=}"; shift ;;
    [0-9]*) PORT="$1"; shift ;;
    *) echo "未知参数：$1"; exit 1 ;;
  esac
done

if [ "$(id -u)" -ne 0 ]; then
  echo "✗ 需要 root 权限，请用 sudo bash deploy.sh"
  exit 1
fi

say(){ printf '\n\033[1;36m▸ %s\033[0m\n' "$*"; }
ok(){  printf '\033[1;32m  ✓ %s\033[0m\n' "$*"; }
warn(){ printf '\033[1;33m  ! %s\033[0m\n' "$*"; }

# ---------- 1. 系统包 ----------
say "检查系统"
if command -v apt-get >/dev/null 2>&1; then
  PKG=apt
elif command -v dnf >/dev/null 2>&1; then
  PKG=dnf
elif command -v yum >/dev/null 2>&1; then
  PKG=yum
else
  echo "✗ 认不出包管理器（不是 apt/yum/dnf），请手动装 Node 18+ 后重试"
  exit 1
fi
ok "包管理器：$PKG"

# curl 后面要用，精简镜像常常没装
if ! command -v curl >/dev/null 2>&1; then
  if [ "$PKG" = "apt" ]; then apt-get update -qq && apt-get install -y -qq curl ca-certificates
  else $PKG install -y curl ca-certificates; fi
  ok "已安装 curl"
fi

NODE_OK=0
if command -v node >/dev/null 2>&1; then
  NVER="$(node -v | sed 's/v//' | cut -d. -f1)"
  if [ "${NVER:-0}" -ge 18 ]; then NODE_OK=1; ok "已有 Node $(node -v)"; fi
fi

if [ "$NODE_OK" -eq 0 ]; then
  say "安装 Node 20"
  if [ "$PKG" = "apt" ]; then
    apt-get update -qq
    apt-get install -y -qq curl ca-certificates
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash - >/dev/null
    apt-get install -y -qq nodejs
  else
    curl -fsSL https://rpm.nodesource.com/setup_20.x | bash - >/dev/null
    $PKG install -y nodejs
  fi
  ok "Node $(node -v)"
fi

# ---------- 2. 放文件 ----------
say "部署到 $APP_DIR"
mkdir -p "$APP_DIR"
for f in server.js index.html manifest.json selftest.html icon-180.png icon-192.png icon-512.png; do
  [ -f "$DIR/$f" ] && cp -f "$DIR/$f" "$APP_DIR/"
done
ok "已复制 $(ls -1 "$APP_DIR" | wc -l | tr -d ' ') 个文件"

# ---------- 3. API Key ----------
say "配置 DeepSeek Key"
if [ -f "$ENV_FILE" ]; then
  ok "已存在 $ENV_FILE，沿用（如需更换：编辑该文件后 systemctl restart $SVC）"
else
  KEY="${DEEPSEEK_API_KEY:-}"
  if [ -z "$KEY" ]; then
    printf '  把 DeepSeek API Key 粘进来（sk-... ），直接回车跳过：'
    read -r KEY
  fi
  {
    echo "DEEPSEEK_API_KEY=${KEY}"
    echo "PORT=${PORT}"
  } > "$ENV_FILE"
  chmod 600 "$ENV_FILE"
  if [ -z "$KEY" ]; then
    warn "没有 Key：服务会起来，但翻译请求会返回 500。稍后编辑 $ENV_FILE 补上"
  else
    ok "Key 已写入（权限 600，只有 root 可读）"
  fi
fi
# shellcheck disable=SC1090
PORT="$(sed -n 's/^PORT=//p' "$ENV_FILE" | head -1)"; PORT="${PORT:-8787}"

# ---------- 4. systemd ----------
say "配置 systemd 常驻"
cat > "/etc/systemd/system/${SVC}.service" <<EOF
[Unit]
Description=Tongchuan live translation
After=network.target

[Service]
Type=simple
EnvironmentFile=${ENV_FILE}
ExecStart=$(command -v node) ${APP_DIR}/server.js
Restart=always
RestartSec=3
User=root

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable "$SVC" >/dev/null 2>&1 || true
systemctl restart "$SVC"
sleep 1.2

if curl -fsS "http://127.0.0.1:${PORT}/api/health" >/dev/null 2>&1; then
  ok "服务已启动：$(curl -fsS "http://127.0.0.1:${PORT}/api/health")"
else
  echo "✗ 服务没起来，看日志：journalctl -u $SVC -n 40 --no-pager"
  exit 1
fi

# ---------- 5. 放行端口 ----------
if [ "$PKG" = "apt" ]; then
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q active; then
    ufw allow "${PORT}/tcp" >/dev/null 2>&1 && ok "ufw 已放行 ${PORT}"
  fi
else
  if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --permanent --add-port="${PORT}/tcp" >/dev/null 2>&1
    firewall-cmd --reload >/dev/null 2>&1
    ok "firewalld 已放行 ${PORT}"
  fi
fi
warn "别忘了阿里云控制台 → 安全组 → 入方向放行 ${PORT}（或 80/443）"

# ---------- 6. nginx + https（可选） ----------
if [ -n "$DOMAIN" ]; then
  say "配置 nginx + https（$DOMAIN）"
  if [ "$PKG" = "apt" ]; then
    apt-get install -y -qq nginx certbot python3-certbot-nginx
    CONF=/etc/nginx/sites-available/tongchuan
    mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled
    LINK=/etc/nginx/sites-enabled/tongchuan
  else
    $PKG install -y nginx certbot python3-certbot-nginx \
      || warn "nginx/certbot 没装上（RHEL 系包名不同），请手动反代到 127.0.0.1:${PORT}"
    CONF=/etc/nginx/conf.d/tongchuan.conf
    LINK=""
  fi

  cat > "$CONF" <<EOF
server {
    listen 80;
    server_name ${DOMAIN};

    location / {
        proxy_pass http://127.0.0.1:${PORT};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        # 同传必须关缓冲，否则流式会被憋成一整段
        proxy_buffering off;
        proxy_cache off;
        proxy_set_header Connection '';
        chunked_transfer_encoding on;
        proxy_read_timeout 300s;
    }
}
EOF
  [ -n "$LINK" ] && ln -sf "$CONF" "$LINK"

  if nginx -t >/dev/null 2>&1; then
    systemctl reload nginx || systemctl restart nginx
    ok "nginx 已加载"
  else
    echo "✗ nginx 配置有误，nginx -t 看详情"; exit 1
  fi

  say "申请 Let's Encrypt 证书"
  if certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos --register-unsafely-without-email --redirect; then
    ok "https 就绪"
  else
    warn "证书没申请下来（多半是域名未备案 / 未解析到本机 / 80 端口没放行）"
    warn "先跑一次纯 http 验证：http://${DOMAIN}"
  fi
fi

# ---------- 7. 收尾提示 ----------
PUBIP="$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || curl -fsS --max-time 5 http://ifconfig.me 2>/dev/null || echo '你的公网IP')"

cat <<EOF

────────────────────────────────────────────
 部署完成
────────────────────────────────────────────
 本地自检   curl http://127.0.0.1:${PORT}/api/health

 手机访问   $( [ -n "$DOMAIN" ] && echo "https://${DOMAIN}" || echo "http://${PUBIP}:${PORT}" )

 下一步
   1. iPhone 用 Safari 打开上面这个地址（微信里打开不行）
   2. 首次点「开始同传」→ 允许麦克风
   3. 设置 → Siri 与搜索 → 确认 Siri 已开
   4. 先打开 /selftest.html 跑一遍自检，确认听写和朗读都正常

 常用命令
   systemctl status ${SVC}          查看状态
   journalctl -u ${SVC} -f          看实时日志
   systemctl restart ${SVC}         重启
   vi ${ENV_FILE}                   改 Key / 端口
────────────────────────────────────────────
EOF
