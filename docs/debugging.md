# Debugging a deployment

Troubleshooting the Openfire deployment on OpenShift/Kubernetes. Container-level
issues (image build, JVM) are in
[openfire-oci › debugging](https://gitlab.com/mkoese/openfire-oci/-/blob/main/docs/debugging.md).

## First look

```bash
oc get pods -n openfire
oc describe pod <pod> -n openfire            # events: scheduling, mounts, probes
oc get events -n openfire --sort-by=.lastTimestamp | tail -20
```

## Logs — main and init container

The pod has an **init container** (`init-conf`) that seeds config, keystores, and
injects secrets. Setup problems usually show there, not in the main container:

```bash
oc logs deployment/<release>-openfire -n openfire -c init-conf   # seeding, keystore, injects
oc logs -f deployment/<release>-openfire -n openfire             # Openfire runtime (stdout)
oc logs deployment/<release>-openfire -n openfire --previous     # after a crash
```

## Common failures

| Symptom | Where to look | Likely cause / fix |
|---------|---------------|--------------------|
| Pod `Pending` | `describe pod` events | PVC unbound (no storage class) or anti-scheduling; check `persistence.storageClassName` |
| Init container `Error`/`CrashLoop` | `logs -c init-conf` | missing referenced secret (`database.existingSecret`, `auth.ldap.existingSecret`, `adminPasswordSecret`, `kerberos.keytabSecret`); create it or unset the value |
| Main container `CrashLoopBackOff` | `logs --previous` | DB unreachable, bad JDBC URL, or a schema error — check `database.host`/NetworkPolicy egress |
| Startup probe never succeeds | `describe pod` | admin console slow to come up; raise the startup probe `failureThreshold` in `templates/deployment.yaml` (not a values key) |
| `readOnlyRootFilesystem` → write errors | main logs | a write path isn't a mounted volume; disable `security.readOnlyRootFilesystem` and report the path |
| Auth: everyone rejected | main logs (enable auth debug) | LDAP unreachable (fail-closed), wrong `baseDN`/`usernameField`, or bad service-account bind |
| Kerberos/GSSAPI fails | main logs (`sasl.gssapi.debug`) | SPN ≠ `xmpp/<fqdn>@REALM`, keytab enctype mismatch, clock skew > 5 min |
| DB password won't decrypt after restore | main logs | conf PVC (encryption key) doesn't match the DB — see [data-lifecycle.md](data-lifecycle.md) |

## Enable auth / SASL debug logging

Set on the running server (admin console → *System Properties*, or seed via conf):

```
log.debug.enabled = true
```

For Kerberos, set `sasl.gssapi.debug = true` (chart: `kerberos` block renders the
JAAS config; the JVM gets `-Djava.security.krb5.conf` automatically). See
[openfire-authprovider › debugging](https://gitlab.com/mkoese/openfire-authprovider/-/blob/main/docs/debugging.md)
for interpreting auth-provider behavior.

To raise the level of a specific category (e.g. `com.mkoese.openfire.auth` to
`trace`, or the LDAP/SASL classes) without a restart, edit or mount the image's
`log4j2.xml` — see [openfire-oci › logging](https://gitlab.com/mkoese/openfire-oci/-/blob/main/docs/logging.md).

## Inspect what actually got rendered/mounted

```bash
oc get secret <release>-openfire-conf -n openfire -o jsonpath='{.data.openfire\.xml}' | base64 -d
oc get cm <release>-openfire-init -n openfire -o yaml            # the init.sh
oc exec deployment/<release>-openfire -n openfire -- \
  sh -c 'ls -l /opt/openfire/conf /opt/openfire/resources/security'
oc exec deployment/<release>-openfire -n openfire -- \
  cat /opt/openfire/conf/openfire.xml                            # post-inject, post-setup
```

## Probe / networking checks

```bash
oc exec deployment/<release>-openfire -n openfire -- curl -sf http://localhost:9090/login.jsp
oc get networkpolicy -n openfire                                 # egress to DB/LDAP/KDC allowed?
oc exec deployment/<release>-openfire -n openfire -- \
  bash -c 'timeout 3 bash -c "</dev/tcp/<db-host>/5432" && echo open'  # DB reachability (no nc in the image)
```

## Data / reset

Backup, restore, migrate, or fully reset the database and conf PVC:
[data-lifecycle.md](data-lifecycle.md).
