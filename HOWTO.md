# pi-cluster — HOWTO

Kompletní popis, jak je domácí Kubernetes cluster (Raspberry Pi / k3s) postavený,
jak se spravuje přes GitOps a jak provádět běžné operace.

> Tento dokument **neobsahuje žádné tajné hodnoty**. Všechny secrets jsou v repu
> uložené zašifrované přes SOPS/age a v textu se na ně odkazuje pouze jménem.

---

## 1. Přehled

Cluster běží na třech Raspberry Pi uzlech s distribucí **k3s** (`v1.30.6+k3s1`)
a je řízen výhradně **GitOps** přístupem přes **FluxCD** — jediný zdroj pravdy je
tento Git repozitář. Nic se do clusteru nenasazuje ručně `kubectl apply`;
veškeré změny jdou přes commit do větve `main`, který Flux automaticky aplikuje.

### Uzly

| Uzel | Role | IP | Poznámka |
|---|---|---|---|
| `malina` | control-plane / master | 192.168.1.108 | řídicí uzel |
| `rpinode1` | worker | 192.168.1.21 | |
| `rpinode2` | worker | 192.168.1.109 | sem se typicky připojují iSCSI svazky |

Uzly jsou propojené **Ethernetem** (dříve WiFi — viz [§12 Známé problémy](#12-známé-problémy-a-poučení)).

### Externí závislosti

| Služba | Účel |
|---|---|
| **Synology NAS** (192.168.1.206, DSM `/volume1`) | perzistentní úložiště přes iSCSI (Synology CSI) |
| **Cloudflare** | DNS pro `*.barina.tech`, DNS-01 pro Let's Encrypt, tunnel pro linkding |
| **Let's Encrypt** | TLS certifikáty pro veřejné domény |
| **IDrive e2** (S3, `h1t7.fra203.idrivee2-84.com`) | off-site zálohy (CNPG barman + Velero) |

---

## 2. GitOps architektura (Flux)

Flux je nabootstrapovaný proti repu `ssh://git@github.com/barinap/pi-cluster`,
větev `main`. Vstupní bod je adresář `clusters/staging` (přestože je cluster
de facto produkční, prostředí se jmenuje „staging").

```
GitRepository (flux-system)         interval 1 min  — stahuje main
  └─ Kustomization flux-system      path ./clusters/staging, interval 10 min
       ├─ apps                      path ./apps/staging          (SOPS)
       ├─ monitoring-controllers    path ./monitoring/controllers/staging
       ├─ monitoring-configs        path ./monitoring/configs/staging (SOPS)
       └─ storage-synology-csi      path ./storage/synology-csi  (SOPS)
```

Každá Flux `Kustomization` má `prune: true` — co zmizí z Gitu, zmizí i z clusteru.
Kustomizace, které obsahují šifrované secrets, mají nastavenou `decryption.provider: sops`
s odkazem na secret `sops-age` v namespace `flux-system`.

**Důsledek:** chceš-li cokoliv změnit, uprav manifest, commitni a pushni do `main`.
Flux změnu do ~1–10 minut aplikuje. Urychlit jde ručním reconcile (viz [§11](#11-běžné-operace)).

---

## 3. Struktura repozitáře

```
clusters/staging/        # Flux bootstrap — definice GitRepository a Kustomizations
  flux-system/           # vygenerováno fluxem (gotk-*), needitovat ručně
  apps.yaml              # Kustomization "apps"        → ./apps/staging
  monitoring.yaml        # Kustomizations monitoring-* → ./monitoring/...
  cnpg-operator.yaml     # Kustomization cnpg-operator → ./controllers/cnpg-operator
  coredns.yaml           # Kustomization coredns       → ./controllers/coredns
  storage.yaml           # Kustomization storage       → ./storage/synology-csi
  .sops.yaml             # pravidla šifrování (age recipient)

apps/
  base/                  # znovupoužitelné Kustomize základy (bez prostředí)
    cnpg-cluster/        # CloudNativePG cluster + pgAdmin + zálohy
    linkding/            # Linkding (bookmarky)
  staging/               # overlay pro prostředí + SOPS secrets + ingressy
    cnpg-cluster/
    linkding/

controllers/
  cnpg-operator/         # operátor CloudNativePG (vendorovaný release manifest)
  coredns/               # CoreDNS mimo k3s (2 repliky, PDB) — viz §6

monitoring/
  controllers/           # HelmRepository + HelmRelease kube-prometheus-stack
    base/ , staging/
  configs/               # overlay konfigurace (Grafana TLS secret)
    staging/

storage/
  synology-csi/          # Synology CSI driver, controller, node, StorageClass

ops/
  tls/renew-tls.sh       # obnova Let's Encrypt certů (viz §7)
  velero/                # DR runbook + pomocné skripty pro Velero zálohy

.github/workflows/
  renew-tls.yml          # cron obnova TLS certů (každých 14 dní)
```

Vzor `base` + `staging` overlay: základ je čistý manifest, overlay v `apps/staging`
přidává `namespace`, secrets a ingress. **Overlay vždy nastavuje `namespace` explicitně**
v `kustomization.yaml` — to mj. vstřikuje namespace do secretů generovaných
obnovovacím skriptem (viz [§7](#7-tls--lets-encrypt) a [§12](#12-známé-problémy-a-poučení)).

---

## 4. Správa secrets (SOPS + age)

Secrets se **nikdy neukládají v plaintextu**. Šifrují se nástrojem
[SOPS](https://github.com/getsops/sops) s [age](https://github.com/FiloSottile/age)
backendem.

- **Pravidla šifrování:** `clusters/staging/.sops.yaml` — šifruje pouze pole
  `data` a `stringData` (`encrypted_regex: ^(data|stringData)$`), takže metadata
  (jméno, namespace, typ) zůstávají čitelná pro Flux i v Gitu.
- **Veřejný klíč (recipient):** `age13rglp49t3fzw0q4wq2n9y4g4dgsdv3nc5tzwetnrzjc4nx3z3gwqnd2nzl`
  — je to veřejný klíč, není citlivý; je uvedený i v `.sops.yaml`.
- **Privátní klíč** žije **mimo repo** (lokálně `~/.config/sops/age/keys.txt`,
  v clusteru jako secret `sops-age` v `flux-system`; CI ho nepotřebuje — `renew-tls` šifruje jen veřejným klíčem). Klíč rotován 2026-10-08.

Zašifrované soubory mají příponu `*.sops.yaml` (výjimka: `grafana-tls-secret.yaml`
historicky bez přípony, ale je rovněž SOPS-zašifrovaný).

```bash
# zobrazit/upravit secret lokálně
sops --decrypt apps/staging/linkding/linkding-container-env-secret.yaml
sops apps/staging/linkding/linkding-container-env-secret.yaml   # interaktivní edit
```

---

## 5. Úložiště (Synology CSI / iSCSI)

Perzistentní svazky poskytuje **Synology CSI** driver (`csi.san.synology.com`),
nasazený z `storage/synology-csi`.

- **StorageClass `synology-iscsi`** (výchozí pro cluster):
  - protokol **iSCSI**, NAS `192.168.1.206`, volume `/volume1`, filesystem **ext4**
  - `reclaimPolicy: Delete`, `allowVolumeExpansion: true`, `volumeBindingMode: Immediate`
- Přístupové údaje k DSM jsou v secretu `synology-csi-client-info`
  (`storage/synology-csi/secret-client-info.yaml`, SOPS).
- Vedle toho existuje vestavěná k3s `local-path` třída (taky označená jako default,
  ale aplikace cíleně používají `synology-iscsi`).

Většina PVC (Prometheus, Alertmanager, Grafana, CNPG Postgres, pgAdmin, linkding)
je na iSCSI svazcích z NASu.

---

## 6. Síť a ingress

### Traefik (k3s vestavěný)
Ingress controller je **Traefik**, který přichází s k3s. Service `kube-system/traefik`
je typu `LoadBalancer` (k3s ServiceLB / klippy-lb) a poslouchá na portech 80/443
na všech uzlech.

Veřejně dostupné HTTP(S) služby přes `ingressClassName: traefik`:

| Host | Service | Port | TLS secret |
|---|---|---|---|
| `pgadmin.barina.tech` | pgadmin | 80 | `pgadmin-tls-secret` |
| `grafana.barina.tech` | kube-prometheus-stack-grafana | 80 | `grafana-tls-secret` |

### CoreDNS — mimo k3s, spravuje Flux
Vestavěný CoreDNS z k3s je vypnutý (`/etc/rancher/k3s/config.yaml` na malině:
`disable: [coredns]`). CoreDNS (Deployment `kube-system/coredns`, **2 repliky** rozprostřené
po uzlech, PDB `minAvailable: 1`, ConfigMap `coredns` + volitelný `coredns-custom`,
Service `kube-dns` s `clusterIP: 10.43.0.10`) je v `controllers/coredns/` a spravuje ho
Flux Kustomization `coredns` (`prune: true`, `deletionPolicy: Orphan`).

- **Verze image se při upgradu k3s sama nezmění!** Po každém upgradu k3s porovnat image
  v `controllers/coredns/deployment.yaml` s tím, co by k3s nasadil (v nové verzi k3s:
  `grep image: /var/lib/rancher/k3s/server/manifests/coredns.yaml` — soubor se při
  `disable` nezapisuje; alternativně v release notes k3s / `rancher/mirrored-coredns-coredns`)
  a případně zvednout tag + zkontrolovat Corefile. Pak commit, `flux reconcile ks coredns`.
- `NodeHosts` v ConfigMap `coredns` je **statický** (dříve ho udržoval k3s). Při přidání/změně
  uzlu upravit `controllers/coredns/configmap.yaml`.
- Vlastní DNS pravidla: ConfigMap `kube-system/coredns-custom` (`*.server` / `*.override`).
- Záloha před změnou: `~/backups/coredns-20261028/` na BladeAsus, sqlite `backup-pre-coredns-20261028`
  v `/var/lib/rancher/k3s/server/db/` na malině.
- Rollback na vestavěný: odstranit `disable` z `config.yaml`, `sudo systemctl restart k3s`
  (k3s znovu zapíše `coredns.yaml`), Kustomization `coredns` pozastavit/smazat.

### LoadBalancer služby (mimo ingress)
| Service | Port | Účel |
|---|---|---|
| `cnpg-cluster/pg-cluster-lb` | 5432 | přímý přístup k PostgreSQL primary (např. z pgAdminu / klienta v LAN) |
| `forgejo/forgejo-ssh` | 2222 | git přes SSH (Forgejo, jen LAN) |

### Cloudflare Tunnel (linkding)
Linkding **není** za Traefikem — je vystavený přes **Cloudflare Tunnel**
(`cloudflared`, 2 repliky, tunel `ldpi`). Konfigurace v `apps/staging/linkding/cloudflare.yaml`
směruje `ldpi.barina.tech` → `http://linkding:9090`. Credentials tunelu jsou
v secretu `tunnel-credentials`.

---

## 7. TLS / Let's Encrypt

Veřejné domény za Traefikem mají **Let's Encrypt** certifikáty, vydávané metodou
**DNS-01** přes Cloudflare. Není použitý cert-manager — obnova je řešená skriptem
a GitHub Actions cronem.

### Jak to funguje
1. `ops/tls/renew-tls.sh` projde pole `DOMAINS` a pro každou doménu:
   - `acme.sh --issue --dns dns_cf` vydá/obnoví cert (vytvoří dočasný TXT v Cloudflare DNS),
   - výsledek uloží jako Kubernetes TLS secret, **zašifruje SOPS** a zapíše do repa.
2. GitHub workflow `.github/workflows/renew-tls.yml` to spouští **každých 14 dní**
   (cron `0 3 */14 * *`) i ručně (`workflow_dispatch`), pak commitne a pushne.
3. Flux nové secrets nasadí, Traefik je začne servírovat.

### Domény v obnově
`pgadmin.barina.tech`, `grafana.barina.tech`, `git.barina.tech`.

Mapování doména → (secret, namespace, cesta v repu) je v `case` bloku skriptu.
Skript při generování secretu **odstraňuje řádek `namespace:`**; namespace pak
do secretu vstřikuje `namespace:` pole v příslušné `kustomization.yaml` overlaye
(`cnpg-cluster`, `monitoring/configs/.../kube-prometheus-stack`).
**Bez tohoto pole obnova selže** s chybou „namespace not specified" — viz [§12](#12-známé-problémy-a-poučení).

### Spuštění obnovy ručně (cesta přes workflow — doporučeno)
Potřebné Cloudflare/age klíče (`CF_Token`, `CF_Account_ID`, `CF_Zone_ID`,
`SOPS_AGE_KEY`) jsou uložené v GitHub repo secrets.

```bash
gh workflow run renew-tls.yml     # spustí obnovu
gh run watch                       # sleduje průběh
```

- **`CF_Token`** — Cloudflare API token s právem editovat DNS zóny `barina.tech`
  (Dashboard → My Profile → API Tokens → „Edit zone DNS").
- **`CF_Account_ID`** — ID Cloudflare účtu (Dashboard → doména `barina.tech` →
  Overview → sekce API vpravo dole).

### Spuštění lokálně (alternativa)
```bash
export CF_Token="…" CF_Account_ID="…" CF_Zone_ID="…" SOPS_AGE_KEY="…"
./ops/tls/renew-tls.sh
git add <změněné *.sops.yaml> && git commit -m "renew tls certs" && git push
```

---

## 8. Aplikace

### Linkding — `ldpi.barina.tech` (namespace `linkding`)
Bookmark manager (`sissbruecker/linkding`), 1 replika, data na PVC `linkding-data-pvc`.
Vystavený přes **Cloudflare Tunnel** (ne Traefik). Env z secretu `linkding-container-env`.

### CloudNativePG — `pg-cluster` (namespace `cnpg-cluster`)
Produkční PostgreSQL spravovaný operátorem **CloudNativePG** (operátor v `cnpg-system`).
- operátor je v GitOps: `controllers/cnpg-operator/` (vendorovaný oficiální manifest `cnpg-<verze>.yaml`)
  + Flux Kustomization `cnpg-operator` (`clusters/staging/cnpg-operator.yaml`); `apps` na něj má `dependsOn`,
  takže operátor a CRD existují dřív než `pg-cluster`. CRD a namespace `cnpg-system` mají
  `kustomize.toolkit.fluxcd.io/prune: disabled` a Kustomization má `deletionPolicy: Orphan`
  (odebrání z gitu nesmí smazat CRD → tím i `pg-cluster` a data),
- **upgrade operátoru:** stáhnout `https://github.com/cloudnative-pg/cloudnative-pg/releases/download/vX.Y.Z/cnpg-X.Y.Z.yaml`
  do `controllers/cnpg-operator/`, starý soubor smazat, upravit `resources:` v `kustomization.yaml`,
  ověřit `kubectl diff --server-side -f <(kubectl kustomize controllers/cnpg-operator)`, před tím záloha
  (CNPG Backup + Velero). Po změně verze operátor restartuje instance Postgresu (rolling update);
  neodstraňovat soubory z gitu ani `git revert` bez `flux suspend` (prune by smazal Deployment/RBAC operátoru),
- **2 instance** (primary + replika, asynchronní replikace), storage `synology-iscsi` 5Gi/instance (zvětšeno z 1Gi 2026-10-28; po zvětšení PVC je nutný restart podu pro resize FS: nejdřív replika, pak primary),
- `enableSuperuserAccess: true` (pro správu z pgAdminu),
- bootstrap databáze `app` (vlastník `app`, secret `cnpg-app-user`),
- PodMonitor zapnutý → metriky tečou do Prometheu,
- přímý přístup přes `pg-cluster-lb` LoadBalancer na portu 5432,
- alerty v `prometheus-rule.yaml`.

### Nextcloud — `office.barina.tech` (namespace `nextcloud`, nasazeno 2026-10-28)
Soubory, kalendář, kontakty. Oficiální Helm chart (`apps/base/nextcloud/release.yaml`, HelmRelease
`nextcloud`, chart **9.4.1**, image `nextcloud:35.0.2-apache`, obojí pinnuté), 1 replika (strategie Recreate),
cron jako sidecar (`/cron.sh`, každých 5 min), limit 2 CPU / 2Gi.
- **umístění:** `apps/base/nextcloud` (namespace, HelmRepository, HelmRelease, Redis) a `apps/staging/nextcloud`
  (overlay se SOPS secrety, registrovaný v `apps/staging/kustomization.yaml`),
- **databáze:** `pg-cluster` (CNPG), databáze `nextcloud` (CRD `Database` v `apps/base/cnpg-cluster/database-nextcloud.yaml`)
  a role `nextcloud` (`spec.managed.roles` v `cluster.yaml`). Heslo role: SOPS secret `nextcloud-db-user`
  (ns `cnpg-cluster`) + kopie `nextcloud-db` (ns `nextcloud`) — **musí mít stejné heslo**,
- **Redis:** `nextcloud-redis` (Deployment `redis:8.8-alpine`, bez persistence, s heslem v secretu `nextcloud-redis`),
- **úložiště:** PVC `nextcloud-nextcloud` 5Gi (html/config/apps) a `nextcloud-nextcloud-data` 50Gi (data), StorageClass
  `synology-iscsi`; obě se dají zvětšit změnou `persistence.size` / `nextcloudData.size` (po zvětšení restart podu).
  První mount 50Gi LUNu trvá několik minut (mkfs na NASu) — HelmRelease tím může skončit jako „install failed
  (stalled)"; stačí `flux reconcile helmrelease nextcloud -n nextcloud --force`,
- **admin:** uživatel `admin`, heslo v SOPS secretu `nextcloud-admin`; při nasazení uložené také do souboru
  `~/nextcloud-admin-password` na BladeAsus (po změně hesla v UI soubor smazat — secret se používá jen při instalaci),
- **přístup:** přes cloudflared (pravidlo `office.barina.tech → http://nextcloud.nextcloud.svc.cluster.local:80` v
  ConfigMapu v `apps/staging/linkding/cloudflare.yaml`; po změně ConfigMapu zvýšit anotaci `config-revision`
  v Deploymentu cloudflared, jinak se nenačte). DNS: proxied CNAME `office` → `<tunnel-id>.cfargotunnel.com`.
  TLS končí na Cloudflare, Nextcloud má `overwriteprotocol=https`, `trusted_proxies=10.42.0.0/16`,
  `forwarded_for_headers=HTTP_X_FORWARDED_FOR`. Cloudflare limit 100 MB / request → chunked upload 50 MiB.
  Cloudflare Access na hostname není (rozbil by mobilní/desktop klienty),
- **aktualizace:** zvýšit `chart.spec.version` a `image.tag` v `release.yaml` (Nextcloud povoluje jen postupné
  skoky po jedné major verzi!), před tím záloha (Velero `nextcloud-<datum>` + CNPG Backup). Aktualizace se při startu
  provede automaticky, krátký výpadek. HelmRelease nemá auto-remediation (retries 0) — při chybě zkontrolovat ručně,
- **zálohy:** namespace spadá pod Velero `cluster-daily` (`*`, FS backup obou PVC přes kopia) a DB pod CNPG
  `pg-cluster-daily`. Úvodní ruční zálohy: Velero `nextcloud-initial`, CNPG `pg-cluster-nextcloud-initial`.
  Obnova: Velero restore namespace `nextcloud` + CNPG restore DB (viz `ops/velero/DR-Runbook.md`),
- NAS je jediný disk bez redundance → jedinou další kopií dat jsou zálohy na iDrive e2.

### Forgejo — `git.barina.tech` (namespace `forgejo`, nasazeno 2026-10-28, jen LAN)
Self-hosted Git. Oficiální Helm chart (`apps/base/forgejo/release.yaml`, HelmRelease `forgejo`, OCI repo
`oci://code.forgejo.org/forgejo-helm`, chart **17.3.2**, image `forgejo:15.0.11-rootless` — obojí pinnuté), 1 replika
(Recreate), limit 1 CPU / 1Gi. Overlay se SOPS secrety: `apps/staging/forgejo`.
- **přístup:** jen z vnitřní sítě, **ne** přes Cloudflare tunnel. Ingress třídy `traefik` na `git.barina.tech`, TLS secret
  `forgejo-tls-secret`. DNS: Cloudflare záznam A `git.barina.tech` → `192.168.1.108`, DNS only (vnitřní IP jako u pgAdminu).
  Registrace jsou vypnuté (`DISABLE_REGISTRATION`), anonymní čtení také (`REQUIRE_SIGNIN_VIEW`), `OFFLINE_MODE=true`.
  Pokud by se mělo někdy otevřít ven, je nutný tunel + ochrana přihlášení (Cloudflare Access/2FA),
- **SSH pro git:** Service `forgejo-ssh` typu LoadBalancer na portu **2222** (port 22 používá sshd na uzlech):
  `git clone ssh://git@git.barina.tech:2222/<uživatel>/<repo>.git`. Pro pohodlí lze v `~/.ssh/config` nastavit `Port 2222`,
- **databáze:** `pg-cluster` (CNPG), DB `forgejo` (`database-forgejo.yaml`) a role `forgejo` (`managed.roles`), heslo ve
  SOPS secretu `forgejo-db-user` (ns `cnpg-cluster`) + kopie `forgejo-db` (ns `forgejo`) — **musí mít stejné heslo**. Bez Redisu
  (cache/session v paměti, fronta `level`),
- **úložiště:** PVC `gitea-shared-storage` 20Gi (`synology-iscsi`; první mount nové LUN trvá minuty). Zvětšení změnou
  `persistence.size`. Repozitáře se zálohují Velerem (kopia) jako kopie souborů za běhu; pro důležitá data lze doplnit `forgejo dump`,
- **admin:** uživatel `barinap`, heslo v SOPS secretu `forgejo-admin` (`passwordMode: initialOnlyNoReset` — používá se jen při
  prvním vytvoření účtu) a při nasazení také v souboru `~/forgejo-admin-password` na BladeAsus (mimo repo). Po změně hesla v UI soubor smazat,
- **TLS obnova:** `git.barina.tech` je v `ops/tls/renew-tls.sh` (a v `git add` workflow `renew-tls.yml`), certifikát se obnovuje
  každých 14 dní stejně jako pgadmin/grafana → `apps/staging/forgejo/forgejo-tls-secret.sops.yaml`. Lokální vydání: Cloudflare token má
  omezení na IP (domácí IP) — při zapnutém Mullvad VPN spouštět přes `mullvad-exclude`,
- **kontrola po upgradech:** `kubectl get helmrelease -n forgejo`, `curl https://git.barina.tech/api/healthz`; chart a image měnit
  společně (`chart.spec.version`, `image.tag`), před major verzí zálohovat (Velero `forgejo-<datum>` + CNPG Backup). HelmRelease
  nemá auto-remediation (retries 0),
- **zálohy:** ns `forgejo` spadá pod Velero `cluster-daily`, DB pod CNPG `pg-cluster-daily`. Úvodní ruční zálohy:
  Velero `forgejo-initial`, CNPG `pg-cluster-forgejo-initial`.

### pgAdmin — `pgadmin.barina.tech` (namespace `cnpg-cluster`)
Webová správa PostgreSQL. Deployment + PVC + service + ingress.
Přihlašovací údaje v secretu `pgadmin-secret`.

---

## 9. Monitoring

Nasazený **kube-prometheus-stack** (Helm chart `66.2.2`) přes Flux HelmRelease
v namespace `monitoring`. Zahrnuje Prometheus, Alertmanager, Grafanu a exportéry.

- **Storage:** Prometheus 10Gi, Alertmanager 5Gi — oba na `synology-iscsi`.
- **k3s úpravy:** scrape endpointy `kubeControllerManager`, `kubeScheduler`,
  `kubeProxy` a `kubeApiServer` jsou **vypnuté** — k3s je embeduje a nevystavuje
  je standardním způsobem (jinak by Prometheus hlásil falešné „target down").
- **Grafana:** `grafana.barina.tech`, persistence 5Gi na iSCSI, TLS přes
  `grafana-tls-secret` (Let's Encrypt, viz §7).
- **Alertmanager:** notifikace e-mailem (SMTP přes Office 365).
- **CNPG dashboard** v Grafaně je udržovaný **ručně** (ne GitOps) — edituje se
  přes Grafana API, není v repu.

---

## 10. Zálohy a Disaster Recovery

Dvě nezávislé vrstvy záloh, obě do **IDrive e2** (S3, bucket `pi-cluster-backup`,
endpoint `https://h1t7.fra203.idrivee2-84.com`):

### CNPG (logické zálohy PostgreSQL)
- **barman object store** přímo v definici clusteru (`apps/base/cnpg-cluster/cluster.yaml`),
  cesta `s3://pi-cluster-backup/cnpg`, WAL i data gzip, retence **30 dní**.
- **ScheduledBackup `pg-cluster-daily`** — denně ve 03:00 (cron `0 0 3 * * *`).
- Credentials v secretu `cnpg-backup-s3-credentials` (SOPS `apps/staging/cnpg-cluster/cnpg-backup-s3-credentials.sops.yaml`).
- Velero a CNPG mají od 21. 10. 2026 **oddělené** iDrive klíče (jen bucket `pi-cluster-backup`).

### Velero (zálohy namespace + PV)
- Zálohuje mj. `monitoring` a `linkding` (filesystem backup / kopia, AWS plugin).
- Denní schedule `monitoring-linkding-daily`.
- Credentials: secret `velero/cloud-credentials` (klíč `cloud`) je od 21. 10. 2026 v GitOps,
  SOPS soubor `apps/staging/velero/cloud-credentials.sops.yaml` (Kustomization `apps`).
  Namespace `velero` Flux nespravuje. Po změně: `kubectl -n velero rollout restart deploy/velero ds/node-agent`.
- Pomocné skripty: `ops/velero/backup-now.sh`, `list-backups.sh`, `restore-linkding-test.sh`.

### Disaster Recovery
Kompletní postup obnovy (totální ztráta clusteru i testovací restore do jiného
namespace) je v **`ops/velero/DR-Runbook.md`**. Hrubý postup při totální ztrátě:
1. Postavit nový k3s cluster.
2. `flux bootstrap git` proti tomuto repu (`clusters/staging`).
3. Obnovit Synology CSI secret a ověřit StorageClass.
4. Vytvořit namespace `velero` (hned po bootstrapu, jinak selže Kustomization `apps`) a přeinstalovat Velero s `--no-secret` proti existujícímu S3 bucketu (secret dodá Flux).
5. `velero restore` namespace `monitoring` + `linkding`.

---

## 11. Běžné operace

```bash
# stav GitOps
flux get kustomizations -A
flux get sources git -A
flux get helmreleases -A

# vynutit okamžitý reconcile (po pushnutí změny)
flux reconcile source git flux-system
flux reconcile kustomization apps
flux reconcile kustomization monitoring-configs --with-source

# náhled, co by Flux změnil, ještě před aplikací
flux diff kustomization apps --kustomization-file clusters/staging/apps.yaml

# ověřit, že overlay renderuje
kustomize build apps/staging

# stav clusteru
kubectl get nodes -o wide
kubectl get pods -A
kubectl get ingress -A
kubectl get pvc -A

# stav PostgreSQL clusteru
kubectl -n cnpg-cluster get cluster pg-cluster
kubectl cnpg status pg-cluster -n cnpg-cluster   # plugin cnpg

# ověřit živý TLS cert domény
echo | openssl s_client -connect grafana.barina.tech:443 \
  -servername grafana.barina.tech 2>/dev/null | openssl x509 -noout -issuer -dates
```

**Workflow pro změnu:** uprav manifest → `kustomize build <path>` (ověření) →
commit s konvenčním subjektem → push do `main` → (volitelně) `flux reconcile`.

---

## 12. Známé problémy a poučení

### iSCSI svazky padaly do read-only (vyřešeno)
Cluster dlouhodobě trpěl tím, že iSCSI svazky z NASu po I/O chybách remountovaly
ext4 jako **read-only** (postihovalo Prometheus, MinIO, PostgreSQL → ztráta dat
v Grafaně, pády DB). **Hlavní příčinou byla WiFi konektivita uzlů** — nestabilní
síť způsobovala výpadky iSCSI session. Po **přechodu uzlů na Ethernet (~2026-06-13)**
chronické read-only výpadky zmizely.

Postup ručního zotavení (když svazek přesto spadne do RO) je: scale-down postižené
aplikace → smazat pod → odpojit iSCSI session na uzlu → ověřit/opravit filesystem
(`fsck`) → znovu připojit → scale-up.

### TLS obnova a chybějící namespace (vyřešeno)
Obnovovací skript ze secretu odstraňuje pole `namespace:`. Funguje to jen proto,
že overlay `kustomization.yaml` má nastavené `namespace:`, které se vstříkne zpět.
Když se přidávala obnova pro Grafanu, `monitoring/configs/staging/kube-prometheus-stack/kustomization.yaml`
toto pole nemělo a Flux selhával chybou „namespace not specified". Oprava:
doplnit `namespace: monitoring` do té kustomizace. **Při přidávání další domény
do obnovy vždy ověř, že cílový overlay nastavuje namespace.**

### Odstranění aplikace Kan (2026-10-21)
Kanban aplikace Kan (`tasks.barina.tech`, `tasks-storage.barina.tech`, namespace `kan`,
vlastní Postgres + MinIO StatefulSet) se nepoužívala a byla odstraněna z repa i clusteru.
Důvodem byl i konec oficiálních MinIO community image na Docker Hubu. Flux prune smazal
namespace, PVC i iSCSI LUNy na NASu. Poslední data Kanu zůstávají jen v denních
Velero zálohách do jejich expirace (TTL 30 dní).

### k3s a Prometheus scrape targety
k3s embeduje controller-manager, scheduler, kube-proxy i apiserver a nevystavuje
je standardními scrape endpointy. Proto jsou v kube-prometheus-stack HelmRelease
vypnuté (`kubeControllerManager/Scheduler/Proxy/ApiServer: enabled: false`),
aby nevznikaly falešné alerty „target down".

---

## Reference

- `AGENTS.md` — konvence repa (YAML styl, commit guidelines, SOPS).
- `ops/velero/DR-Runbook.md` — kompletní DR postup.
