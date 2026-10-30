#!/usr/bin/env bash
# Runs TLC on every Looper*.cfg and compares the outcome with its "EXPECT:" line.
set -uo pipefail
cd "$(dirname "$0")"
python3 gen-configs.py
status=0
for cfg in Looper*.cfg; do
  expect=$(sed -n 's/^\\\* EXPECT: //p' "$cfg")
  out=$(tlc Looper.tla -config "$cfg" -workers auto 2>&1)
  if grep -q "No error has been found" <<<"$out"; then got="pass"
  else got="fail $(grep -oE '(Invariant|Temporal property|Action property) [A-Za-z]+' <<<"$out" | head -1 | awk '{print $NF}')"; fi
  states=$(grep -oE '[0-9]+ distinct states' <<<"$out" | head -1)
  if [[ "$got" == "$expect" ]]; then mark=ok; else mark=UNEXPECTED; status=1; fi
  printf '%-12s %-36s expected %-28s got %-28s %s\n' "$mark" "$cfg" "$expect" "$got" "$states"
done
exit $status
