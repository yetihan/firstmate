#!/usr/bin/env bash
# Live read-only probe of the CHANGED discovery path against the real cmux app.
# A PATH wrapper logs every cmux argv verbatim and forwards to the bundled CLI
# unchanged, so the adapter's real query sequence can be audited:
#   - list_live on an app with no fm task (read-only, no task)
#   - create fm-test- task (sanctioned mutation), then list_live twice:
#     must enumerate list-windows, query each window explicitly via
#     `workspace list --window <uuid>`, discover the task by scoped title,
#     revalidate, and issue NO focus or mutation verbs during discovery.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EV="${1:?evidence dir}"
WRAP="$EV/argv-wrapper"
mkdir -p "$WRAP"
REAL=/Applications/cmux.app/Contents/Resources/bin/cmux
cat > "$WRAP/cmux" <<WRPEOF
#!/usr/bin/env bash
printf '%s\037' "\$(date -u +%H:%M:%S.%3N)" >> "\$CMUX_ARGV_LOG"
for a in "\$@"; do printf '%s\037' "\$a" >> "\$CMUX_ARGV_LOG"; done
printf '\n' >> "\$CMUX_ARGV_LOG"
exec "$REAL" "\$@"
WRPEOF
chmod +x "$WRAP/cmux"

run_adapter() {  # <shell-code> - runs with wrapper on PATH, argv logged
  PATH="$WRAP:$PATH" CMUX_ARGV_LOG="$EV/argv.log" \
    bash -c "$1" "$ROOT"
}

: > "$EV/argv.log"

echo "== phase 1: list_live with no fm task for this home (read-only) =="
PH1_START=$(wc -l < "$EV/argv.log" | tr -d ' ')
out=$(run_adapter '. "$0/bin/fm-backend.sh"; fm_backend_source cmux >/dev/null; fm_backend_cmux_list_live')
status=$?
echo "list_live(no task) status=$status output=[${out}]"
PH1_END=$(wc -l < "$EV/argv.log" | tr -d ' ')
echo "-- argv phase1:"
sed -n "$((PH1_START + 1)),${PH1_END}p" "$EV/argv.log" | tr '\037' ' '

echo
echo "== phase 2: create fm-test- task, then discover it twice =="
PH2_START=$PH1_END
ids=$(run_adapter '. "$0/bin/fm-backend.sh"; fm_backend_source cmux >/dev/null; fm_backend_cmux_create_task fm-test-live1 /tmp')
echo "create ids=[${ids}]"
WS=$(printf '%s\n' "$ids" | awk '{print $1}')
PH2_CREATE_END=$(wc -l < "$EV/argv.log" | tr -d ' ')
out1=$(run_adapter '. "$0/bin/fm-backend.sh"; fm_backend_source cmux >/dev/null; fm_backend_cmux_list_live')
out2=$(run_adapter '. "$0/bin/fm-backend.sh"; fm_backend_source cmux >/dev/null; fm_backend_cmux_list_live')
echo "list_live run1=[${out1}]"
echo "list_live run2=[${out2}]"
PH2_END=$(wc -l < "$EV/argv.log" | tr -d ' ')
echo "-- argv discovery-phase (after create):"
sed -n "$((PH2_CREATE_END + 1)),${PH2_END}p" "$EV/argv.log" | tr '\037' ' '

echo
echo "== audits =="
DISC_LOG=$(mktemp)
sed -n "$((PH2_CREATE_END + 1)),${PH2_END}p" "$EV/argv.log" > "$DISC_LOG"
bad=0
while IFS=$'\037' read -r ts cmd sub rest; do
  case "$cmd" in
    list-windows|list-panes|ping|version) ;;
    workspace) [ "$sub" = list ] || { echo "MUTATION-VERB: $cmd $sub"; bad=1; } ;;
    *) if [ "$cmd" = new-workspace ]; then echo "MUTATION-VERB: $cmd (outside create window)"; bad=1; fi ;;
  esac
done < "$DISC_LOG"
[ "$bad" = 0 ] && echo "AUDIT PASS: discovery issued only read-only verbs (no focus, no mutation)"
[ "$out1" = "$out2" ] && echo "AUDIT PASS: repeated discovery returned identical bindings" || echo "AUDIT FAIL: discovery unstable"
case "$out1" in
  *fm-test-live1*) echo "AUDIT PASS: discovered the fm-test-live1 task by scoped title" ;;
  *) echo "AUDIT FAIL: task not discovered" ;;
esac
WINDOW_IDS=$(run_adapter '. "$0/bin/fm-backend.sh"; fm_backend_source cmux >/dev/null; fm_backend_cmux_cli list-windows --json --id-format uuids' | jq -r '.[].id')
for wid in $WINDOW_IDS; do
  if grep -q "$wid" "$DISC_LOG"; then echo "AUDIT PASS: window $wid was explicitly queried with --window"; else echo "AUDIT FAIL: window $wid never queried"; fi
done
if grep -q 'focus' "$DISC_LOG"; then echo "AUDIT FAIL: focus verb present"; else echo "AUDIT PASS: no focus verb"; fi

echo
echo "== cleanup =="
PATH="$WRAP:$PATH" CMUX_ARGV_LOG="$EV/argv.log" bash -c '
  . "$0/bin/fm-backend.sh"; fm_backend_source cmux >/dev/null
  . "$0/tests/cmux-test-safety.sh"
  cmux_safe_close_workspace "'"$WS"'" fm-test-live1 && echo closed || echo close-refused' "$ROOT"
rm -f "$DISC_LOG"
