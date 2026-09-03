#!/usr/bin/env bash
# Release blockers for the WoWTaskManager addon folder.
#
# Everything here is something that would break the addon in a real client but
# that the test harness cannot see, because the harness loads Includes.xml
# directly rather than going through the TOC the way WoW does.
#
#   ./tools/release-check.sh
set -u

ADDON_DIR="WoWTaskManager"
fails=0
warns=0

pass() { printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fails=$((fails + 1)); }
warn() { printf '  \033[33mWARN\033[0m  %s\n' "$1"; warns=$((warns + 1)); }

section() { printf '\n\033[1m%s\033[0m\n' "$1"; }

#---------------------------------------------------------------------------
section "TOC files"
#---------------------------------------------------------------------------

# Flavour suffix -> the Interface number that flavour must declare.
declare -A EXPECTED_INTERFACE=(
    ["_Mainline"]="120100"   # Retail / Midnight 12.1.0
    ["_Mists"]="50504"       # MoP Classic 5.5.4
    ["_TBC"]="20506"         # TBC Anniversary 2.5.6
    ["_Vanilla"]="11509"     # Classic Era 1.15.9
)

for suffix in "${!EXPECTED_INTERFACE[@]}"; do
    toc="$ADDON_DIR/WoWTaskManager${suffix}.toc"
    expected="${EXPECTED_INTERFACE[$suffix]}"

    if [ ! -f "$toc" ]; then
        fail "$toc is missing"
        continue
    fi

    actual=$(grep -m1 '^## Interface:' "$toc" | tr -d '\r' | awk '{print $3}')
    if [ "$actual" = "$expected" ]; then
        pass "$(basename "$toc") declares Interface $expected"
    else
        fail "$(basename "$toc") declares Interface '$actual', expected '$expected'"
    fi
done

if [ -f "$ADDON_DIR/WoWTaskManager.toc" ]; then
    pass "fallback WoWTaskManager.toc present"
else
    fail "fallback WoWTaskManager.toc is missing"
fi

#---------------------------------------------------------------------------
section "SavedVariables"
#---------------------------------------------------------------------------

for toc in "$ADDON_DIR"/*.toc; do
    if grep -q '^## SavedVariables:.*WoWTaskManagerDB' "$toc"; then
        pass "$(basename "$toc") declares WoWTaskManagerDB"
    else
        # Without this the database silently fails to persist, which is the
        # kind of bug you only notice a week later.
        fail "$(basename "$toc") does not declare SavedVariables: WoWTaskManagerDB"
    fi
done

#---------------------------------------------------------------------------
section "Includes"
#---------------------------------------------------------------------------

for toc in "$ADDON_DIR"/*.toc; do
    if grep -q '^Includes.xml' "$toc"; then
        pass "$(basename "$toc") references Includes.xml"
    else
        fail "$(basename "$toc") does not reference Includes.xml"
    fi
done

if [ ! -f "$ADDON_DIR/Includes.xml" ]; then
    fail "Includes.xml is missing"
else
    pass "Includes.xml present"
fi

#---------------------------------------------------------------------------
section "Referenced files exist and load once"
#---------------------------------------------------------------------------

listed=$(grep -o '<Script file="[^"]*"' "$ADDON_DIR/Includes.xml" \
    | sed 's/<Script file="//; s/"//' | tr '\\' '/')

missing=0
count=0
for rel in $listed; do
    count=$((count + 1))
    if [ ! -f "$ADDON_DIR/$rel" ]; then
        fail "Includes.xml references a file that does not exist: $rel"
        missing=1
    fi
done
[ $missing -eq 0 ] && pass "all $count referenced Lua files exist"

# A file listed twice loads twice, which re-runs its top-level code and
# silently resets module state.
dupes=$(echo "$listed" | sort | uniq -d)
if [ -n "$dupes" ]; then
    while read -r d; do [ -n "$d" ] && fail "listed more than once in Includes.xml: $d"; done <<< "$dupes"
else
    pass "no file is listed twice"
fi

# A .lua file that exists but is never loaded is almost always a mistake.
orphans=0
while read -r f; do
    rel="${f#$ADDON_DIR/}"
    case "$rel" in Libs/*) continue ;; esac
    if ! echo "$listed" | grep -qx "$rel"; then
        warn "not referenced by Includes.xml: $rel"
        orphans=$((orphans + 1))
    fi
done < <(find "$ADDON_DIR" -name '*.lua' | sort)
[ $orphans -eq 0 ] && pass "every Lua file in the addon is loaded"

#---------------------------------------------------------------------------
section "Syntax"
#---------------------------------------------------------------------------

syntax_fail=0
for f in $(find "$ADDON_DIR" -name '*.lua' | sort); do
    if ! luac5.1 -p "$f" >/dev/null 2>&1; then
        fail "does not parse under Lua 5.1: $f"
        luac5.1 -p "$f" 2>&1 | sed 's/^/          /'
        syntax_fail=1
    fi
done
[ $syntax_fail -eq 0 ] && pass "all $(find "$ADDON_DIR" -name '*.lua' | wc -l | tr -d ' ') files parse under Lua 5.1"

#---------------------------------------------------------------------------
section "Version consistency"
#---------------------------------------------------------------------------

code_version=$(grep -m1 'C.VERSION' "$ADDON_DIR/Core/Constants.lua" | sed 's/.*"\(.*\)".*/\1/')
version_mismatch=0
for toc in "$ADDON_DIR"/*.toc; do
    toc_version=$(grep -m1 '^## Version:' "$toc" | tr -d '\r' | awk '{print $3}')
    if [ "$toc_version" != "$code_version" ]; then
        fail "$(basename "$toc") is version '$toc_version' but Constants.lua says '$code_version'"
        version_mismatch=1
    fi
done
[ $version_mismatch -eq 0 ] && pass "every TOC matches C.VERSION ($code_version)"

#---------------------------------------------------------------------------
section "Wording rules"
#---------------------------------------------------------------------------

# The project's central promise: measurements are never presented as proven
# causation. These are the phrasings that would break it.
#
# Lines that NEGATE the phrase ("is not responsible for", "does not mean
# caused by") are the wording working correctly, so they are excluded - the
# check is for assertions, not for the vocabulary.
banned='caused by|is causing|responsible for|proven cause|definitely caused'
negation='\bnot\b|\bnever\b|\bcannot\b|\bNOT\b|\bwithout\b'

hits=$(grep -rEin "$banned" "$ADDON_DIR" --include=*.lua | grep -Ev "$negation" || true)
if [ -n "$hits" ]; then
    fail "causation wording found in addon source:"
    echo "$hits" | sed 's/^/          /'
else
    pass "no causation wording asserted in addon source"
fi

# Phi is a correlation coefficient, not a likelihood, so it must never be
# multiplied into a percentage or formatted with a % sign of its own.
#
# Matching "phi" anywhere near a %% is too loose - a line can legitimately
# format phi and a separate percentage together - so this looks for phi being
# scaled to 100 or formatted directly as a percentage.
phi_hits=$(grep -rEn 'phi[^-]*\* *100|format\(entry\.phi[^)]*%%|phi[a-zA-Z]* *\* *100' \
    "$ADDON_DIR" --include=*.lua | grep -v 'TXT_PHI_NOTE' || true)
if [ -n "$phi_hits" ]; then
    fail "phi appears to be presented as a percentage:"
    echo "$phi_hits" | sed 's/^/          /'
else
    pass "phi is never scaled or formatted as a percentage"
fi

#---------------------------------------------------------------------------
section "Tests"
#---------------------------------------------------------------------------

if ./tools/run-tests.sh >/tmp/wtm-tests.log 2>&1; then
    pass "$(grep -c '^  PASS' /tmp/wtm-tests.log) test scenarios pass"
else
    fail "test matrix failed - see the output below"
    tail -30 /tmp/wtm-tests.log | sed 's/^/          /'
fi

if lua5.1 tools/test-downsample.lua >/tmp/wtm-downsample.log 2>&1; then
    pass "downsampling regression test passes"
else
    fail "downsampling regression test failed"
    cat /tmp/wtm-downsample.log | sed 's/^/          /'
fi

if [ -f tools/test-recorder.lua ]; then
    if lua5.1 tools/test-recorder.lua >/tmp/wtm-recorder.log 2>&1; then
        pass "flight recorder and migration tests pass"
    else
        fail "flight recorder / migration tests failed"
        cat /tmp/wtm-recorder.log | sed 's/^/          /'
    fi
fi

# The error monitor. Its handler contract is the one place where a bug in this
# addon can break a DIFFERENT addon, so it gets its own gate.
if [ -f tools/test-errors.lua ]; then
    if lua5.1 tools/test-errors.lua >/tmp/wtm-errors.log 2>&1; then
        pass "error monitor and handler chaining tests pass"
    else
        fail "error monitor / handler chaining tests failed"
        cat /tmp/wtm-errors.log | sed 's/^/          /'
    fi
fi

# Scale and emptiness: 220 addons, 140 incidents, a session with nothing in it
# yet, and a client that can measure almost none of it.
if lua5.1 tools/test-scale.lua >/tmp/wtm-scale.log 2>&1; then
    pass "scale and empty-state tests pass"
else
    fail "scale / empty-state tests failed"
    tail -20 /tmp/wtm-scale.log | sed 's/^/          /'
fi

# The end-to-end simulated session. It is not an assertion suite, but it is the
# only thing that drives a full login-to-logout run - and it had rotted against
# a renamed field without anything noticing, because nothing ran it.
for iface in 120100 50504 20506 11509; do
    if lua5.1 tools/run.lua "$iface" >/tmp/wtm-run-$iface.log 2>&1 \
        && grep -q "== OK ==" /tmp/wtm-run-$iface.log; then
        pass "simulated session runs clean on $iface"
    else
        fail "simulated session failed on $iface"
        tail -20 /tmp/wtm-run-$iface.log | sed 's/^/          /'
    fi
done

#---------------------------------------------------------------------------
printf '\n'
if [ $fails -eq 0 ]; then
    printf '\033[32mRELEASE CHECK PASSED\033[0m  (%d warnings)\n' "$warns"
    exit 0
fi
printf '\033[31mRELEASE CHECK FAILED\033[0m  (%d blockers, %d warnings)\n' "$fails" "$warns"
exit 1
