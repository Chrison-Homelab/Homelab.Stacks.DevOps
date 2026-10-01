#!/usr/bin/env bash
#
# openbao-bootstrap.sh — harden a freshly installed OpenBao (DevOps CT 3007, superproject #609).
# Run ONCE, by Christian, from the workstation, with the Bitwarden CLI unlocked.
#
# WHY THIS EXISTS: community-scripts' installer inits OpenBao with ONE key share and writes the
# unseal key AND the root token in plaintext to /etc/openbao/openbao.env, plus a systemd drop-in
# that unseals from that file on every start. The seal is then decorative: the CT disk and every
# PBS backup of it open the store. This script turns it into the design Christian chose:
#
#   1. KV v2 at secret/, an `admin` policy + a `christian` userpass login (the audit log is
#      declared in openbao.hcl by the provisioner; OpenBao 2.x refuses it over the API)
#   2. INIT 2-of-3 directly if the installer never initialised (what CT 3007 got), or else
#      REKEY its 1-of-1 to 2-of-3 (the installer's single key stops working)
#   3. the 3 shares + the admin login go into Christian's Bitwarden vault, read back and compared
#   4. root token REVOKED, plaintext lines + auto-unseal drop-in removed
#   5. TLS cert re-issued with the real name/IP in its SAN (the package's has CN=OpenBao only)
#   6. restart → proven SEALED (nothing on disk can open it) → unsealed with 2 shares
#   7. proven: the old root token is dead, the admin login works
#
# KEY HANDLING: secrets never go in argv, never to the terminal, never to a log. They travel
# over ssh STDIN inside the script text sent to `pct exec … bash -s`, and live on the
# workstation only in shell variables plus ONE mode-600 lifeline file ($LIFELINE). That file
# holds the new shares from the moment the rekey returns until Bitwarden has them verified.
# If anything fails after the rekey, it is the only copy: the script says where it is and
# leaves it alone.
#
# Re-running after success is refused: the store is no longer 1-of-1, and the root token that
# steps 1–2 need is gone. Everything later is `bao` with the admin login, or generate-root
# with 2 shares.
#
# Usage:
#   export BW_SESSION="$(bw unlock --raw)"
#   stacks/DevOps/tools/openbao-bootstrap.sh            # does it
#   stacks/DevOps/tools/openbao-bootstrap.sh --check    # preflight only, changes nothing
set -euo pipefail

NODE="${OPENBAO_NODE:-hpe-01.homelab.chrison.internal}"
CTID="${OPENBAO_CTID:-3007}"
FQDN="openbao.devops.chrison.internal"
IP="10.10.30.7"
SHARES=3
THRESHOLD=2
ITEM_SHARES="OpenBao CT 3007 — unseal shares"
ITEM_ADMIN="OpenBao CT 3007 — admin login"
CHECK_ONLY=0; TEST=0
[ "${1:-}" = "--check" ] && CHECK_ONLY=1
# --test-no-bitwarden: the whole run minus Bitwarden, for rehearsing against a CT snapshot that is
# rolled back afterwards (the shares it produces die with the rollback). Never use it for real.
[ "${1:-}" = "--test-no-bitwarden" ] && TEST=1

die() { echo "✗ $*" >&2; exit 1; }
say() { echo "▸ $*"; }

# Run a script inside the CT. The script arrives on stdin, so anything interpolated into it
# (shares, passwords) never appears in a process list on the workstation, the node or the CT.
in_ct() { ssh -o BatchMode=yes "root@$NODE" "LC_ALL=C pct exec $CTID -- bash -s" 2>/dev/null; }

# ── preflight ────────────────────────────────────────────────────────────────────────────
command -v jq >/dev/null || die "jq not found"
if [ "$TEST" = 0 ]; then
  command -v bw >/dev/null || die "bw (Bitwarden CLI) not found"
  [ "$(bw status 2>/dev/null | jq -r .status)" = "unlocked" ] \
    || die "Bitwarden is locked — run: export BW_SESSION=\"\$(bw unlock --raw)\""
  bw sync >/dev/null
fi

state=$(in_ct <<'EOF'
set -e
. /etc/openbao/openbao.env 2>/dev/null || true
s=$(curl -fsSk https://127.0.0.1:8200/v1/sys/seal-status) || { echo '{"error":"unreachable"}'; exit 0; }
has=0; [ -n "${BAO_UNSEAL_KEY:-}" ] && [ -n "${BAO_ROOT_TOKEN:-}" ] && has=1
echo "$s" | jq -c --argjson has $has '. + {plaintext:$has}'
EOF
) || die "cannot reach CT $CTID on $NODE"
echo "$state" | jq -e 'has("error")|not' >/dev/null || die "OpenBao not answering in CT $CTID: $state"
n=$(echo "$state" | jq .n); sealed=$(echo "$state" | jq .sealed); plain=$(echo "$state" | jq .plaintext)
say "CT $CTID: initialised=$(echo "$state" | jq .initialized) shares=$n sealed=$sealed plaintext-keys-on-disk=$plain"
# Two starting states are accepted, nothing else:
#   rekey — the installer's: initialised 1-of-1, unsealed, unseal key + root token in plaintext
#   init  — never initialised. What CT 3007 actually got: the 2.7.0 .deb's `file` storage made
#           the installer die before its init (#609), so we init 2-of-3 directly and no single
#           key or on-disk root token ever exists.
if [ "$(echo "$state" | jq .initialized)" = false ]; then MODE=init
elif [ "$n" = 1 ] && [ "$plain" = 1 ] && [ "$sealed" = false ]; then MODE=rekey
else die "neither a fresh install (1-of-1, keys on disk) nor uninitialised — refusing. Already bootstrapped?"
fi
say "mode: $MODE"
[ "$TEST" = 1 ] || for it in "$ITEM_SHARES" "$ITEM_ADMIN"; do
  [ "$(bw list items --search "$it" | jq --arg n "$it" '[.[]|select(.name==$n)]|length')" = 0 ] \
    || die "Bitwarden already has an item named '$it' — refusing to create a second"
done
say "preflight OK"
[ "$CHECK_ONLY" = 1 ] && exit 0

LIFELINE="$(mktemp -t openbao-shares)"; chmod 600 "$LIFELINE"
# Hex: no quoting hazards. And NO PIPE: `tr < /dev/urandom | head` dies of SIGPIPE under
# pipefail, which killed the first rehearsal (exit 141) right after preflight.
ADMIN_PW="$(openssl rand -hex 24)"

# The configuration both modes run, with $TOKEN set in the CT: KV v2, admin policy, userpass
# login. NOT the audit device: OpenBao 2.x refuses to create one over the API ("use declarative,
# config-based audit device management"), so the provisioner declares it in openbao.hcl. Emitted into the remote script, so the password travels on stdin only.
configure() { cat <<CFG
export BAO_ADDR=https://127.0.0.1:8200 BAO_SKIP_VERIFY=true BAO_TOKEN="\$TOKEN"
bao secrets list -format=json | jq -e 'has("secret/")' >/dev/null \
  || bao secrets enable -path=secret -version=2 kv >/dev/null
printf '%s\n' 'path "*" { capabilities = ["create","read","update","delete","list","sudo"] }' \
  | bao policy write admin - >/dev/null
bao auth list -format=json | jq -e 'has("userpass/")' >/dev/null || bao auth enable userpass >/dev/null
printf '%s' '${ADMIN_PW}' | bao write auth/userpass/users/christian password=- policies=admin >/dev/null
CFG
}

ROOT=""   # init mode only: the root token from init, revoked in phase 4
if [ "$MODE" = rekey ]; then
  # ── 1+2 (rekey): configure with the installer's root token, then rekey ─────────────────
  say "configuring (kv, admin policy, userpass) and rekeying to $THRESHOLD-of-$SHARES"
  in_ct > "$LIFELINE" <<EOF
set -euo pipefail
. /etc/openbao/openbao.env
TOKEN="\$BAO_ROOT_TOKEN"
$(configure)
# Rekey over the HTTP API: bodies go in on stdin (--data @-), the token as a header read from a
# process substitution, so neither the key nor the token is ever an argument.
hdr() { printf 'X-Vault-Token: %s\n' "\$TOKEN"; }
nonce=\$(printf '{"secret_shares":$SHARES,"secret_threshold":$THRESHOLD}' \
  | curl -fsSk -X PUT -H @<(hdr) --data @- https://127.0.0.1:8200/v1/sys/rekey/init | jq -r .nonce)
jq -nc --arg k "\$BAO_UNSEAL_KEY" --arg n "\$nonce" '{key:\$k,nonce:\$n}' \
  | curl -fsSk -X PUT -H @<(hdr) --data @- https://127.0.0.1:8200/v1/sys/rekey/update \
  | jq -c '{keys:.keys_base64}'
EOF
else
  # ── 1+2 (init): initialise 2-of-3 directly ────────────────────────────────────────────
  say "initialising $THRESHOLD-of-$SHARES"
  in_ct > "$LIFELINE" <<EOF
set -euo pipefail
printf '{"secret_shares":$SHARES,"secret_threshold":$THRESHOLD}' \
  | curl -fsSk -X PUT --data @- https://127.0.0.1:8200/v1/sys/init | jq -c '{keys:.keys_base64, root:.root_token}'
EOF
  ROOT="$(jq -r '.root // empty' "$LIFELINE" 2>/dev/null)"
  [ -n "$ROOT" ] || die "init returned no root token. Lifeline (may hold the shares): $LIFELINE — do NOT delete it."
fi
[ "$(jq '.keys|length' "$LIFELINE" 2>/dev/null)" = "$SHARES" ] \
  || die "$MODE did not return $SHARES shares. Lifeline (may be empty or partial): $LIFELINE — do NOT delete it."
say "$MODE done — $SHARES shares held only in $LIFELINE until Bitwarden has them"
S=(); while IFS= read -r k; do S+=("$k"); done < <(jq -r '.keys[]' "$LIFELINE")   # bash 3.2: no mapfile

if [ "$MODE" = init ]; then
  say "unsealing with $THRESHOLD shares and configuring (kv, admin policy, userpass)"
  in_ct <<EOF || die "configure after init failed. Lifeline kept: $LIFELINE"
set -euo pipefail
printf '{"key":"%s"}' '${S[0]}' | curl -fsSk -X PUT --data @- https://127.0.0.1:8200/v1/sys/unseal >/dev/null
printf '{"key":"%s"}' '${S[1]}' | curl -fsSk -X PUT --data @- https://127.0.0.1:8200/v1/sys/unseal >/dev/null
TOKEN='${ROOT}'
$(configure)
EOF
fi

# ── 3: Bitwarden, then read back and compare ────────────────────────────────────────────
if [ "$TEST" = 0 ]; then
say "storing shares + admin login in Bitwarden"
note="OpenBao on CT $CTID ($FQDN / $IP), superproject #609.
Any $THRESHOLD of the $SHARES shares unseal it. After a restart it is SEALED by design:
  pct exec $CTID -- bao operator unseal     (twice, one share each; BAO_ADDR/BAO_SKIP_VERIFY are set in the CT)
There is NO root token (revoked at bootstrap). For root, use generate-root with $THRESHOLD shares:
  bao operator generate-root -init   → then -nonce=… with each share → decode with the OTP.
Everyday admin: userpass login 'christian' (the '$ITEM_ADMIN' item)."
bw get template item | jq --arg name "$ITEM_SHARES" --arg notes "$note" \
  --arg a "${S[0]}" --arg b "${S[1]}" --arg c "${S[2]}" \
  '.type=2 | .secureNote={type:0} | .name=$name | .notes=$notes | .login=null
   | .fields=[{name:"share 1",value:$a,type:1},{name:"share 2",value:$b,type:1},{name:"share 3",value:$c,type:1}]' \
  | bw encode | bw create item >/dev/null
bw get template item | jq --arg name "$ITEM_ADMIN" --arg pw "$ADMIN_PW" --arg uri "https://$FQDN:8200/ui/" \
  '.type=1 | .name=$name | .notes="userpass auth, policy admin. CLI: bao login -method=userpass username=christian"
   | .login={username:"christian",password:$pw,uris:[{match:null,uri:$uri}]}' \
  | bw encode | bw create item >/dev/null
bw sync >/dev/null
got=$(bw list items --search "$ITEM_SHARES" | jq -r --arg n "$ITEM_SHARES" '.[]|select(.name==$n)|.fields|map(.value)|join(" ")')
[ "$got" = "${S[*]}" ] || die "Bitwarden read-back of the shares did not match. Lifeline kept: $LIFELINE"
[ "$(bw get password "$ITEM_ADMIN")" = "$ADMIN_PW" ] || die "Bitwarden read-back of the admin login did not match"
say "Bitwarden read-back matches"
else
  say "TEST: skipping Bitwarden — shares stay in $LIFELINE; roll the CT snapshot back afterwards"
fi

# ── 4–7: revoke root, strip plaintext, re-issue TLS, prove sealed, unseal, prove logins ─
say "revoking root, removing plaintext keys + auto-unseal, re-issuing TLS, restarting"
result=$(in_ct <<EOF
set -euo pipefail
. /etc/openbao/openbao.env 2>/dev/null || true
export BAO_ADDR=https://127.0.0.1:8200 BAO_SKIP_VERIFY=true
OLD_ROOT='${ROOT}'; [ -n "\$OLD_ROOT" ] || OLD_ROOT="\${BAO_ROOT_TOKEN:-}"
BAO_TOKEN="\$OLD_ROOT" bao token revoke -self >/dev/null
sed -i '/^BAO_UNSEAL_KEY=/d;/^BAO_ROOT_TOKEN=/d' /etc/openbao/openbao.env
rm -f /etc/systemd/system/openbao.service.d/unseal.conf /etc/openbao/openbao-init.json
rmdir /etc/systemd/system/openbao.service.d 2>/dev/null || true
cd /opt/openbao/tls
openssl req -x509 -newkey rsa:4096 -sha256 -nodes -days 1095 -keyout tls.key.new -out tls.crt.new \
  -subj "/O=Homelab/CN=$FQDN" \
  -addext "subjectAltName=DNS:$FQDN,DNS:localhost,IP:$IP,IP:127.0.0.1" >/dev/null 2>&1
mv tls.key.new tls.key; mv tls.crt.new tls.crt
chown openbao:openbao tls.key tls.crt; chmod 600 tls.key tls.crt
systemctl daemon-reload
systemctl restart openbao
for i in \$(seq 1 30); do curl -fsSk -o /dev/null https://127.0.0.1:8200/v1/sys/seal-status && break; sleep 1; done
after_restart=\$(curl -fsSk https://127.0.0.1:8200/v1/sys/seal-status | jq .sealed)
printf '{"key":"%s"}' '${S[0]}' | curl -fsSk -X PUT --data @- https://127.0.0.1:8200/v1/sys/unseal >/dev/null
printf '{"key":"%s"}' '${S[1]}' | curl -fsSk -X PUT --data @- https://127.0.0.1:8200/v1/sys/unseal >/dev/null
st=\$(curl -fsSk https://127.0.0.1:8200/v1/sys/seal-status)
old=\$(curl -sk -o /dev/null -w '%{http_code}' -H "X-Vault-Token: \$OLD_ROOT" https://127.0.0.1:8200/v1/auth/token/lookup-self)
login=\$(printf '{"password":"%s"}' '${ADMIN_PW}' | curl -sk -o /dev/null -w '%{http_code}' --data @- https://127.0.0.1:8200/v1/auth/userpass/login/christian)
plain=\$(grep -cE '^BAO_(UNSEAL_KEY|ROOT_TOKEN)=' /etc/openbao/openbao.env || true)
san=\$(openssl x509 -in tls.crt -noout -ext subjectAltName | tail -1 | tr -d ' ')
fp=\$(openssl x509 -in tls.crt -noout -fingerprint -sha256 | cut -d= -f2)
echo "\$st" | jq -c --argjson ar "\$after_restart" --arg old "\$old" --arg login "\$login" \
  --arg plain "\$plain" --arg san "\$san" --arg fp "\$fp" \
  '{sealed_after_restart:\$ar, sealed_now:.sealed, t, n, old_root_http:\$old, admin_login_http:\$login, plaintext_lines:\$plain, san:\$san, fingerprint:\$fp}'
EOF
) || die "post-rekey phase failed. The shares ARE in Bitwarden; lifeline kept anyway: $LIFELINE"
echo "$result" | jq .
ok=$(echo "$result" | jq '(.sealed_after_restart==true) and (.sealed_now==false) and (.t==2) and (.n==3)
        and (.old_root_http=="403") and (.admin_login_http=="200") and (.plaintext_lines=="0")')
[ "$ok" = true ] || die "a post-condition failed (see above). The shares ARE in Bitwarden; lifeline kept: $LIFELINE"

[ "$TEST" = 1 ] && { say "TEST passed — lifeline left at $LIFELINE; delete it after the rollback"; exit 0; }
rm -P "$LIFELINE" 2>/dev/null || rm -f "$LIFELINE"
unset S ADMIN_PW ROOT
say "done: $THRESHOLD-of-$SHARES seal, root revoked, nothing on disk can unseal it, unsealed now."
say "next: add CT $CTID to the PBS job (it was deliberately left out while the keys were on disk)."
