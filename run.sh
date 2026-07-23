#!/bin/sh
# Run notify.js with whichever JS runtime is available. notify.js sticks to
# node:* builtins, so bun and node (>= 18) behave identically here.
cd "$(dirname "$0")" || exit 1

if command -v bun >/dev/null 2>&1; then
  exec bun notify.js
fi
if command -v node >/dev/null 2>&1; then
  exec node notify.js
fi
echo "herdr-approvr: neither bun nor node found on PATH" >&2
exit 1
