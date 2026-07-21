#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
cd "$ROOT_DIR"

if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  repository_files=("${(@f)$(git -c core.quotePath=false ls-files \
    --cached --others --exclude-standard |
    rg -v '^scripts/privacy-check\.sh$')}")
else
  repository_files=("${(@f)$(rg --files \
    -g '!build/**' \
    -g '!dist/**' \
    -g '!.git/**' |
    rg -v '^scripts/privacy-check\.sh$')}")
fi
if (( ${#repository_files} == 0 )); then
  echo "privacy check failed: no repository files"
  exit 1
fi

private_home="/Users/${USER}/"
if rg -n -I \
  '(github_pat_|gh[opsu]_[A-Za-z0-9]{20,}|sk-[A-Za-z0-9_-]{20,}|BEGIN (RSA|OPENSSH|EC|PRIVATE) KEY)' \
  "${repository_files[@]}" ||
  rg -n -I -F \
    -e "$private_home" \
    -e "/var/folders/" \
    "${repository_files[@]}"; then
  echo "privacy check failed: possible secret or private local path"
  exit 1
fi

if rg -n -I \
  '(3204万|7247万|44\.2%|5\.71亿|32\.04M|72\.47M|571M|英语乐园|风格盛宴)' \
  "${repository_files[@]}"; then
  echo "privacy check failed: known private usage example"
  exit 1
fi

if rg -n \
  'NSURLSession|NSURLConnection|CFNetwork|analytics|telemetry|crashlytics|sentry' \
  Sources App; then
  echo "privacy check failed: unexpected networking or telemetry API"
  exit 1
fi

if rg -n 'printf\("active_(project|path)=' Sources; then
  echo "privacy check failed: self-test exposes local project details"
  exit 1
fi

echo "privacy check passed"
