#!/bin/bash
# ────────────────────────────────────────────────────────────
# generate-wg-keys.sh — Generate WireGuard keypairs for all hosts
# Run once, then copy the keys into group_vars/vault.yml
# ────────────────────────────────────────────────────────────
set -euo pipefail

HOSTS=("daftpunk" "rammstein" "greenday" "yoga" "sophon")
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KEYS_DIR="${SCRIPT_DIR}/../wg-keys"

echo "=== WireGuard Key Generation ==="
echo "Output: ${KEYS_DIR}/"
echo ""

mkdir -p "${KEYS_DIR}"

for host in "${HOSTS[@]}"; do
    echo "--- ${host} ---"
    
    # Generate keypair
    privkey=$(wg genkey)
    pubkey=$(echo "${privkey}" | wg pubkey)
    
    # Save to files
    echo "${privkey}" > "${KEYS_DIR}/${host}.private"
    echo "${pubkey}" > "${KEYS_DIR}/${host}.public"
    
    chmod 600 "${KEYS_DIR}/${host}.private"
    chmod 644 "${KEYS_DIR}/${host}.public"
    
    echo "  Private: ${privkey}"
    echo "  Public:  ${pubkey}"
    echo ""
done

echo "=== Done ==="
echo ""
echo "Keys saved to: ${KEYS_DIR}/"
echo ""
echo "Next steps:"
echo "  1. Copy private keys into group_vars/vault.yml (wg_private_keys)"
echo "  2. Copy public keys into group_vars/vault.yml (wg_public_keys)"
echo "  3. Delete the wg-keys/ directory after copying"
echo "  4. Encrypt vault.yml: ansible-vault encrypt group_vars/vault.yml"
echo ""
echo "  Or use the generated YAML snippet:"
echo ""

# Generate YAML snippet for vault.yml
YAML_FILE="${KEYS_DIR}/vault-snippet.yml"
cat > "${YAML_FILE}" << 'YAML'
# ── WireGuard private keys ─────────────────────────────────
wg_private_keys:
YAML

for host in "${HOSTS[@]}"; do
    echo "  ${host}: \"$(cat "${KEYS_DIR}/${host}.private")\"" >> "${YAML_FILE}"
done

cat >> "${YAML_FILE}" << 'YAML'

# ── WireGuard public keys ──────────────────────────────────
wg_public_keys:
YAML

for host in "${HOSTS[@]}"; do
    echo "  ${host}: \"$(cat "${KEYS_DIR}/${host}.public")\"" >> "${YAML_FILE}"
done

echo "YAML snippet written to: ${YAML_FILE}"
echo "Copy contents into group_vars/vault.yml"
