# Kan (tasks.barina.tech)

This folder contains the staging overlay for Kan and its Postgres database.
Secrets are stored only as SOPS-encrypted YAML. Regenerate secrets as needed and
never commit plaintext.

## Generate and encrypt secrets (macOS)

### 1) App secret (POSTGRES_PASSWORD + BETTER_AUTH_SECRET)
Create a temporary plaintext file, then encrypt it with SOPS+AGE:

```bash
POSTGRES_PASSWORD_B64=$(printf %s "<POSTGRES_PASSWORD>" | base64)
BETTER_AUTH_SECRET_B64=$(printf %s "<BETTER_AUTH_SECRET>" | base64)

cat <<KANS > /tmp/kan-secret.yaml
apiVersion: v1
data:
  POSTGRES_PASSWORD: ${POSTGRES_PASSWORD_B64}
  BETTER_AUTH_SECRET: ${BETTER_AUTH_SECRET_B64}
kind: Secret
metadata:
  name: kan-secret
KANS

sops --encrypt \
  --age age19fd7xlck0r3645chqjxq2m22qmtmatr4g0yghplsm33cn5yq7fuq69734h \
  --encrypted-regex '^(data|stringData)$' \
  /tmp/kan-secret.yaml > apps/staging/kan/kan-secret.sops.yaml

rm -f /tmp/kan-secret.yaml
```

### 2) MinIO root + Kan S3 access secrets
Generate MinIO root credentials and reuse them for Kan S3 access:

```bash
MINIO_ROOT_USER="<MINIO_ROOT_USER>"
MINIO_ROOT_PASSWORD="<MINIO_ROOT_PASSWORD>"

MINIO_ROOT_USER_B64=$(printf %s "${MINIO_ROOT_USER}" | base64)
MINIO_ROOT_PASSWORD_B64=$(printf %s "${MINIO_ROOT_PASSWORD}" | base64)

cat <<EOF > /tmp/minio-root-secret.yaml
apiVersion: v1
data:
  MINIO_ROOT_USER: ${MINIO_ROOT_USER_B64}
  MINIO_ROOT_PASSWORD: ${MINIO_ROOT_PASSWORD_B64}
kind: Secret
metadata:
  name: minio-root-secret
EOF

cat <<EOF > /tmp/kan-s3-secret.yaml
apiVersion: v1
data:
  S3_ACCESS_KEY_ID: ${MINIO_ROOT_USER_B64}
  S3_SECRET_ACCESS_KEY: ${MINIO_ROOT_PASSWORD_B64}
kind: Secret
metadata:
  name: kan-s3-secret
EOF

sops --encrypt \
  --age age19fd7xlck0r3645chqjxq2m22qmtmatr4g0yghplsm33cn5yq7fuq69734h \
  --encrypted-regex '^(data|stringData)$' \
  /tmp/minio-root-secret.yaml > apps/staging/kan/minio-root-secret.sops.yaml

sops --encrypt \
  --age age19fd7xlck0r3645chqjxq2m22qmtmatr4g0yghplsm33cn5yq7fuq69734h \
  --encrypted-regex '^(data|stringData)$' \
  /tmp/kan-s3-secret.yaml > apps/staging/kan/kan-s3-secret.sops.yaml

rm -f /tmp/minio-root-secret.yaml /tmp/kan-s3-secret.yaml
```

### 3) TLS secret for tasks.barina.tech
Create the secret from real cert/key files, then encrypt it:

```bash
kubectl create secret tls tasks-tls-secret \
  --cert /path/to/tasks.barina.tech.crt \
  --key /path/to/tasks.barina.tech.key \
  --namespace kan \
  --dry-run=client -o yaml > /tmp/tasks-tls-secret.yaml

sops --encrypt \
  --age age19fd7xlck0r3645chqjxq2m22qmtmatr4g0yghplsm33cn5yq7fuq69734h \
  --encrypted-regex '^(data|stringData)$' \
  /tmp/tasks-tls-secret.yaml > apps/staging/kan/tasks-tls-secret.sops.yaml

rm -f /tmp/tasks-tls-secret.yaml
```

### 4) TLS secret for tasks-storage.barina.tech
Create the secret from real cert/key files, then encrypt it:

```bash
kubectl create secret tls tasks-storage-tls-secret \
  --cert /path/to/tasks-storage.barina.tech.crt \
  --key /path/to/tasks-storage.barina.tech.key \
  --namespace kan \
  --dry-run=client -o yaml > /tmp/tasks-storage-tls-secret.yaml

sops --encrypt \
  --age age19fd7xlck0r3645chqjxq2m22qmtmatr4g0yghplsm33cn5yq7fuq69734h \
  --encrypted-regex '^(data|stringData)$' \
  /tmp/tasks-storage-tls-secret.yaml > apps/staging/kan/tasks-storage-tls-secret.sops.yaml

rm -f /tmp/tasks-storage-tls-secret.yaml
```

Note: If you use self-signed certs, import the CA/cert into your internal
clients to avoid browser warnings. The Kan deployment trusts
`tasks-storage-tls-secret` via `NODE_EXTRA_CA_CERTS`.

## Verify deployment

```bash
kubectl -n kan get pods
kubectl -n kan get svc
kubectl -n kan get ingress
kubectl -n kan logs deploy/kan
```

## Verify DB connectivity

```bash
kubectl -n kan exec -it postgres-0 -- psql -U kan -d kan_db -c "SELECT 1;"
```

## Verify storage (MinIO)

```bash
kubectl -n kan get pods -l app=minio
kubectl -n kan logs job/minio-buckets
```

## Verify ingress (internal network)

```bash
curl -I https://tasks.barina.tech
curl -I https://tasks-storage.barina.tech
```
