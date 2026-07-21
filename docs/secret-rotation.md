# Secret rotation

What each secret feeds, **when it is actually read**, and how to rotate it.
The one rule to internalize: DB/LDAP/admin credentials are injected **on first
boot only** (the init container seeds the conf PVC once) — updating the
Kubernetes secret alone does **not** change a running install. Still always
keep the secret in sync: a future re-seed (conf-PVC delete) uses it.

| Secret | Read | Rotate by |
|--------|------|-----------|
| `tls.secretName` (server cert) | every pod start | update secret → restart ([tls.md](tls.md#rotation)) |
| `tls.extraKeypairs[].secretName` | every pod start | update secret → restart |
| `tls.trustedCAConfigMap` | every pod start | update ConfigMap → restart |
| `tls.keystorePasswordSecret` | every pod start | update secret → restart (stores self-heal, see below) |
| `kerberos.keytabSecret` | on each GSSAPI auth (mounted file) | replace secret → restart |
| `adminPasswordSecret` | **first boot only** (autosetup) | admin console + update secret |
| `auth.ldap.existingSecret` | **first boot only** | AD + admin console + update secret |
| `database.existingSecret` | **first boot only** | PostgreSQL + persisted conf + update secret |

## Keystore password

Update the secret, restart. The init container self-heals: a keystore/truststore
that no longer opens with the current password is **regenerated/rebuilt**, and
the chart syncs `keypass`/`trustpass` in the persisted `openfire.xml` on every
start — no manual step. Two caveats:

- The rebuilt truststore contains **only** stock CAs + `trustedCAConfigMap`
  re-imports; CAs imported manually (admin console / keytool) survive only in
  the automatic `truststore.bak` — re-import them declaratively.
- Bring-your-own conf (`conf.existingSecret`) must update its own
  `keypass`/`trustpass` ([tls.md](tls.md#custom-keystore-password)).

## Admin password

Autosetup used it once; afterwards the DB hash is authoritative:

1. Change it in the **admin console** (*Users/Groups → admin → Password*).
2. Update the secret so a future re-seed matches:
   ```bash
   oc create secret generic openfire-admin --from-literal=password=<new> \
     -n openfire --dry-run=client -o yaml | oc apply -f -
   ```

## LDAP service account

`ldap.adminPassword` migrated into an **encrypted DB system property** at setup:

1. Rotate the service-account password in **Active Directory**.
2. Admin console → *Server Manager → System Properties* → edit
   `ldap.adminPassword` (stored encrypted).
3. Update `auth.ldap.existingSecret` (same `oc create … | oc apply` pattern).

## Database password

`database.*` is XML-reserved — it lives **only** in the persisted
`openfire.xml` on the conf PVC (encrypted). Openfire may rewrite that file at
shutdown, so edit it with the deployment **scaled down**:

```bash
# 1. New password in PostgreSQL
#      ALTER USER openfire WITH PASSWORD '<new>';
# 2. Update the k8s secret (oc create … | oc apply, as above)
# 3. Edit the persisted conf via the helper pod
#    (pod manifest: data-lifecycle.md § Restore)
oc scale deployment/<release>-openfire -n openfire --replicas=0
oc apply -n openfire -f pvc-helper.yaml && oc wait pod/pvc-helper -n openfire --for=condition=Ready
oc exec pvc-helper -n openfire -- sed -i \
  's|<password encrypted="true">[^<]*</password>|<password><new></password>|' \
  /pvc/conf/openfire.xml
oc delete pod pvc-helper -n openfire
oc scale deployment/<release>-openfire -n openfire --replicas=1
```

Openfire re-encrypts the plaintext value on the next boot.
