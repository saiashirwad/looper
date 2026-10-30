#!/usr/bin/env bash
# Type-checks looper.qnt, runs its scenario tests, model-checks it exhaustively
# through TLC, and confirms the type checker rejects every mutation.
set -uo pipefail
cd "$(dirname "$0")"
status=0
expect() { # name expected-verdict command...
  local name=$1 want=$2; shift 2
  local out; out=$("$@" 2>&1)
  local got=pass; grep -qE '\[violation\]|failed|error:' <<<"$out" && got=fail
  local mark=ok; [[ $got == "$want" ]] || { mark=UNEXPECTED; status=1; }
  printf '%-11s %-44s expected %-5s got %s\n' "$mark" "$name" "$want" "$got"
}
expect "typecheck"                         pass quint typecheck looper.qnt
expect "scenario tests (quint test)"       pass quint test looper.qnt --main defaults
expect "simulation, 10k random traces"     pass quint run looper.qnt --main defaults --invariant safety --max-samples 10000 --max-steps 40
expect "exhaustive, defaults (TLC backend)" pass quint verify looper.qnt --main defaults --invariant safety --backend tlc
expect "exhaustive, longFade (TLC backend)" fail quint verify looper.qnt --main longFade --invariant safety --backend tlc
echo
python3 mutations.py || status=1
exit $status
