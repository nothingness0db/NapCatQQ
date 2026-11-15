#!/usr/bin/env bash
# 重建并部署自建 NapCat 镜像。
#
# 注意：pnpm run build:shell 用 vite 构建，会清空 packages/napcat-shell/dist，
# 所以 Dockerfile 和 QQ 安装包必须在构建后重新放回 dist（本脚本已处理）。
#
# 用法:
#   ./rebuild-napcat.sh              # 构建 + 重建容器（会导致 QQ 掉线，需要重新扫码）
#   BUILD_ONLY=1 ./rebuild-napcat.sh # 只构建镜像，不重建运行中的容器
#   SKIP_PULL=1 ./rebuild-napcat.sh  # 不执行 git pull
set -euo pipefail

export PATH=/home/eria/.local/bin:$PATH
SRC=/home/eria/napcat-src
DIST="$SRC/packages/napcat-shell/dist"
QQ_DEB="${QQ_DEB:-/home/eria/napcat-debs/QQ_3.2.32_260812_amd64_01.deb}"
QQ_DEB_SHA256="d085dd89397225061eb9f194308f688129818ed445777e97a4a0a16e13d7b0e8"

cd "$SRC"

if [ ! -f "$QQ_DEB" ]; then
  echo "缺少 QQ 安装包: $QQ_DEB" >&2
  echo "下载: https://github.com/Rodert/qq-versions/releases/download/qq-packages-20260813-1d08f1d4/QQ_3.2.32_260812_amd64_01.deb" >&2
  exit 1
fi
echo "$QQ_DEB_SHA256  $QQ_DEB" | sha256sum -c -

if [ "${SKIP_PULL:-0}" != "1" ]; then
  git pull --ff-only
fi

pnpm --filter napcat-webui-frontend run build
pnpm run build:shell
pnpm --filter napcat-plugin-builtin run build || true

cd "$DIST"
# 构建产物里的 package.json 带 devDependencies，npm 10 解析 vitest peer 会崩，
# 这里换成只含运行时依赖的最小版本。
cp "$SRC/dist-package.json" package.json
# vite 清空过 dist，Dockerfile 与 QQ 安装包要重新放回来
cp "$SRC/docker/Dockerfile.napcat-dist" Dockerfile
cp "$QQ_DEB" qq.deb
rm -rf node_modules package-lock.json
npm install --omit=dev --no-audit --no-fund
rm -f package-lock.json

docker build -t napcat-custom:qqbackup .
rm -f qq.deb

if [ "${BUILD_ONLY:-0}" = "1" ]; then
  echo "镜像已构建（BUILD_ONLY=1，未重建容器）"
else
  cd /home/eria/data_disk/astrbot
  docker compose up -d napcat
  echo "已部署 napcat-custom:qqbackup（QQ 会掉线，需要扫码）"
fi
