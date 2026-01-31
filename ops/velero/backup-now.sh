#!/usr/bin/env bash
set -euo pipefail

# Create an on-demand Velero backup for monitoring + linkding.
# Usage: ./backup-now.sh [name-prefix]

prefix="${1:-manual-full}"
timestamp="$(date +%Y%m%d-%H%M)"
backup_name="${prefix}-${timestamp}"

velero backup create "${backup_name}" \
  --include-namespaces monitoring,linkding \
  --default-volumes-to-fs-backup \
  --ttl 720h0m0s

echo "Created backup: ${backup_name}"
