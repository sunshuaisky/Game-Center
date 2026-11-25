#!/bin/bash
set -euo pipefail

revision=4ab27a53ccb25545fc72dde841320ce5010c399d
checkout="${GAME_CENTER_NX2APPLE_ROOT:-${XDG_CACHE_HOME:-$HOME/Library/Caches}/GameCenter/NX2Apple-$revision}"
if [[ "${1:-}" == engine-path ]]; then
  printf '%s\n' "$checkout/engine"
  exit 0
fi
if [[ ! -f "$checkout/frontend-ios/Shell/App/ShellMain.m" ]]; then
  mkdir -p "$(dirname "$checkout")"
  staging="$(mktemp -d "$(dirname "$checkout")/.nx2apple.XXXXXX")"
  trap 'rm -rf -- "$staging"' EXIT
  git -C "$staging" init -q
  git -C "$staging" fetch -q --depth 1 https://github.com/LNPANDY/NX2Apple.git "$revision"
  git -C "$staging" checkout -q --detach FETCH_HEAD
  if ! mv -n "$staging" "$checkout" || [[ ! -f "$checkout/frontend-ios/Shell/App/ShellMain.m" ]]; then
    echo "无法准备 NX2Apple Shell 源码" >&2
    exit 1
  fi
fi
if [[ "${1:-}" == engine ]]; then
  (cd "$checkout" && python3 tools/engine.py sync) >&2
fi
printf '%s\n' "$checkout"
