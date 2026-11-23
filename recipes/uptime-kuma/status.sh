#!/usr/bin/env bash
# The state of the Uptime Kuma instance as data: one row, tab separated: state, address, port ("-" = empty).
# state is the Incus state in lower case (running, stopped) or "missing" when the instance does not exist. Read only.
# Test knob: HS_INCUS (the incus command).
set -u
inc=${HS_INCUS:-incus}
ct=uptime-kuma
row=$("$inc" list "$ct" --format csv -c ns4 </dev/null 2>/dev/null | awk -F, -v n="$ct" '$1 == n { print $2 "\t" $3; exit }')
if [ -z "$row" ]; then
  printf 'missing\t-\t-\n'
  exit 0
fi
state=$(printf '%s' "$row" | cut -f1 | tr 'A-Z' 'a-z')
addr=$(printf '%s' "$row" | cut -f2 | sed 's/ .*//')
printf '%s\t%s\t3001\n' "${state:-unknown}" "${addr:--}"
