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
1. Create the `velero` namespace (it is NOT managed by Flux). Do this right after
   `flux bootstrap` (or before it), otherwise Kustomization `apps` fails because it
   applies a Secret into the `velero` namespace:
   - `kubectl create namespace velero`
2. Credentials are managed by GitOps (since 2026-10-21):
   - Secret `velero/cloud-credentials`, key `cloud` (AWS credentials file format),
     is SOPS-encrypted in `apps/staging/velero/cloud-credentials.sops.yaml`
     and applied by Flux Kustomization `apps` (needs the `flux-system/sops-age` secret).
   - Do NOT create the secret manually. Verify after reconcile:
     `kubectl -n velero get secret cloud-credentials` (label `kustomize.toolkit.fluxcd.io/name=apps`).
   - To rotate the iDrive key: edit with `sops apps/staging/velero/cloud-credentials.sops.yaml`,
     commit, `flux reconcile kustomization apps`, then
     `kubectl -n velero rollout restart deploy/velero ds/node-agent`.
3. Install/upgrade Velero with filesystem backups (kopia) and the AWS plugin:
   - Example Helm values or CLI install (adjust to your setup). `--no-secret` because the
     `cloud-credentials` secret comes from Flux. Example Velero CLI:
     `velero install \
       --provider aws \
       --plugins velero/velero-plugin-for-aws:<AWS_PLUGIN_TAG> \
       --bucket pi-cluster-backup \
       --prefix velero \
       --backup-location-config region=eu-central-1,s3ForcePathStyle=true,s3Url=https://h1t7.fra203.idrivee2-84.com \
       --no-secret \
       --use-node-agent \
       --default-volumes-to-fs-backup`
   - Or apply the checked-in BSL: `kubectl apply -f ops/velero/backupstoragelocation.yaml`
   - Bucket layout: Velero data under `velero/` (`backups/`, `kopia/`); CNPG stays at `cnpg/` (do not put CNPG in the Velero prefix).
4. Verify BackupStorageLocation and Velero components:
   - `velero backup-location get` (must show **Available**, prefix `velero`)
   - `kubectl -n velero get bsl default -o yaml`
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
- The schedule name for daily backups is `cluster-daily` (`0 1 * * *`).
- Example successful backup name: `monitoring-linkding-full-20260131-1321`.
- Always validate restore results and PVC reattachments before declaring recovery complete.

## Lokální záloha NAS na USB (Hyper Backup)

NAS: Synology DS120j `BladeSynology` (192.168.1.206), DSM 7.4.1, Hyper Backup 4.2.2.
Cíl: USB disk SanDisk Extreme 55AE (~3.6 TiB, ext4), sdílená složka `usbshare1` (`/volumeUSB1/usbshare`).

### Co se zálohuje
| Úloha | Obsah | Plán | Verze / kontrola |
|---|---|---|---|
| `NAS-data-USB` (task_id 1, repo `usbshare1/NAS-data-USB.hbk`) | sdílené složky `pi_cluster`, `TimeMachine` + konfigurace systému DSM (Hyper Backup ji přidává automaticky) | denně 03:00 | Smart Recycle, max. 30 verzí, kontrola integrity každou sobotu 08:00, komprese zapnutá, bez šifrování zálohy |

Poznámky:
- `pi_cluster` je šifrovaná sdílená složka. Hyper Backup ji zálohuje **jen když je odemčená (připojená)**. Pokud je zamčená, úloha skončí stavem „částečně dokončeno“ (log: *The backup source shared folder is encrypted and not mounted*). Oprava: odemknout složku (Ovládací panely → Sdílená složka → pi_cluster → Šifrování → Připojit), případně zapnout automatické připojení po startu přes Správce klíčů.
- Zálohy LUN (iSCSI PVC: `nextcloud-nextcloud-data`, `nextcloud-nextcloud`, `forgejo/gitea-shared-storage`) **nejsou** přes Hyper Backup multi-version k dispozici. DS120j tuto funkci nepodporuje (jen modely FS/btrfs). Dostupná je pouze starší jednoverzová „LUN backup“. Data aplikací v clusteru pokrývá Velero (viz výše).

Mapování PV → LUN (pro ruční obnovu):
- `nextcloud/nextcloud-nextcloud-data` → `k8s-csi-pvc-f0dec89a-aee1-43a0-aff4-feacf2747a5e`
- `nextcloud/nextcloud-nextcloud` → `k8s-csi-pvc-697b5abf-05da-472b-a6a2-f70699f7f6b4`
- `forgejo/gitea-shared-storage` → `k8s-csi-pvc-19406990-5522-4188-9fd9-b6973e091336`

### Obnova
1. **Z NAS (DSM):** Hyper Backup → úloha `NAS-data-USB` → Obnovit → Data (nebo Konfigurace systému) → vybrat verzi → vybrat složky/soubory → obnovit na původní místo nebo jinam.
2. **Bez NAS:** připojit USB disk (ext4) k Linuxu, nebo zkopírovat `NAS-data-USB.hbk` a otevřít ho v **Hyper Backup Explorer** (Windows/macOS/Linux, ke stažení na synology.com) → procházet verze → extrahovat soubory.
3. **Konfigurace DSM:** Hyper Backup → Obnovit → Konfigurace systému → vybrat verzi.
4. **LUN (pokud se zavede jednoverzová LUN záloha):** Hyper Backup → Obnovit → LUN → vybrat zálohu → obnovit jako nový LUN, ten pak namapovat na PV nebo z něj data zkopírovat.

### Time Machine pro Mac
- Sdílená složka `TimeMachine` na `volume1`: bez šifrování a bez koše. Kvóta 2 TB se nastavuje jako uživatelská kvóta uživatele `timemachine`, protože volume1 je ext4 a kvóta sdílené složky na něm nejde.
- SMB3 (min. i max.), Bonjour Time Machine broadcast je zapnutý. V DSM firewallu jsou pro LAN 192.168.1.0/24 povolené porty TCP 445 a UDP 5353.
- Připojení: `smb://192.168.1.206/TimeMachine`, případně se NAS sám nabídne v Nastavení systému → Time Machine.
- Uživatel `timemachine` (bez administrátorských práv, přístup RW jen k `TimeMachine`). Heslo je uložené pouze lokálně na BladeAsus v `~/timemachine-password` (0600), v repu ani v dokumentaci není.
