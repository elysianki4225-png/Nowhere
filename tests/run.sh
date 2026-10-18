#!/usr/bin/env bash
#
# tests/run.sh — self-contained test suite for nw.sh / install.sh
#
# Runs without root and without network:
#   * syntax checks
#   * unit tests for pure helpers (pct_encode, split_cred, build_url, ...)
#   * end-to-end install/list/link/pin/probe/uninstall against a MOCK
#     nowhere binary packed as a release-style tarball (NW_LOCAL_TARBALL)
#   * CLI error paths
#
# Usage: bash tests/run.sh
#
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NW="$ROOT/nw.sh"
PASS=0; FAIL=0

ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
check() { # check <desc> <expected> <actual>
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected [$2] got [$3])"; fi
}
section() { printf '\n== %s\n' "$1"; }

# ---------------------------------------------------------------- syntax ----
section "syntax"
for f in nw.sh install.sh; do
  if bash -n "$ROOT/$f" 2>/dev/null; then ok "bash -n $f"; else bad "bash -n $f"; fi
done
if have_shellcheck 2>/dev/null || command -v shellcheck >/dev/null 2>&1; then
  if command -v shellcheck >/dev/null 2>&1; then
    if shellcheck -S warning "$ROOT/nw.sh" "$ROOT/install.sh"; then ok "shellcheck"; else bad "shellcheck"; fi
  fi
else
  printf '  skip shellcheck (not installed)\n'
fi

# ----------------------------------------------------------------- units ----
section "unit: helpers"
OUT="$(NW_LIB_ONLY=1 NW_LANG=en bash -c "source '$NW'
pct_encode 'a:b@c'; echo; pct_encode 'p@ss w'; echo
split_cred 'user:pass@1.2.3.4:1080'; echo \"\$CRED_USER|\$CRED_PASS|\$CRED_HOST|\$CRED_PORT\"
split_cred '[2001:db8::1]:443'; echo \"\$CRED_HOST|\$CRED_PORT\"
split_cred '1.2.3.4:1080'; echo \"\$CRED_HOST|\$CRED_PORT\"
encode_socks 'a:b:p@ss@127.0.0.1:1080'; echo
bracket_host '2001:db8::1'; echo
redact_key 0123456789abcdef0123456789abcdef; echo
")"
check "pct_encode basic" "a%3Ab%40c" "$(sed -n 1p <<<"$OUT")"
check "pct_encode space" "p%40ss%20w" "$(sed -n 2p <<<"$OUT")"
check "split_cred full" "user|pass|1.2.3.4|1080" "$(sed -n 3p <<<"$OUT")"
check "split_cred ipv6" "[2001:db8::1]|443" "$(sed -n 4p <<<"$OUT")"
check "split_cred plain" "1.2.3.4|1080" "$(sed -n 5p <<<"$OUT")"
check "encode_socks" "a:b%3Ap%40ss@127.0.0.1:1080" "$(sed -n 6p <<<"$OUT")"
check "bracket_host" "[2001:db8::1]" "$(sed -n 7p <<<"$OUT")"
check "redact_key" "0123..cdef" "$(sed -n 8p <<<"$OUT")"

# ------------------------------------------------------------------ urls ----
section "unit: URL building"
T="$(mktemp -d /tmp/nw-test.XXXXXX)"
KEY="0123456789abcdef0123456789abcdef"
PIN="$(printf 'a%.0s' {1..64})"
URT="$T/urltest.sh"
cat >"$URT" <<'INNER'
set -uo pipefail
source "$NW_PATH"
mk() {
  ROLE="$1"; shift
  # reset the full instance state, exactly like cmd_install/load_instance do
  KEY=""; MORPH=1; PORT=2000; TCP_PORT=""; UDP_PORT=""; TCP_CARRIER=""; UDP_CARRIER=""
  OUT=direct; SOCKS=""; TLS=1; CRT=""; KEY_PATH=""
  PORTAL_HOST=""; PORTAL_PORT=2000; NET=tcp
  IN=127.0.0.1:1080; IN_USER=""; IN_PASS=""
  PIN=""; SNI=""; RATE=""; ETAR=""
  eval "$@"
  build_url
  echo "$URL"
}
K="$TEST_KEY"; P="$TEST_PIN"
mk portal 'PORT=2000; TCP_PORT=2000; UDP_PORT=2000; TCP_CARRIER=tcp; UDP_CARRIER=udp; OUT=direct; TLS=1; MORPH=1; KEY=$K'
mk portal 'PORT=2000; TCP_PORT=443; UDP_PORT=8443; TCP_CARRIER=tcp; UDP_CARRIER=udp; OUT=socks; SOCKS=a:b:p@ss@127.0.0.1:1080; TLS=1; MORPH=0; RATE=100; KEY=$K'
mk portal 'PORT=2000; TCP_PORT=2000; UDP_PORT=; TCP_CARRIER=tcp; UDP_CARRIER=; OUT=direct; TLS=1; MORPH=1; KEY=$K'
mk portal 'PORT=2000; TCP_PORT=2000; UDP_PORT=2000; TCP_CARRIER=tcp; UDP_CARRIER=udp; OUT=egress; TLS=1; MORPH=1; KEY=$K'
mk vector 'NET=tcp; PORTAL_HOST=relay.example.com; PORTAL_PORT=2000; IN=127.0.0.1:1080; IN_USER=alice; IN_PASS=s3cret; PIN=$P; MORPH=1; KEY=$K'
mk vector 'NET=udp; PORTAL_HOST=2001:db8::1; PORTAL_PORT=2001; IN=127.0.0.1:1080; MORPH=1; KEY=$K'
mk egress 'PORTAL_HOST=relay.example.com; PORTAL_PORT=2001; PIN=$P; MORPH=1; KEY=$K'
INNER
URLS="$(NW_LIB_ONLY=1 TEST_KEY="$KEY" TEST_PIN="$PIN" NW_PATH="$NW" NW_LANG=en bash "$URT")"
check "portal same-port"  "portal://$KEY@*:2000" "$(sed -n 1p <<<"$URLS")"
check "portal split+socks" "portal://$KEY@*/tcp:443/udp:8443?out=a:b%3Ap%40ss@127.0.0.1:1080&morph=0&rate=100" "$(sed -n 2p <<<"$URLS")"
check "portal tcp-only"   "portal://$KEY@*/tcp:2000" "$(sed -n 3p <<<"$URLS")"
check "portal out=egress" "portal://$KEY@*:2000?out=egress" "$(sed -n 4p <<<"$URLS")"
check "vector+auth+pin"   "vector://$KEY@relay.example.com:2000?in=alice:s3cret@127.0.0.1:1080&pin=$PIN" "$(sed -n 5p <<<"$URLS")"
check "vector udp+ipv6"   "vector://$KEY@[2001:db8::1]/udp:2001?in=127.0.0.1:1080" "$(sed -n 6p <<<"$URLS")"
check "egress"            "egress://$KEY@relay.example.com/udp:2001?pin=$PIN" "$(sed -n 7p <<<"$URLS")"

# ------------------------------------------------------------- cli errors ----
section "cli: error paths"
run_cli() { NW_LANG=en bash "$NW" "$@" </dev/null 2>&1; }
OUT="$(run_cli frobnicate)";        check "unknown command" "1" "$([ $? -ne 0 ] && echo 1 || echo 0)"
OUT="$(run_cli portal --bogus)";    check "unknown option" "1" "$([ $? -ne 0 ] && echo 1 || echo 0)"
OUT="$(run_cli help | head -n1)";   case "$OUT" in Nowhere*) ok "help output" ;; *) bad "help output" ;; esac
OUT="$(run_cli version)";           case "$OUT" in nw.sh*) ok "version output" ;; *) bad "version output" ;; esac

# ------------------------------------------------------------------- e2e ----
section "e2e: mock binary install lifecycle"
mkdir -p "$T/prefix/bin" "$T/etc" "$T/pkg"

# mock nowhere binary
cat >"$T/pkg/nowhere" <<'MOCK'
#!/usr/bin/env bash
case "${1:-}" in
  generate-key) echo "fedcba98765432100123456789abcde0" ;;
  fingerprint)  echo "presented certificate SHA-256: $(printf 'b%.0s' {1..64})" ;;
  status)       echo "ROLE PID INSTANCE FLOWS"; echo "portal 1234 a1b2c3d4 2" ;;
  probe)        echo "READY $2 -> $3" ;;
  --version|version) echo "nowhere 3.0.1-mock" ;;
  "")           echo "mock help" ;;
  *)            echo "mock serving: $1"; trap 'exit 0' TERM INT; while :; do sleep 1; done ;;
esac
MOCK
chmod +x "$T/pkg/nowhere"
tar czf "$T/nowhere-x86_64-unknown-linux-gnu.tar.gz" -C "$T/pkg" nowhere

E() { NW_ASSUME_ROOT=1 NW_SKIP_SERVICE=1 NW_LOCAL_TARBALL="$T/nowhere-x86_64-unknown-linux-gnu.tar.gz" \
      NW_PREFIX="$T/prefix" NW_ETC="$T/etc" NW_LANG=en bash "$NW" "$@" </dev/null 2>&1; }

OUT="$(E portal --yes --port 2000 --public-addr 203.0.113.10)"
case "$OUT" in *"+ nowhere"*) ok "portal install" ;; *) bad "portal install: $OUT" ;; esac
[ -f "$T/etc/portal/url" ]     && ok "url file written"    || bad "url file written"
[ -f "$T/etc/portal/meta" ]    && ok "meta file written"   || bad "meta file written"
[ -f "$T/prefix/bin/nowhere-portal" ] && ok "wrapper written" || bad "wrapper written"
[ ! -f /etc/systemd/system/nowhere-portal.service ] && ok "no unit in skip-service mode" || bad "unit created in skip-service mode"
check "url content" "portal://fedcba98765432100123456789abcde0@*:2000" "$(cat "$T/etc/portal/url" 2>/dev/null)"

OUT="$(E vector --yes --portal-host 203.0.113.10 --portal-port 2000 --name v1 --pin "$(printf 'c%.0s' {1..64})")"
case "$OUT" in *nowhere-v1*) ok "vector install" ;; *) bad "vector install: $OUT" ;; esac
check "vector url" "vector://fedcba98765432100123456789abcde0@203.0.113.10:2000?in=127.0.0.1:1080&pin=$(printf 'c%.0s' {1..64})" "$(cat "$T/etc/v1/url" 2>/dev/null)"

OUT="$(E egress --yes --portal-host 203.0.113.10 --portal-port 2001 --name e1)"
check "egress url" "egress://fedcba98765432100123456789abcde0@203.0.113.10/udp:2001" "$(cat "$T/etc/e1/url" 2>/dev/null)"

OUT="$(E list)"
for n in portal v1 e1; do
  case "$OUT" in *"$n "*) ok "list shows $n" ;; *) bad "list shows $n" ;; esac
done

OUT="$(E link portal)"
case "$OUT" in *"nowhere://fedcba98765432100123456789abcde0@203.0.113.10:2000"*) ok "portal share link" ;; *) bad "portal share link" ;; esac
case "$OUT" in *"pin=bbbb"*) ok "portal link auto-pin" ;; *) bad "portal link auto-pin" ;; esac

OUT="$(E probe portal example.com:443)"
case "$OUT" in *"READY"*) ok "probe" ;; *) bad "probe: $OUT" ;; esac

OUT="$(E pin v1 --apply)"
case "$OUT" in *"Pin written to instance v1"*) ok "pin --apply" ;; *) bad "pin --apply: $OUT" ;; esac
case "$(cat "$T/etc/v1/url")" in *pin=bbbb*) ok "pin persisted to url" ;; *) bad "pin persisted to url" ;; esac

OUT="$(E status)"
case "$OUT" in *"ROLE PID INSTANCE FLOWS"*) ok "status telemetry" ;; *) bad "status telemetry" ;; esac

OUT="$(E uninstall --all --yes)"
for n in portal v1 e1; do
  [ ! -e "$T/etc/$n" ] && ok "uninstalled $n" || bad "uninstalled $n"
done
[ ! -e "$T/prefix/bin/nowhere" ] && ok "binary removed" || bad "binary removed"

rm -rf "$T"

# ------------------------------------------------------------------ done ----
printf '\n%s\n' "----------------------------------------"
printf 'passed: %d  failed: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
