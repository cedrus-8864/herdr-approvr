#!/bin/sh
# End-to-end check of the post gate in handle-event: which agent statuses
# deliver a notification and which stay silent. Drives the built binary with a
# stub herdr, so it needs no live herdr and touches no real pane. Posts to a
# throwaway pane id and withdraws it, so a stray desktop notification never
# survives the run.
#
# Complements `--self-test` (which covers parseApproval/applyFormat only) and
# build-app.sh. Run after touching the gate at handle-event's status check.
set -u

cd "$(dirname "$0")" || exit 1
app="assets/HerdrPromptReply.app/Contents/MacOS/HerdrPromptReply"
[ -x "$app" ] && ./build-app.sh >/dev/null 2>&1 || { ./build-app.sh || exit 1; }

pane="GATETEST:pane"
stub=$(mktemp)
cfg_done=$(mktemp -d)
cat > "$stub" <<'STUB'
#!/bin/sh
case "$1 $2" in
  "pane get")      printf '{"result":{"pane":{"tab_id":"t1","workspace_id":"w1","cwd":"/x/demo","focused":false,"agent_status":"blocked"}}}' ;;
  "tab get")       printf '{"result":{"tab":{"label":"demo"}}}' ;;
  "workspace get") printf '{"result":{"workspace":{"label":"demo"}}}' ;;
  "pane read")     printf ' Do you want to proceed?\n \xe2\x9d\xaf 1. Yes\n   2. No\n' ;;
  *)               printf '{}' ;;
esac
STUB
chmod +x "$stub"
printf 'notify_done = true\n' > "$cfg_done/config.toml"

trap '"$app" --remove "$pane" >/dev/null 2>&1; rm -f "$stub"; rm -rf "$cfg_done"' EXIT INT TERM

failures=0
check() { # label  status  config_dir  expected(delivered|silent)
    "$app" --remove "$pane" >/dev/null 2>&1
    env HERDR_BIN_PATH="$stub" HERDR_PANE_ID="$pane" \
        HERDR_PLUGIN_EVENT="pane.agent_status_changed" \
        ${3:+HERDR_PLUGIN_CONFIG_DIR="$3"} \
        HERDR_PLUGIN_EVENT_JSON="{\"data\":{\"pane_id\":\"$pane\",\"agent_status\":\"$2\",\"agent\":\"claude\",\"title\":\"T\"}}" \
        "$app" handle-event >/dev/null 2>&1
    sleep 0.7
    if "$app" --list 2>/dev/null | grep -q "$pane"; then got=delivered; else got=silent; fi
    "$app" --remove "$pane" >/dev/null 2>&1
    if [ "$got" = "$4" ]; then
        echo "  ok   $1"
    else
        echo "  FAIL $1 (got $got, want $4)"
        failures=$((failures + 1))
    fi
}

echo "gate cases:"
check "blocked delivers"                  blocked ""         delivered
check "idle stays silent"                 idle    ""         silent
check "done silent when notify_done off"  done    ""         silent
check "done delivers when notify_done on" done    "$cfg_done" delivered

# pane.focused withdraws a live notification.
"$app" --remove "$pane" >/dev/null 2>&1
env HERDR_BIN_PATH="$stub" HERDR_PANE_ID="$pane" HERDR_PLUGIN_EVENT="pane.agent_status_changed" \
    HERDR_PLUGIN_EVENT_JSON="{\"data\":{\"pane_id\":\"$pane\",\"agent_status\":\"blocked\",\"agent\":\"claude\",\"title\":\"T\"}}" \
    "$app" handle-event >/dev/null 2>&1
sleep 0.7
env HERDR_BIN_PATH="$stub" HERDR_PANE_ID="$pane" HERDR_PLUGIN_EVENT="pane.focused" \
    HERDR_PLUGIN_EVENT_JSON="{\"data\":{\"pane_id\":\"$pane\"}}" \
    "$app" handle-event >/dev/null 2>&1
sleep 0.7
if "$app" --list 2>/dev/null | grep -q "$pane"; then
    echo "  FAIL pane.focused withdraws (still present)"; failures=$((failures + 1))
else
    echo "  ok   pane.focused withdraws"
fi

if [ "$failures" -eq 0 ]; then echo "gate test OK"; else echo "gate test FAILED ($failures)"; exit 1; fi
