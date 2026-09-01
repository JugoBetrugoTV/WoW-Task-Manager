#!/usr/bin/env bash
# Runs the assertion suite across every client flavor and every capability
# combination that changes a code path.
#
# Requires lua5.1 (the addon targets Lua 5.1, the same as WoW).
#   apt-get install lua5.1
#
# Run from the repository root:  ./tools/run-tests.sh
set -u

FLAVORS="120100:Retail-12.1.0 50504:MoP-5.5.4 20506:TBC-2.5.6 11509:Classic-1.15.9"
fails=0
total=0

for spec in $FLAVORS; do
    iface="${spec%%:*}"
    name="${spec#*:}"
    for mode in on off; do
        for api in normal degraded; do
            total=$((total + 1))
            if [ "$api" = "degraded" ]; then
                out=$(lua5.1 tools/test.lua "$iface" "$mode" degraded 2>&1)
            else
                out=$(lua5.1 tools/test.lua "$iface" "$mode" 2>&1)
            fi
            if [ $? -eq 0 ]; then
                printf '  PASS  %-18s profiling=%-3s api=%-8s  %s\n' \
                    "$name" "$mode" "$api" "$(echo "$out" | tail -1 | tr -s ' ')"
            else
                fails=$((fails + 1))
                printf '  FAIL  %-18s profiling=%-3s api=%-8s\n' "$name" "$mode" "$api"
                echo "$out" | sed 's/^/        /'
            fi
        done
    done
done

echo
echo "syntax check:"
syntax_fail=0
for f in $(find WoWTaskManager -name '*.lua' | sort); do
    if ! luac5.1 -p "$f" >/dev/null 2>&1; then
        echo "  FAIL $f"
        luac5.1 -p "$f" 2>&1 | sed 's/^/        /'
        syntax_fail=1
    fi
done
[ $syntax_fail -eq 0 ] && echo "  all $(find WoWTaskManager -name '*.lua' | wc -l) files parse"

echo
if [ $fails -eq 0 ] && [ $syntax_fail -eq 0 ]; then
    echo "ALL $total SCENARIOS PASSED"
    exit 0
fi
echo "$fails of $total scenarios failed"
exit 1
