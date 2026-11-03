#!/bin/zsh
# 给本机的同传服务开一条临时公网 https 隧道，方便 iPhone 打开。
#
# 为什么需要：iOS 对语音识别要求"安全上下文"。局域网 http 有时能用有时不行，
# https 一定行。Cloudflare 的快速隧道不需要注册账号，跑完直接给一个 https 网址。
#
# 用法：先 ./start.command 起服务，再另开一个终端跑 ./tunnel.command
set -e
cd "$(dirname "$0")"

PORT="${PORT:-8787}"

if ! command -v cloudflared >/dev/null 2>&1; then
  cat <<'EOF'

没装 cloudflared。装一下（约 30 秒）：

    brew install cloudflared

装完再跑一次 ./tunnel.command

不想装的话，还有两条路：
  · 手机和电脑连同一个 Wi-Fi，直接用局域网地址（http，可能拿不到语音识别权限）
  · 传到阿里云服务器上，bash deploy.sh --domain 你的域名（正式做法）

EOF
  exit 1
fi

# 先确认本地服务在跑
if ! curl -fsS --max-time 2 "http://127.0.0.1:${PORT}/api/health" >/dev/null 2>&1; then
  echo "本地 ${PORT} 端口没响应。先另开一个终端跑 ./start.command"
  exit 1
fi

echo ""
echo "正在开隧道… 下面会打印一个 https://xxxx.trycloudflare.com 的网址"
echo "把这个网址在 iPhone Safari 里打开，先跑 /selftest.html"
echo "按 Ctrl+C 关掉隧道（网址随即失效，只适合测试）"
echo ""

exec cloudflared tunnel --url "http://127.0.0.1:${PORT}" --no-autoupdate
