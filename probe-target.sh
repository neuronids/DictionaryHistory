#!/bin/bash
# Portability probe for DictionaryHistory.
# Run on the target Mac Mini. Verifies every assumption the design rests on.
# Safe: read-only except for a temp build dir. Opens Dictionary.app briefly.

banner(){ printf '\n\033[1m== %s ==\033[0m\n' "$1"; }
pass(){ printf '  \033[32mPASS\033[0m %s\n' "$1"; }
fail(){ printf '  \033[31mFAIL\033[0m %s\n' "$1"; }
info(){ printf '  ---- %s\n' "$1"; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

banner "1. Machine"
info "macOS $(sw_vers -productVersion) ($(sw_vers -buildVersion))"
info "arch: $(uname -m)"
info "swift: $(swiftc --version 2>/dev/null | head -1 || echo MISSING)"
if ! command -v swiftc >/dev/null; then
  fail "no swiftc - install Command Line Tools: xcode-select --install"; exit 1
fi
pass "toolchain present"

banner "2. DCSCopyTextDefinition (the engine the whole design depends on)"
cat > "$TMP/t.swift" <<'EOF'
import Foundation
@_silgen_name("DCSCopyTextDefinition")
func DCSCopyTextDefinition(_ d: AnyObject?, _ s: CFString, _ r: CFRange) -> Unmanaged<CFString>?
let w = CommandLine.arguments[1] as CFString
if let d = DCSCopyTextDefinition(nil, w, CFRangeMake(0, CFStringGetLength(w))) {
    print(String(d.takeRetainedValue()).prefix(90))
} else { print("NIL") }
EOF
if swiftc -O "$TMP/t.swift" -o "$TMP/t" 2>"$TMP/err"; then
  pass "compiles natively on $(uname -m)"
  for w in serendipity palimpsest casa; do
    r=$("$TMP/t" "$w")
    [ "$r" = "NIL" ] && fail "lookup '$w' returned NIL" || info "$w -> $r"
  done
  r=$("$TMP/t" zzzznotaword); [ "$r" = "NIL" ] && pass "unknown word correctly returns NIL" || fail "unknown word returned data"
else
  fail "compile failed:"; sed 's/^/      /' "$TMP/err"
fi

banner "3. Active dictionaries"
defaults read ~/Library/Preferences/com.apple.DictionaryServices DCSActiveDictionaries 2>/dev/null | sed 's/^/  /' || info "none set (defaults in use)"

banner "4. dict:// URL scheme (needed for the pass-through design)"
RC=~/Library/Containers/com.apple.Dictionary/Data/Library/Caches/com.apple.DictionaryApp/resumecache-2
BEFORE=$(plutil -p "$RC" 2>/dev/null | grep searchstring)
info "resumecache before: ${BEFORE:-<absent>}"
if open "dict://serendipity" 2>/dev/null; then
  sleep 4
  pgrep -q Dictionary && pass "dict:// launched Dictionary.app" || fail "Dictionary.app not running"
  osascript -e 'tell application "Dictionary" to quit' >/dev/null 2>&1; sleep 3
  AFTER=$(plutil -p "$RC" 2>/dev/null | grep searchstring)
  info "resumecache after:  ${AFTER:-<absent>}"
  if [ -z "$AFTER" ]; then
    info "resumecache not present on this macOS; confirm the search field with: dh dump-ax"
  else
    echo "$AFTER" | grep -qi serendip && pass "dict:// actually drove the search field" \
                                      || fail "word did not reach search field (scheme may have changed)"
  fi
else
  fail "'open dict://' rejected - URL scheme gone"
fi

banner "5. Accessibility permission (only needed for the observer add-on)"
osascript -e 'tell application "System Events" to get name of first process' >/dev/null 2>&1 \
  && pass "this terminal already has Accessibility access" \
  || info "not granted for this terminal (expected; grant per-app in System Settings > Privacy & Security > Accessibility)"

banner "6. Unified log leakage (expected: none)"
info "confirms Apple still does not log the looked-up word"
# No `timeout` on stock macOS; the stream is stopped with kill below.
log stream --style compact --predicate 'process == "Dictionary"' > "$TMP/log" 2>&1 &
LP=$!; sleep 2; open "dict://ephemeral" 2>/dev/null; sleep 8; kill $LP 2>/dev/null; wait $LP 2>/dev/null
osascript -e 'tell application "Dictionary" to quit' >/dev/null 2>&1
N=$(grep -ic ephemeral "$TMP/log" 2>/dev/null); N=${N:-0}
[ "$N" -eq 0 ] && pass "word never appears in logs ($(wc -l < "$TMP/log") lines scanned) - log route confirmed dead" \
               || fail "word LEAKED into logs $N times - a cheaper capture route may exist, investigate"

banner "Done"
