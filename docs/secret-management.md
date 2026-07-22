# Secret management

All secrets are created **before the first deploy**, **per namespace** — the
chart references them by name and never renders a credential into YAML/git.
Dev needs **none** (embedded defaults); preprod needs the first four; prod
needs all five (six with Kerberos).

| Secret | Key | Contains | dev | preprod | prod |
|---|---|---|---|---|---|
| `openfire-db` | `password` | PostgreSQL user password | – | ✅ | ✅ |
| `openfire-ldap` | `password` | AD service account (`svc-openfire`) | – | ✅ | ✅ |
| `openfire-admin` | `password` | admin console password — **must satisfy the password policy** (12+ chars, 3 classes) or autosetup cannot set it | – | ✅ | ✅ |
| `openfire-tls` | `tls.crt` / `tls.key` | the real certificate for the env FQDN ([tls.md](tls.md)) | – | ✅ | ✅ |
| `openfire-keystore-password` | `password` | keystore password (auto-wired into `keypass`/`trustpass`) | – | – | ✅ |
| `openfire-keytab` | `openfire.keytab` | Kerberos SPN keytab — only with `kerberos.enabled` | – | – | (opt) |

## Create (prod shown — repeat with `-n openfire-preprod`)

```bash
oc create secret generic openfire-db       --from-literal=password='<db-pw>'         -n openfire-prod
oc create secret generic openfire-ldap     --from-literal=password='<svc-acct-pw>'   -n openfire-prod
oc create secret generic openfire-admin    --from-literal=password='<Strong-Pw-12+>' -n openfire-prod
oc create secret tls     openfire-tls      --cert=chat.crt --key=chat.key            -n openfire-prod
oc create secret generic openfire-keystore-password --from-literal=password='<ks-pw>' -n openfire-prod
# Kerberos SSO only:
# oc create secret generic openfire-keytab --from-file=openfire.keytab=<path>        -n openfire-prod
```

## Good to know

- The chart's **fail-guards** catch missing *references* at render time — but
  they cannot see the cluster: a referenced but **uncreated** secret shows up
  as the init container erroring (first row of the
  [debugging table](debugging.md#common-failures)).
- Rotating any of these: [secret-rotation.md](secret-rotation.md) — what is
  read when, and the runbook per credential.
- Shell history: prefer `--from-file` or `read -s` over pasting passwords
  into `--from-literal` on shared machines ([admin-basics.md](admin-basics.md)).
