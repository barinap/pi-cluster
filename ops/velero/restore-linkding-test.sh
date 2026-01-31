#!/usr/bin/env bash
set -euo pipefail

# Restore linkding into linkding-restore-test using namespace mapping.
# Usage: ./restore-linkding-test.sh <backup-name>

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <backup-name>" >&2
  exit 1
fi

backup_name="$1"
timestamp="$(date +%Y%m%d-%H%M)"
restore_name="linkding-restore-test-${timestamp}"

echo "Creating restore ${restore_name} from backup ${backup_name}"

velero restore create "${restore_name}" \
  --from-backup "${backup_name}" \
  --namespace-mappings linkding:linkding-restore-test
