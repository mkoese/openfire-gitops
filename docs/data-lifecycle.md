# Data, backup & database lifecycle

Where Openfire keeps state in this deployment, what a "new database" actually
costs you, and how to back up / migrate / reset cleanly.

> **One rule to remember:** the **conf PVC and the PostgreSQL database are a
> matched pair.** The encryption key that protects secrets in the database lives
> on the conf PVC. Reset both together, or neither — never one without the other.

## Where state lives

| Location | Contents | Survives pod/node loss? |
|----------|----------|-------------------------|
| **PostgreSQL** (external) | Almost all mutable runtime state — see [What's in the database](#whats-in-the-database) | ✅ external, independent of the pod |
| **conf PVC** (`<release>-openfire-conf`) | `openfire.xml`, `security.xml` (the **property-encryption key**), keystore + truststore (`resources/security`) | ✅ PVC |
| **plugins PVC** (`<release>-openfire-plugins`) | Plugin JARs (seeded from the image on first boot) | ✅ PVC |
| **Image + conf Secret** | Defaults, baked-in plugins/JARs, and the *seed* `openfire.xml`/`security.xml` | ✅ rebuilt / re-seeded |

The conf PVC and the database `security.xml`/`ofProperty` split matters: the
**encryption key** is on the PVC, the **encrypted values** (DB password, LDAP
service-account password, and any property marked encrypted) are rows in the
database. Neither is useful without the other.

## What's in the database

Openfire stores nearly all mutable data in PostgreSQL (tables prefixed `of…`):

| Category | Tables (representative) | What you lose if it's gone |
|----------|-------------------------|-----------------------------|
| **Accounts & auth** | `ofUser`, `ofUserProp` | usernames + **SCRAM password hashes** (salt/storedKey/serverKey) |
| **Contacts & presence** | `ofRoster`, `ofRosterGroups` | every user's contact list |
| **Groups** | `ofGroup`, `ofGroupUser`, `ofGroupProp` | shared groups & memberships |
| **Offline messages** | `ofOffline` | messages queued for offline users |
| **Profiles / storage** | `ofVCard`, `ofPrivate` | vCards, private XML, bookmarks |
| **Group chat (MUC)** | `ofMucRoom`, `ofMucMember`, `ofMucAffiliation`, `ofMucConversationLog` | persistent rooms + **room history** |
| **PubSub / PEP** | `ofPubsubNode`, `ofPubsubItem`, `ofPubsubSubscription` | pub/sub nodes, items, subscriptions |
| **System properties** | `ofProperty` | **all settings seeded at setup + everything changed later in the admin console**, including the *encrypted* DB/LDAP passwords |
| **Audit** | `ofSecurityAuditLog` | admin audit trail |
| **Federation / components** | `ofRemoteServerConf`, `ofExtComponentConf` | S2S allow/block lists, component secrets |
| **Archive (Monitoring plugin)** | `ofMessageArchive`, `ofConParticipant` | MAM / message archive |

**Not** in the database: the property-encryption *key* (`security.xml`, conf
PVC), the TLS key/trust stores (conf PVC), and the connection settings
themselves (`openfire.xml`, conf PVC).

Schema reference: [Openfire Database guide](https://download.igniterealtime.org/openfire/docs/latest/documentation/database-guide.html).

## Database lifecycle

1. **First boot against an empty database** — Openfire's `SchemaManager` creates
   the full schema automatically (runs `openfire_postgresql.sql`); autosetup then
   creates the admin account and seeds `ofProperty` from `openfire.xml`. No manual
   schema load is required ([Database Installation guide](https://download.igniterealtime.org/openfire/docs/latest/documentation/database.html)).
2. **Version upgrade** (e.g. 5.0 → 5.1) — `SchemaManager` auto-applies the
   migration scripts on first boot of the new image; expect a one-time upgrade
   line in the startup logs. Fresh databases are created at the new version
   directly.
3. **Steady state** — the database is external, so it outlives any pod or node.
   OpenShift reschedules the pod; the data is untouched.

## "I want to use a new database" — what's lost

⚠️ **Pointing at a new *empty* database is starting over.** Everything in
[What's in the database](#whats-in-the-database) is gone: local password hashes,
rosters, groups, offline messages, MUC rooms + history, PubSub data, vCards,
private storage, the audit log, and all runtime-set system properties.

### The conf-PVC gotcha

After first setup, autosetup rewrites `openfire.xml` on the conf PVC to
`<setup>true</setup>` and removes the autosetup block. So:

- **New DB + keep the old conf PVC** → the schema is created, but autosetup does
  **not** re-run → **no admin account and no seeded `ofProperty`** → you are
  locked out of the console. A broken half-state.
- **New DB + also delete the conf PVC** → the init container re-seeds
  `openfire.xml` from the conf Secret (the autosetup version) → clean fresh
  setup: new admin, re-seeded auth/LDAP/SASL config, and a **brand-new encryption
  key**. This is the correct "start fresh" path.

### What comes back automatically (AD-gated auth)

Because config is re-seeded from the conf Secret, the auth / LDAP / Kerberos /
SASL / password-policy settings return on their own. And since Active Directory
is the directory of record for *existence*, **user accounts are JIT-recreated on
next login** — but each user re-bootstraps their DB password via AD bind again.
Permanently gone: any DB password that had diverged from AD, plus all rosters,
offline messages, local group memberships, and MUC history.

## Back up

Two independent things to capture — back them up **together** so they stay
consistent:

```bash
# 1. Database
pg_dump -Fc -h <db-host> -U openfire openfire > openfire-$(date +%F).dump

# 2. Conf PVC -- BOTH subdirectories:
#    conf/     = openfire.xml + security.xml (the property-encryption key;
#                without a matching key, encrypted values in the DB dump are
#                unreadable)
#    security/ = keystore + truststore
oc rsync <openfire-pod>:/opt/openfire/conf ./pvc-backup -n openfire
oc rsync <openfire-pod>:/opt/openfire/resources/security ./pvc-backup -n openfire
```

## Restore

Restore the DB dump and the conf PVC **together** — they are a matched pair.

```bash
# 1. Database
pg_restore -c -h <db-host> -U openfire -d openfire openfire-<date>.dump

# 2. Conf PVC -- write through a helper pod while the deployment is down
oc scale deployment/<release>-openfire -n openfire --replicas=0
oc apply -n openfire -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: pvc-helper
spec:
  containers:
    - name: shell
      image: registry.access.redhat.com/ubi9/ubi-minimal:9.8
      command: ["sleep", "infinity"]
      securityContext:
        allowPrivilegeEscalation: false
        capabilities:
          drop: ["ALL"]
      volumeMounts:
        - name: pvc
          mountPath: /pvc
  volumes:
    - name: pvc
      persistentVolumeClaim:
        claimName: <release>-openfire-conf
EOF
oc wait pod/pvc-helper -n openfire --for=condition=Ready
oc rsync ./pvc-backup/conf/ pvc-helper:/pvc/conf/ -n openfire
oc rsync ./pvc-backup/security/ pvc-helper:/pvc/security/ -n openfire
oc delete pod pvc-helper -n openfire

oc scale deployment/<release>-openfire -n openfire --replicas=1
```

The same helper pod is used for the DB-password rotation procedure
([secret-rotation.md](secret-rotation.md#database-password)).

## Migrate to another PostgreSQL (keep all data)

Do **not** point at an empty database — dump and restore:

```bash
pg_dump -Fc -h old-host -U openfire openfire > openfire.dump
pg_restore -h new-host -U openfire -d openfire openfire.dump
```

Then update `database.host` to the new host and **keep the same conf PVC** — the
encryption key in `security.xml` must match the encrypted values in the restored
`ofProperty`, or the DB/LDAP passwords become undecryptable.

## Reset to a clean slate

To wipe and re-provision from scratch:

```bash
oc scale deployment/<release>-openfire -n openfire --replicas=0
# drop & recreate the database (or point database.host at a fresh empty one)
oc delete pvc <release>-openfire-conf -n openfire     # discards encryption key + keystores
oc scale deployment/<release>-openfire -n openfire --replicas=1
```

On the next boot the init container re-seeds config from the Secret and autosetup
runs against the empty database — a brand-new install.
