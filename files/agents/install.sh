#!/bin/bash
# 在容器里执行:安装 Node(用户目录)+ 指定的 agent。用法: install.sh [claude] [pi]
set -eu
export PATH=${HOME}/.local/bin:${HOME}/.npm-global/bin:$PATH
if ! command -v node >/dev/null || [ "$(node -p 'process.versions.node.split(".")[0]')" -lt 22 ]; then
    case "$(uname -m)" in x86_64) a=x64 ;; aarch64) a=arm64 ;; *) echo "不支持的架构" >&2; exit 1 ;; esac
    base=https://nodejs.org/dist/latest-v24.x
    f=$(curl -fsSL "$base/SHASUMS256.txt" | awk -v a="linux-$a.tar.xz" '$2 ~ a"$" {print $2; exit}')
    mkdir -p ${HOME}/.local/node ${HOME}/.local/bin
    curl -fsSL "$base/$f" | tar -xJ -C ${HOME}/.local/node --strip-components=1
    for b in node npm npx; do ln -sf ${HOME}/.local/node/bin/$b ${HOME}/.local/bin/$b; done
fi
npm config set prefix ${HOME}/.npm-global
for x in "$@"; do
    case "$x" in
        claude) npm i -g @anthropic-ai/claude-code ;;
        pi)     npm i -g @earendil-works/pi-coding-agent ;;
    esac
done
echo "node $(node -v)"; command -v claude >/dev/null && claude --version || true; command -v pi >/dev/null && pi --version || true
