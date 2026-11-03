#!/usr/bin/env bash
# 安装版本化 git 钩子:把 core.hooksPath 指到仓库的 .githooks/。
#
# 钩子随仓库分发,但 core.hooksPath 是仓库本地配置 —— 每台机器/每个
# clone 执行一次本脚本即可(所有 worktree 共享同一份 .git/config,
# 因此只需装一次)。
#
# 路径解析:优先用主 worktree 的 .githooks(合入 main 后的常态);
# 若主 worktree 还没有该目录(特性分支尚未合入),回退到当前工作区
# 的 .githooks,保证开发期也能用。
set -euo pipefail

repo=$(git rev-parse --show-toplevel)
cd "$repo"
common=$(git rev-parse --git-common-dir)
main=$(cd "$common/.." && pwd)

if [ -d "$main/.githooks" ]; then
  hooks="$main/.githooks"
else
  hooks="$repo/.githooks"
fi

chmod +x "$hooks"/* 2>/dev/null || true
git config core.hooksPath "$hooks"
echo "core.hooksPath -> $hooks"
