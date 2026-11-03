#!/usr/bin/env bash
# ==============================================================================
# TVBox 自动更新接口 —— 一键部署脚本（方案 A：GitHub Actions + raw）
# ==============================================================================
# 用法：
#   bash deploy.sh              # 常规推送
#   bash deploy.sh --check      # 推送前先体检 type=1 接口存活
#
# 前置条件：
#   1. 已在 GitHub 手动创建空仓库（不要勾选 README/.gitignore/LICENSE）
#   2. 已把本机 SSH 公钥添加到 GitHub 账号
#   3. 仓库 Settings → Actions → Workflow permissions 设为 Read and write
# ==============================================================================
set -uo pipefail

cd "$(dirname "$0")" || exit 1

GITHUB_USER="${GITHUB_USER:-hubeizgd1979}"
REPO_NAME="${REPO_NAME:-tvbox-config}"
BRANCH="main"
REMOTE="git@github.com:${GITHUB_USER}/${REPO_NAME}.git"

RED='\033[0;31m'; GRN='\033[0;32m'; YEL='\033[1;33m'; CYN='\033[0;36m'; NC='\033[0m'
say()  { echo -e "${CYN}$1${NC}"; }
ok()   { echo -e "${GRN}✓ $1${NC}"; }
warn() { echo -e "${YEL}! $1${NC}"; }
err()  { echo -e "${RED}✗ $1${NC}"; }

echo "=============================================="
echo " TVBox 自动更新接口部署"
echo "=============================================="

# ---------------------------------------------------------------- 1. SSH 连通性
say "[1/5] 检查 SSH 连通性（走 443 端口）"
if timeout 30 ssh -o StrictHostKeyChecking=accept-new -o BatchMode=yes -T git@ssh.github.com 2>&1 | grep -q "successfully authenticated"; then
  ok "SSH 认证通过"
else
  err "SSH 认证失败。请把本机公钥添加到 GitHub："
  echo "    公钥路径: ~/.ssh/id_ed25519.pub"
  echo "    添加页面: https://github.com/settings/keys"
  echo "    查看公钥: cat ~/.ssh/id_ed25519.pub"
  exit 1
fi

# ---------------------------------------------------------------- 2. 生成产物
say "[2/5] 生成本地配置产物"
BUILD_ARGS=""
if [ "${1:-}" = "--check" ]; then
  BUILD_ARGS="--check"
  ok "将同时校验 type=1 接口存活"
fi
if python scripts/build.py $BUILD_ARGS; then
  ok "产物已生成到 dist/"
else
  err "生成失败（上游可能全部不可达），终止"
  exit 1
fi

# ---------------------------------------------------------------- 3. 提交
say "[3/5] 提交代码"
git config user.name  "Administrator"
git config user.email "Administrator@users.noreply.github.com"

git add -A
if git diff --staged --quiet; then
  warn "工作区无变化，跳过提交"
else
  git commit -q -m "chore: 更新配置 $(date '+%Y-%m-%d %H:%M:%S')"
  ok "已提交"
fi

# ---------------------------------------------------------------- 4. 推送
say "[4/5] 推送到 GitHub"
if git remote get-url origin >/dev/null 2>&1; then
  git remote set-url origin "$REMOTE"
else
  git remote add origin "$REMOTE"
fi

if git push -u origin "$BRANCH" 2>&1 | tail -5; then
  ok "推送成功"
else
  err "推送失败。若提示 Repository not found，说明 GitHub 上还没建同名仓库"
  exit 1
fi

# ---------------------------------------------------------------- 5. 输出订阅地址
say "[5/5] 生成订阅地址"
RAW="https://raw.githubusercontent.com/${GITHUB_USER}/${REPO_NAME}/${BRANCH}/dist/config.json"

echo ""
echo "=============================================="
echo -e "${GRN} 部署完成${NC}"
echo "=============================================="
echo ""
echo "  直连地址（境外/网络好时用）："
echo "    $RAW"
echo ""
echo -e "  ${YEL}推荐地址（国内走代理加速）：${NC}"
echo "    https://gh-proxy.com/$RAW"
echo ""
echo "  备用加速前缀（第一个失效就换下一个）："
echo "    https://ghproxy.net/$RAW"
echo "    https://mirror.ghproxy.com/$RAW"
echo ""
echo "  在 TVBox 里：设置 → 配置地址 → 粘贴上面地址 → 确定"
echo ""
echo "  首次使用请确认："
echo "    1. 仓库 Settings → Actions → General → Workflow permissions"
echo "       设为 Read and write permissions"
echo "    2. Actions 页面手动 Run workflow 跑一次，验证定时任务可用"
echo ""
echo "  直播源单独订阅（可选）："
echo "    https://gh-proxy.com/https://raw.githubusercontent.com/${GITHUB_USER}/${REPO_NAME}/${BRANCH}/dist/live.txt"
echo ""
