# Kan (tasks.barina.tech)

This folder contains the staging overlay for Kan and its Postgres database.
Secrets are stored only as SOPS-encrypted YAML. The committed secrets contain
placeholder values and must be regenerated before applying to a real cluster.

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

### 2) TLS secret for tasks.barina.tech
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

## Verify ingress (internal network)

```bash
curl -I https://tasks.barina.tech
```
