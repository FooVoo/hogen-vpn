#!/usr/bin/env bash
# Integration test for rotate-reality-cover.sh
# Tests: domain selection, TLS availability checks, .env update, config render.
# Skips docker compose restart (no Docker required).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

PASS=0
FAIL=0
report() {
  local status="$1" name="$2"
  if [[ "$status" == "PASS" ]]; then
    PASS=$((PASS + 1))
    echo "  ✅ $name"
  else
    FAIL=$((FAIL + 1))
    echo "  ❌ $name"
  fi
}

# ---------------------------------------------------------------------------
# Setup: copy project into temp dir and create a mock .env
# ---------------------------------------------------------------------------
cp "$SCRIPT_DIR/render-xray-config.sh" "$WORK_DIR/"
cp "$SCRIPT_DIR/render-credentials-page.sh" "$WORK_DIR/"
cp -r "$SCRIPT_DIR/web" "$WORK_DIR/"
chmod +x "$WORK_DIR/render-xray-config.sh" "$WORK_DIR/render-credentials-page.sh"

# Create a modified rotate script that skips docker compose
sed 's|docker compose.*||' "$SCRIPT_DIR/rotate-reality-cover.sh" > "$WORK_DIR/rotate-reality-cover.sh"
chmod +x "$WORK_DIR/rotate-reality-cover.sh"

MOCK_DOMAINS="www.microsoft.com,www.cloudflare.com,github.com,www.google.com,www.apple.com"
MOCK_SS_PASSWORD="dGVzdHBhc3N3b3JkMTIzNDU2Nzg5MDEyMzQ1Njc4OTA="

write_mock_env() {
  local sni="${1:-www.microsoft.com}"
  cat > "$WORK_DIR/.env" <<EOF
SERVER_IP=1.2.3.4
MTG_SECRET=ee00000000000000000000000000000000676f6f676c652e636f6d
MTG_PORT=2083
MTG_LINK="https://t.me/proxy?server=1.2.3.4&port=2083&secret=ee00000000000000000000000000000000676f6f676c652e636f6d"
XRAY_UUID=aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee
XRAY_PRIVATE_KEY=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
XRAY_PUBLIC_KEY=BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=
XRAY_SHORT_ID=abcdef0123456789
XRAY_SNI=${sni}
XRAY_DEST=${sni}:443
XRAY_COVER_DOMAINS=${MOCK_DOMAINS}
XRAY_ROTATE_HOURS=2
VLESS_URI="vless://aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee@1.2.3.4:8443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${sni}&fp=chrome&pbk=BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=&sid=abcdef0123456789&type=tcp#VPN"
SS_METHOD=2022-blake3-aes-256-gcm
SS_PORT=8388
SS_PASSWORD="${MOCK_SS_PASSWORD}"
SS_URI="ss://$(printf '%s:%s' '2022-blake3-aes-256-gcm' "${MOCK_SS_PASSWORD}" | openssl base64 -A | tr '+/' '-_' | tr -d '=')@1.2.3.4:8388#SS-VPN"
IKE_PSK="bW9ja2lrZXBzazEyMzQ1Njc4OTAxMjM0"
IKE_USER=vpnuser
IKE_PASSWORD=mockikepass
PAGE_USER=admin
PAGE_PASSWORD=testpass1234
EOF
}

mkdir -p "$WORK_DIR/xray"

echo ""
echo "=== Test 1: Domain changes after rotation ==="
write_mock_env "www.microsoft.com"
WEBROOT="$WORK_DIR/webroot"
mkdir -p "$WEBROOT"
(cd "$WORK_DIR" && WEBROOT="$WEBROOT" bash rotate-reality-cover.sh 2>&1) || true
NEW_SNI=$(grep '^XRAY_SNI=' "$WORK_DIR/.env" | cut -d= -f2)
if [[ "$NEW_SNI" != "www.microsoft.com" && -n "$NEW_SNI" ]]; then
  report PASS "SNI changed from www.microsoft.com to $NEW_SNI"
else
  report FAIL "SNI did not change (still $NEW_SNI)"
fi

echo ""
echo "=== Test 2: .env is updated consistently ==="
ENV_DEST=$(grep '^XRAY_DEST=' "$WORK_DIR/.env" | cut -d= -f2)
if [[ "$ENV_DEST" == "${NEW_SNI}:443" ]]; then
  report PASS "XRAY_DEST matches new SNI (${ENV_DEST})"
else
  report FAIL "XRAY_DEST mismatch: expected ${NEW_SNI}:443, got ${ENV_DEST}"
fi

VLESS=$(grep '^VLESS_URI=' "$WORK_DIR/.env" | head -1)
if echo "$VLESS" | grep -q "sni=${NEW_SNI}"; then
  report PASS "VLESS_URI contains new SNI"
else
  report FAIL "VLESS_URI does not contain new SNI"
fi

echo ""
echo "=== Test 3: Xray config uses new SNI ==="
if [[ -f "$WORK_DIR/xray/config.json" ]]; then
  CFG_SNI=$(python3 -c "import json; c=json.load(open('$WORK_DIR/xray/config.json')); print(c['inbounds'][0]['streamSettings']['realitySettings']['serverNames'][0])")
  if [[ "$CFG_SNI" == "$NEW_SNI" ]]; then
    report PASS "xray/config.json serverNames = $CFG_SNI"
  else
    report FAIL "xray/config.json serverNames = $CFG_SNI, expected $NEW_SNI"
  fi
  CFG_DEST=$(python3 -c "import json; c=json.load(open('$WORK_DIR/xray/config.json')); print(c['inbounds'][0]['streamSettings']['realitySettings']['dest'])")
  if [[ "$CFG_DEST" == "${NEW_SNI}:443" ]]; then
    report PASS "xray/config.json dest = $CFG_DEST"
  else
    report FAIL "xray/config.json dest = $CFG_DEST, expected ${NEW_SNI}:443"
  fi
else
  report FAIL "xray/config.json was not generated"
fi

echo ""
echo "=== Test 4: Credentials page rendered with new SNI ==="
if [[ -f "$WEBROOT/index.html" ]]; then
  if grep -q "$NEW_SNI" "$WEBROOT/index.html"; then
    report PASS "index.html contains new SNI"
  else
    report FAIL "index.html does not contain new SNI"
  fi
else
  report FAIL "index.html was not generated"
fi

echo ""
echo "=== Test 5: .env file permissions ==="
PERMS=$(stat -f '%Lp' "$WORK_DIR/.env" 2>/dev/null || stat -c '%a' "$WORK_DIR/.env" 2>/dev/null)
if [[ "$PERMS" == "600" ]]; then
  report PASS ".env permissions = $PERMS"
else
  report FAIL ".env permissions = $PERMS, expected 600"
fi

echo ""
echo "=== Test 6: Multiple rotations never repeat previous domain ==="
SEEN_DOMAINS=()
ALL_UNIQUE=true
write_mock_env "www.microsoft.com"
for i in $(seq 1 8); do
  BEFORE=$(grep '^XRAY_SNI=' "$WORK_DIR/.env" | cut -d= -f2)
  (cd "$WORK_DIR" && WEBROOT="$WEBROOT" bash rotate-reality-cover.sh 2>&1) || true
  AFTER=$(grep '^XRAY_SNI=' "$WORK_DIR/.env" | cut -d= -f2)
  if [[ "$BEFORE" == "$AFTER" ]]; then
    ALL_UNIQUE=false
    break
  fi
  SEEN_DOMAINS+=("$AFTER")
done
if $ALL_UNIQUE; then
  report PASS "8 consecutive rotations always changed domain"
else
  report FAIL "A rotation kept the same domain"
fi

echo ""
echo "=== Test 7: Rotation fails gracefully with single domain ==="
cat > "$WORK_DIR/.env" <<'EOF'
SERVER_IP=1.2.3.4
MTG_SECRET=ee00000000000000000000000000000000676f6f676c652e636f6d
MTG_PORT=2083
MTG_LINK="https://t.me/proxy?server=1.2.3.4&port=2083&secret=ee00000000000000000000000000000000676f6f676c652e636f6d"
XRAY_UUID=aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee
XRAY_PRIVATE_KEY=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
XRAY_PUBLIC_KEY=BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=
XRAY_SHORT_ID=abcdef0123456789
XRAY_SNI=www.microsoft.com
XRAY_DEST=www.microsoft.com:443
XRAY_COVER_DOMAINS=www.microsoft.com
XRAY_ROTATE_HOURS=2
VLESS_URI="vless://test@1.2.3.4:8443#VPN"
SS_METHOD=2022-blake3-aes-256-gcm
SS_PORT=8388
SS_PASSWORD="dGVzdHBhc3N3b3JkMTIzNDU2Nzg5MDEyMzQ1Njc4OTA="
SS_URI="ss://dGVzdA==@1.2.3.4:8388#SS-VPN"
IKE_PSK="bW9ja2lrZXBzazEyMzQ1Njc4OTAxMjM0"
IKE_USER=vpnuser
IKE_PASSWORD=mockikepass
PAGE_USER=admin
PAGE_PASSWORD=testpass1234
EOF
OUTPUT=$( (cd "$WORK_DIR" && WEBROOT="$WEBROOT" bash rotate-reality-cover.sh 2>&1) || true)
if echo "$OUTPUT" | grep -q "ERROR: need at least two cover domains"; then
  report PASS "Single-domain pool rejected"
else
  report FAIL "Single-domain pool was not rejected: $OUTPUT"
fi

echo ""
echo "=== Test 8: TLS availability check runs on real domains ==="
write_mock_env "www.microsoft.com"
OUTPUT=$( (cd "$WORK_DIR" && WEBROOT="$WEBROOT" bash rotate-reality-cover.sh 2>&1) || true)
if echo "$OUTPUT" | grep -q "Rotated REALITY cover domain"; then
  report PASS "Rotation succeeded with TLS check"
elif echo "$OUTPUT" | grep -q "ERROR: no reachable cover domain"; then
  report FAIL "All domains failed TLS check (network issue?)"
else
  report FAIL "Unexpected output: $OUTPUT"
fi

echo ""
echo "=== Test 9: XRAY_COVER_DOMAINS pool is preserved after rotation ==="
POOL_AFTER=$(grep '^XRAY_COVER_DOMAINS=' "$WORK_DIR/.env" | cut -d= -f2)
if [[ "$POOL_AFTER" == "$MOCK_DOMAINS" ]]; then
  report PASS "Domain pool unchanged after rotation"
else
  report FAIL "Domain pool changed: $POOL_AFTER (expected $MOCK_DOMAINS)"
fi

echo ""
echo "======================================="
echo "Results: $PASS passed, $FAIL failed"
echo "======================================="
exit "$FAIL"
