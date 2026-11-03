#!/usr/bin/env bash
# ==============================================================================
# 一键部署 —— Gitee 版
# ==============================================================================
# 前置：
#   1. 已生成 Gitee 私人令牌，放在 E:/复制github/.gitee_token
#   2. 仓库已创建（或让本脚本创建）
#
# 用法：
#   bash deploy_gitee.sh              # 建仓 + 推送 + 装计划任务
#   bash deploy_gitee.sh --no-task    # 只建仓推送，不装计划任务
# ==============================================================================
set -uo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR"

GITEE_USER="${GITEE_USER:-zhang-gd}"
REPO_NAME="${REPO_NAME:-tvbox-config}"
BRANCH="${BRANCH:-master}"
TOKEN_FILE="${TOKEN_FILE:-E:/复制github/.gitee_token}"

RED='\033[0;31m'; GRN='\033[0;32m'; YEL='\033[1;33m'; CYN='\033[0;36m'; NC='\033[0m'
say()  { echo -e "${CYN}$1${NC}"; }
ok()   { echo -e "${GRN}✓ $1${NC}"; }
warn() { echo -e "${YEL}! $1${NC}"; }
err()  { echo -e "${RED}✗ $1${NC}"; }

echo "=============================================="
echo " TVBox 自动更新接口 · Gitee 部署"
echo "=============================================="

# ---------------------------------------------------------------- 1. 令牌
say "[1/5] 检查 Gitee 令牌"
if [ ! -f "$TOKEN_FILE" ] && [ -z "${GITEE_TOKEN:-}" ]; then
  err "缺少 Gitee 令牌"
  echo ""
  echo "  获取步骤："
  echo "    1. 打开 https://gitee.com/profile/personal_access_tokens"
  echo "    2. 备注名填 tvbox-deploy"
  echo "    3. 权限勾选 projects"
  echo "    4. 生成后复制令牌"
  echo ""
  echo "  存到文件:  echo '<令牌>' > '$TOKEN_FILE'"
  echo "  或设环境变量: export GITEE_TOKEN=<令牌>"
  exit 1
fi
bash gitee.sh token-info || exit 1

# ---------------------------------------------------------------- 2. 生成产物
say "[2/5] 生成本地配置产物"
if python scripts/build.py; then
  ok "产物已生成到 dist/"
else
  err "生成失败（上游可能全部不可达）"
  exit 1
fi

# ---------------------------------------------------------------- 3. 建仓
say "[3/5] 准备 Gitee 仓库 $GITEE_USER/$REPO_NAME"
if curl -sS --noproxy '*' -o /dev/null -w "%{http_code}" \
     "https://gitee.com/api/v5/repos/$GITEE_USER/$REPO_NAME" 2>/dev/null | grep -q 200; then
  ok "仓库已存在，跳过创建"
else
  bash gitee.sh create "$REPO_NAME" "TVBox 自建自动更新配置源" || exit 1
fi

# ---------------------------------------------------------------- 4. 推送
say "[4/5] 推送代码到 Gitee"
bash gitee.sh push . "$REPO_NAME" "$BRANCH" || exit 1
ok "推送完成"

# ---------------------------------------------------------------- 5. 计划任务
say "[5/5] 安装 Windows 计划任务（每 6 小时自动更新）"
if [ "${1:-}" = "--no-task" ]; then
  warn "已跳过（--no-task）"
else
  TASK_NAME="TVBox配置自动更新"
  # 每次先重新生成产物再推送
  RUN_CMD="cd /d \"E:\\复制github\\TVBOX配置源\" && python scripts/build.py && bash gitee.sh push . $REPO_NAME $BRANCH"
  # 用 schtasks 创建（每天 4 次：0/6/12/18 点）
  if command -v schtasks.exe >/dev/null 2>&1; then
    schtasks.exe /Create /TN "$TASK_NAME" /TR "$RUN_CMD" \
      /SC HOURLY /MO 6 /ST 03:17 /F >/dev/null 2>&1 && \
      ok "计划任务已创建：$TASK_NAME（每 6 小时）" || \
      warn "计划任务创建失败，可手动运行 deploy_gitee.sh"
  else
    warn "找不到 schtasks，跳过计划任务安装"
  fi
fi

# ---------------------------------------------------------------- 输出
RAW="https://gitee.com/$GITEE_USER/$REPO_NAME/raw/$BRANCH/dist/config.json"
LIVE="https://gitee.com/$GITEE_USER/$REPO_NAME/raw/$BRANCH/dist/live.txt"

echo ""
echo "=============================================="
echo -e "${GRN} 部署完成${NC}"
echo "=============================================="
echo ""
echo "  ★ TVBox 订阅地址（推荐这个）："
echo "    $RAW"
echo ""
echo "  直播源单独订阅："
echo "    $LIVE"
echo ""
echo "  在 TVBox 里：设置 → 配置地址 → 粘贴上面地址 → 确定"
echo ""
echo "  下一步："
echo "    1. 到仓库 Settings → 仓库设置 → 开启「允许陌生人访问」"
echo "       （Gitee 公开仓库的 raw 链接需要仓库为公开状态）"
echo "    2. 验证：浏览器打开上面的订阅地址，能看到 JSON 即可"
echo ""
echo "  手动更新："
echo "    cd E:\\复制github\\TVBOX配置源 && bash deploy_gitee.sh"
echo ""
