#!/usr/bin/env bash
set -euo pipefail

# Renew Let's Encrypt certs via Cloudflare DNS-01 and store as SOPS-encrypted secrets.
# Usage:
#   export CF_Token="<CLOUDFLARE_API_TOKEN>"
#   export CF_Account_ID="<CLOUDFLARE_ACCOUNT_ID>"
#   # Optional but recommended if API tokens are scoped per-zone:
#   export CF_Zone_ID="<CLOUDFLARE_ZONE_ID>"
#   ./apps/staging/kan/renew-tls.sh

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
AGE_RECIPIENT="age19fd7xlck0r3645chqjxq2m22qmtmatr4g0yghplsm33cn5yq7fuq69734h"
DOMAINS=("tasks.barina.tech" "tasks-storage.barina.tech")

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

require_cmd sops
require_cmd kubectl

if ! command -v acme.sh >/dev/null 2>&1; then
  if [[ -x "${HOME}/.acme.sh/acme.sh" ]]; then
    ACME_SH="${HOME}/.acme.sh/acme.sh"
  else
    echo "acme.sh not found. Install with: brew install acme.sh" >&2
    exit 1
  fi
else
  ACME_SH="$(command -v acme.sh)"
fi

if [[ -z "${CF_Token:-}" || -z "${CF_Account_ID:-}" ]]; then
  echo "CF_Token and CF_Account_ID must be set in the environment." >&2
  exit 1
fi

if [[ -z "${CF_Zone_ID:-}" ]]; then
  echo "Warning: CF_Zone_ID not set. If DNS-01 fails with 'invalid domain', set CF_Zone_ID for barina.tech." >&2
fi

TMP_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

for domain in "${DOMAINS[@]}"; do
  "${ACME_SH}" --set-default-ca --server letsencrypt >/dev/null 2>&1 || true
  echo "Issuing/renewing cert for ${domain}..."
  "${ACME_SH}" --issue --dns dns_cf -d "${domain}"

  key_file="${TMP_DIR}/${domain}.key"
  crt_file="${TMP_DIR}/${domain}.crt"

  "${ACME_SH}" --install-cert -d "${domain}" \
    --key-file "${key_file}" \
    --fullchain-file "${crt_file}"

  secret_name=""
  out_path=""
  if [[ "${domain}" == "tasks.barina.tech" ]]; then
    secret_name="tasks-tls-secret"
    out_path="${REPO_ROOT}/apps/staging/kan/tasks-tls-secret.sops.yaml"
  else
    secret_name="tasks-storage-tls-secret"
    out_path="${REPO_ROOT}/apps/staging/kan/tasks-storage-tls-secret.sops.yaml"
  fi

  tmp_yaml="${TMP_DIR}/${secret_name}.yaml"

  kubectl create secret tls "${secret_name}" \
    --cert "${crt_file}" \
    --key "${key_file}" \
    --namespace kan \
    --dry-run=client -o yaml | sed '/^  namespace:/d' > "${tmp_yaml}"

  sops --encrypt \
    --age "${AGE_RECIPIENT}" \
    --encrypted-regex '^(data|stringData)$' \
    "${tmp_yaml}" > "${out_path}"

  echo "Updated: ${out_path}"
  echo
  echo "Reminder: git commit + push these changes so Flux applies them."
  echo
  rm -f "${tmp_yaml}" "${key_file}" "${crt_file}"

done
