#!/bin/zsh
# Mac 本地一键启动（用来先在手机上真机试跑）
cd "$(dirname "$0")" || exit 1

if ! command -v node >/dev/null 2>&1; then
  echo "没找到 node。先装一个：brew install node"
  exit 1
fi

# ---------- 读 Key ----------
KEY="${DEEPSEEK_API_KEY:-}"
PORT_FROM_ENV=""

if [ -f .env ]; then
  K2=$(sed -n 's/^DEEPSEEK_API_KEY=//p' .env | head -1 | tr -d '"'"'"' ')
  P2=$(sed -n 's/^PORT=//p' .env | head -1 | tr -d '"'"'"' ')
  [ -n "$K2" ] && KEY="$K2"
  [ -n "$P2" ] && PORT_FROM_ENV="$P2"
fi

# 在电脑上填一次，手机就不用输那串 50 位的 Key 了
if [ -z "$KEY" ]; then
  echo ""
  echo "把 DeepSeek API Key 粘进来（输入不显示）。直接回车 = 跳过，之后在网页里填。"
  printf "  Key: "
  read -rs KEY
  echo ""
  if [ -n "$KEY" ]; then
    printf 'DEEPSEEK_API_KEY=%s\n' "$KEY" > .env
    chmod 600 .env
    echo "  已存到 .env（权限 600），下次不用再输。"
  else
    echo "  跳过了。手机打开后需要点右上角 ⚙ 自己填 Key。"
  fi
fi

PORT="${PORT:-${PORT_FROM_ENV:-8787}}"

echo ""
echo "→ 本机  http://localhost:$PORT"
echo "→ 手机  用启动后打印的「局域网」地址（同一个 Wi-Fi），或另开终端跑 ./tunnel.command 拿 https"
echo ""

( sleep 1.5; open -a Safari "http://localhost:$PORT/selftest.html" >/dev/null 2>&1 ) &

DEEPSEEK_API_KEY="$KEY" PORT="$PORT" exec node server.js
