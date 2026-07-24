#!/bin/sh
# Checks that the PostToolUse hook in settings.json does what it claims.
# Run after editing that hook. Slow (~30s): three cases trigger a real build.
#
# The hook command is read out of settings.json rather than duplicated here, so
# this can never pass against a stale copy of it.
set -u

cd "$(dirname "$0")/.." || exit 1
hook=$(jq -r '.hooks.PostToolUse[0].hooks[0].command' .claude/settings.json) || exit 1

backup=$(mktemp)
cp notifier.swift "$backup"
# zsh runs the LAST pipeline component in the current shell, so a case that
# exits non-zero can kill this script mid-run. Only a trap guarantees the
# source file comes back.
trap 'cp "$backup" notifier.swift; rm -f "$backup"' EXIT INT TERM

failures=0
expect() { # label, actual, expected
    if [ "$2" = "$3" ]; then
        echo "  ok   $1"
    else
        echo "  FAIL $1 (got $2, want $3)"
        failures=$((failures + 1))
    fi
}

fire() { # payload -> exit code of the hook
    printf '%s' "$1" | zsh -c "$hook" >/dev/null 2>&1
    echo $?
}

payload() { printf '{"tool_input":{"file_path":"%s/%s"}}' "$PWD" "$1"; }

echo "hook cases:"

expect "ignores a non-Swift file" "$(fire "$(payload README.md)")" 0
expect "ignores a payload with no file_path" "$(fire '{"tool_input":{}}')" 0
expect "passes on clean source" "$(fire "$(payload notifier.swift)")" 0

printf '\nlet hookTestBroken: Int = "not an int"\n' >> notifier.swift
expect "fails on a compile error" "$(fire "$(payload notifier.swift)")" 2

cp "$backup" notifier.swift
printf '\nfunc   hookTestUgly( )   ->Int{return   1}\n' >> notifier.swift
fire "$(payload notifier.swift)" >/dev/null
expect "reformats valid but unformatted code" \
    "$(grep -c 'func hookTestUgly() -> Int { return 1 }' notifier.swift)" 1

cp "$backup" notifier.swift
./build-app.sh >/dev/null 2>&1   # leave a binary matching the restored source

if [ "$failures" -eq 0 ]; then
    echo "hook test OK"
else
    echo "hook test FAILED ($failures)"
    exit 1
fi
