# DR Runbook - Velero (pi-cluster)

This runbook covers disaster recovery for the pi-cluster GitOps repo and Velero backups.
It does not contain secrets. Replace placeholders such as <IDRIVE_ACCESS_KEY> when executing.

## Assumptions
- You have kubectl, helm, kustomize, flux CLI, and velero CLI installed locally.
- You can access the new k3s cluster and the IDrive e2 bucket.
- This repo is available (same Git URL used by Flux).

## DR Scenario: Totální ztráta clusteru

### 1) Rebuild a new k3s cluster
1. Provision Raspberry Pi nodes and networking (same or new IP ranges).
2. Install k3s on the first control-plane node:
   - Example (replace token and server IPs as needed):
     - On first node:
       `curl -sfL https://get.k3s.io | K3S_TOKEN=<K3S_TOKEN> sh -`
     - On additional nodes:
       `curl -sfL https://get.k3s.io | K3S_URL=https://<CONTROL_PLANE_IP>:6443 K3S_TOKEN=<K3S_TOKEN> sh -`
3. Configure local kubectl:
   - Copy kubeconfig from the control-plane node:
     `scp <USER>@<CONTROL_PLANE_IP>:/etc/rancher/k3s/k3s.yaml ~/.kube/config`
   - Update the server address inside `~/.kube/config` to the correct IP/DNS.
4. Verify cluster access:
   - `kubectl get nodes -o wide`

### 2) Bootstrap FluxCD pointing at this repo
1. Install Flux CLI if needed.
2. Bootstrap Flux (replace placeholders):
   `flux bootstrap git \
     --url=<GIT_REPO_URL> \
     --branch=<GIT_BRANCH> \
     --path=clusters/staging \
     --token-auth`
3. Confirm Flux components and kustomizations are healthy:
   - `kubectl -n flux-system get pods`
   - `flux get kustomizations`

### 3) Reconfigure Synology CSI (high level)
1. Ensure Synology CSI manifests/HelmRelease exist in this repo.
2. Create or update the required Kubernetes Secrets in the cluster:
   - Example placeholders (do NOT commit secrets):
     `kubectl -n <CSI_NAMESPACE> create secret generic synology-csi-client-info \
       --from-literal=username=<SYNOLOGY_USERNAME> \
       --from-literal=password=<SYNOLOGY_PASSWORD>`
3. Confirm the StorageClass `synology-iscsi` exists and is default:
   - `kubectl get storageclass`
4. Verify CSI pods are running:
   - `kubectl -n <CSI_NAMESPACE> get pods`

### 4) Reinstall Velero and point it to the existing S3 bucket
1. Create a namespace for Velero if not managed by Flux (if managed, update Git):
   - `kubectl create namespace velero`
2. Provide credentials as a Kubernetes Secret (example):
   - `cat <<'CREDS' > /tmp/velero-credentials
[default]
aws_access_key_id=<IDRIVE_ACCESS_KEY>
aws_secret_access_key=<IDRIVE_SECRET_KEY>
CREDS`
   - `kubectl -n velero create secret generic cloud-credentials \
       --from-file=cloud=/tmp/velero-credentials`
3. Install/upgrade Velero with filesystem backups (kopia) and the AWS plugin:
   - Example Helm values or CLI install (adjust to your setup). Example Velero CLI:
     `velero install \
       --provider aws \
       --plugins velero/velero-plugin-for-aws:<AWS_PLUGIN_TAG> \
       --bucket pi-cluster-backup \
       --backup-location-config region=eu-central-1,s3ForcePathStyle=true,s3Url=https://h1t7.fra203.idrivee2-84.com \
       --secret-file /tmp/velero-credentials \
       --use-node-agent \
       --default-volumes-to-fs-backup`
4. Verify BackupStorageLocation and Velero components:
   - `velero backup-location get`
   - `kubectl -n velero get pods`

### 5) List existing backups and restore
1. List backups in the bucket:
   - `velero backup get`
2. Restore monitoring + linkding into original namespaces:
   - Choose the latest backup, for example:
     `velero restore create monitoring-linkding-restore-<YYYYMMDD> \
       --from-backup monitoring-linkding-full-20260131-1321`
   - Check restore status:
     `velero restore get`
3. Verify workloads:
   - `kubectl -n monitoring get pods`
   - `kubectl -n linkding get pods`

## DR Scenario: Testovací obnova do jiného namespace

### 1) Restore linkding into a test namespace
1. Create restore with namespace mapping:
   - `velero restore create linkding-restore-test-<YYYYMMDD> \
       --from-backup <BACKUP_NAME> \
       --namespace-mappings linkding:linkding-restore-test`
2. Check restore status:
   - `velero restore get`
3. Verify restored resources:
   - `kubectl -n linkding-restore-test get pods`
   - `kubectl -n linkding-restore-test get pvc`

### 2) Clean up test restores
1. Delete the Velero restore object:
   - `velero restore delete linkding-restore-test-<YYYYMMDD>`
2. Delete the test namespace:
   - `kubectl delete namespace linkding-restore-test`
3. Optionally delete the backup (only if no longer needed):
   - `velero backup delete <BACKUP_NAME>`

## Notes
- The schedule name for daily backups is `monitoring-linkding-daily`.
- Example successful backup name: `monitoring-linkding-full-20260131-1321`.
- Always validate restore results and PVC reattachments before declaring recovery complete.
