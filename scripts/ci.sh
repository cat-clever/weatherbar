#!/usr/bin/env bash
# 本地只用于驱动 GitHub Actions，不执行任何编译动作。
# 编译/签名/打包全部发生在 macos-15 runner 上。
set -euo pipefail

cmd=${1:-status}
repo_root=$(cd "$(dirname "$0")/.." && pwd)
cd "$repo_root"

latest_run() {
  gh run list -w "${1:-build.yml}" -L 1 --json databaseId -q '.[0].databaseId'
}

case "$cmd" in
  build)
    ref=${2:-main}
    gh workflow run build.yml --ref "$ref"
    sleep 3
    gh run list -w build.yml -L 1
    ;;
  watch)
    gh run watch "$(latest_run build.yml)"
    ;;
  logs)
    gh run view "$(latest_run build.yml)" --log-failed
    ;;
  fetch)
    mkdir -p dist
    gh run download "$(latest_run build.yml)" -D dist
    ls -lh dist
    ;;
  release)
    ver=${2:?usage: ci.sh release <version>}
    git tag "v${ver}"
    git push origin "v${ver}"
    echo "→ 已推送 tag v${ver}，release.yml 将自动构建并发布"
    ;;
  status)
    gh run list -L 5
    ;;
  *)
    echo "usage: ci.sh {build [ref]|watch|logs|fetch|release <ver>|status}"
    exit 1
    ;;
esac
