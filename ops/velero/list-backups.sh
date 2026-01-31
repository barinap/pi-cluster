#!/usr/bin/env bash
set -euo pipefail

# List Velero backups in a readable table.

velero backup get -o wide
