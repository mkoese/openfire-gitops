# Openfire GitOps

Deployment assets for Openfire XMPP server: Helm chart (OpenShift/Kubernetes).

Part of a 3-repo setup:

| Repo | Purpose |
|------|---------|
| [openfire-oci](https://gitlab.com/mkoese/openfire-oci) | Base container image + plugin/lib pins (`plugins.txt`, `lib.txt`) |
| **openfire-gitops** | This repo — deployment |
| [openfire-authprovider](https://gitlab.com/mkoese/openfire-authprovider) | AD-gated AuthProvider (baked into the image via `lib.txt`) |

## Layout

```
charts/openfire        # Helm chart: Deployment, Services, Routes, NetworkPolicy, PVCs, conf secret
envs/                  # Per-environment values overlays (dev / preprod / prod)
docs/                  # Operational guides
```

| Doc | What |
|-----|------|
| [docs/architecture.md](docs/architecture.md) | **Start here** — the 3 repos, AD/Postgres/Kerberos, and the auth flow (with diagrams) |
| [docs/data-lifecycle.md](docs/data-lifecycle.md) | Where state lives, what's in the database, backup / restore / migrate, what a "new database" costs |
| [docs/tls.md](docs/tls.md) | Ordering certificates (which names, where route URLs come from), keystores, rotation, cert-manager |
| [docs/secret-rotation.md](docs/secret-rotation.md) | Rotating every secret: what is read when, and the runbook per credential |
| [docs/upgrading.md](docs/upgrading.md) | Bump Openfire / base images across the repos; release & versioning; rollback |
| [docs/monitoring.md](docs/monitoring.md) | Prometheus (jmx_exporter) & Zabbix; what's scrapeable; health endpoints |
| [docs/airgapped-setup.md](docs/airgapped-setup.md) | Deploying with no internet |
| [docs/local-dev.md](docs/local-dev.md) | Lint / render matrix / dev-cluster apply — mostly no cluster needed |
| [docs/debugging.md](docs/debugging.md) | Pod/init logs, common failures, auth & Kerberos troubleshooting |
| [docs/admin-basics.md](docs/admin-basics.md) | Admin cheatsheet (Windows/Linux): checksums, PostgreSQL, LDAP/AD, TLS inspection, Kerberos, secrets gotchas |
| [docs/go-live-checklist.md](docs/go-live-checklist.md) | One-time acceptance tests before going live (DNS → TLS → logins → backup) |
| [docs/scaling.md](docs/scaling.md) | 100k users / ~30k concurrent on one node: sizing math, the ceiling, Tsung test |

## Quick start (dev: embedded DB, default auth)

```bash
helm template openfire ./charts/openfire \
  -f ./charts/openfire/values-openshift.yaml | oc apply -f -
```

Admin console: `admin` / `admin` (dev only!).

**Pulling from an external registry** (e.g. Quay.io) — create and link a pull secret:

```bash
oc create secret docker-registry openfire-pull-secret \
  --docker-server=quay.io \
  --docker-username=<user> \
  --docker-password=<token> \
  -n openfire
oc secrets link openfire-openfire openfire-pull-secret --for=pull -n openfire
```

## Multiple environments on one cluster (dev / preprod / prod)

One chart, **one namespace per environment**, one small overlay per
environment in [`envs/`](envs/):

```bash
helm template dev     charts/openfire \
  -f charts/openfire/values-openshift.yaml -f envs/dev.yaml | oc apply -f -
helm template preprod charts/openfire \
  -f charts/openfire/values-openshift.yaml -f envs/preprod.yaml \
  -f envs/sizes/30k.yaml | oc apply -f -
helm template prod    charts/openfire \
  -f charts/openfire/values-openshift.yaml -f envs/prod.yaml \
  -f envs/sizes/30k.yaml | oc apply -f -
```

Environment files carry **identity** (namespace, FQDN, secrets, routes);
capacity comes from a **size tier** in [`envs/sizes/`](envs/sizes/) —
2k / 5k / 10k / 20k / 30k concurrent sessions, one file each
([docs/scaling.md](docs/scaling.md) has the table and the math). Preprod runs
the same tier as prod so load tests are representative.

Namespaces are the isolation boundary, so everything falls into place by
itself:

- **No collisions** — every resource is namespaced and the generated route
  hosts include the namespace, so they are unique per environment.
- **NetworkPolicy isolation** — the "same namespace" ingress rules mean dev
  pods cannot reach preprod, without any extra configuration.
- **Secrets are per namespace** — create `openfire-db` / `openfire-ldap` /
  `openfire-admin` / `openfire-tls` in *each* environment's namespace (the
  overlays list the exact commands).
- **Per-env identity** — each environment has its own `xmpp.fqdn`
  (`chat-dev.…`, `chat-preprod.…`, `chat.…`), which means its own certificate
  and, for Kerberos, its **own SPN + keytab** (the SPN embeds the fqdn).
- **Per-env image tags** — dev can track a CI rebuild tag
  (`5.1.1-<build>`), prod pins the release tag; that's the promotion flow.
- **Spread across nodes** — built-in pod anti-affinity on the shared app label
  (all namespaces): the scheduler always tries a node without a running
  openfire first, so the environments land on different nodes.

Use a **distinct release name per environment** (`dev`, `preprod`, `prod`, as
above): it becomes the `app.kubernetes.io/instance` label and the resource-name
prefix, so environments stay distinguishable in any cross-namespace tooling
(monitoring, label selectors) and can never alias each other. Resources are
named `<release>-openfire` — e.g. `deployment/prod-openfire -n openfire-prod`
(the operations table below shows the single-instance quick-start name
`openfire-openfire`; substitute your release name). Pick the names **before**
go-live: changing a release name later renames the PVCs and orphans the data.

## Production configuration

### External PostgreSQL

```bash
oc create secret generic openfire-db --from-literal=password=<db-password> -n openfire
```

```yaml
database:
  host: postgres.db.svc.cluster.local
  port: 5432
  name: openfire
  user: openfire
  existingSecret: openfire-db
```

The PostgreSQL JDBC driver is baked into the image (`lib.txt` in openfire-oci). The embedded-db PVC is not created. The password is injected on first boot and encrypted by Openfire inside the persisted `openfire.xml` (AES, see `security.xml` encrypt list).

The **schema is created automatically** on first boot against an empty database — Openfire's setup runs `openfire_postgresql.sql` itself, no manual pre-load needed ([Database Installation guide](https://download.igniterealtime.org/openfire/docs/latest/documentation/database.html)).

### AD-gated authentication (SCRAM-SHA-1 + PLAIN + local admin)

```bash
oc create secret generic openfire-ldap --from-literal=password=<service-account-password> -n openfire
```

```yaml
adminPassword: <strong password>   # must satisfy the policy below!
auth:
  enabled: true
  ldap:
    host: dc1.example.com
    port: 636
    sslEnabled: true
    baseDN: OU=Users,DC=example,DC=com
    adminDN: CN=svc-openfire,OU=Service,DC=example,DC=com
    existingSecret: openfire-ldap
    usernameField: sAMAccountName
    nameField: displayName    # -> user Name (Spark contact name), refreshed on login
    emailField: mail          # -> user Email
  localOnlyUsers: admin
  password:
    minLength: 12
    minClasses: 3
    rejectUsername: true
```

**Offboarding & group gating:** the default `auth.ldap.searchFilter` excludes
**disabled** AD accounts — without that clause a disabled user keeps logging in
with their stored hash forever (the DB is authoritative after enrollment). To
also require a group membership, extend the filter with a `memberOf` clause
(see the comment in `values.yaml`).

**Login semantics** (see [openfire-authprovider](https://gitlab.com/mkoese/openfire-authprovider)):

- PLAIN first login: user must exist in AD; password is verified via **AD bind**, then stored as a **SCRAM hash in the DB** — the DB password is authoritative from then on (users may change it; it can diverge from AD).
- SCRAM-SHA-1 works from the **second** login on (enrollment needs PLAIN or GSSAPI once).
- `admin` never touches AD (local console fallback).
- Only SCRAM hashes are stored (`user.scramHashedPasswordOnly=true`), no recoverable passwords.

The `auth.ldap.*` values map to Openfire's standard `ldap.*` properties — see the official [LDAP guide](https://download.igniterealtime.org/openfire/docs/latest/documentation/ldap-guide.html). The `admin`-bypass design follows [Separating Administrative Users](https://download.igniterealtime.org/openfire/docs/latest/documentation/separating-admin-users-guide.html).

### Kerberos SSO (GSSAPI against Active Directory)

Create the service account + SPN + keytab on AD (the SPN host **must** equal `xmpp.fqdn`):

```powershell
ktpass -princ xmpp/chat.example.com@EXAMPLE.COM -mapuser EXAMPLE\svc-openfire `
  -crypto AES256-SHA1 -ptype KRB5_NT_PRINCIPAL -pass <password> -out openfire.keytab
```

```bash
oc create secret generic openfire-keytab --from-file=openfire.keytab=openfire.keytab -n openfire
```

```yaml
xmpp:
  domain: chat.example.com
  fqdn: chat.example.com
kerberos:
  enabled: true
  realm: EXAMPLE.COM
  kdc: dc1.example.com
  keytabSecret: openfire-keytab
```

This mounts `krb5.conf` + JAAS `gss.conf` + keytab at `/opt/openfire/kerberos`, adds GSSAPI to `sasl.mechs`, and registers the AD-gated authorization policy (JIT-creates accounts for Kerberos principals; such users must set a DB password before PLAIN works).

### TLS

```yaml
tls:
  # cert-manager / CA-issued certificate for the service (rebuilt every start)
  secretName: openfire-tls
  # custom keystore password (also requires keypass/trustpass in openfire.xml)
  keystorePasswordSecret: openfire-keystore-password
  # additional private/public keypairs imported into the app JKS
  extraKeypairs:
    - secretName: xmpp-federation-keypair
      alias: federation
  # extra CAs into the truststore
  trustedCAConfigMap: config-trusted-cabundle
```

Extra keypair secrets must contain `tls.crt` / `tls.key` (PEM). They are re-imported (delete + import per alias) on every pod start, so rotations apply on restart.

### Bring your own config

Set `conf.existingSecret` to bypass all conf templating:

```bash
oc create secret generic my-openfire-conf \
  --from-file=openfire.xml=openfire.xml \
  --from-file=security.xml=security.xml -n openfire
```

> The conf PVC persists `openfire.xml`/`security.xml` (incl. the generated
> property-encryption key) and the key/trust stores. Config from the secret is
> seeded on **first boot only** — delete the conf PVC to re-seed.

## Security

**Baseline (always on):** runs as an arbitrary non-root UID in GID 0
(OpenShift `restricted-v2` SCC), `seccompProfile: RuntimeDefault`, all
capabilities dropped, `allowPrivilegeEscalation: false`, no service-account
token mounted, and a default-deny-ish NetworkPolicy (same-namespace + router
ingress only). Credentials (DB, LDAP, admin) are injected from Kubernetes
secrets by the init container, never rendered into the conf Secret's YAML.

**Production checklist:**

| Setting | Why |
|---------|-----|
| `adminPasswordSecret: openfire-admin` | keeps the admin password out of `helm template`/git/etcd (the `adminPassword` value is a dev-only fallback) |
| `database.existingSecret`, `auth.ldap.existingSecret` | same, for DB and LDAP service-account passwords |
| `tls.keystorePasswordSecret` | the self-signed keystore otherwise uses `changeit`; set a real password (and the matching `keypass`/`trustpass` in your conf) |
| `security.readOnlyRootFilesystem: true` | opt-in; all writes go to mounted volumes, so enable it after a smoke test in your cluster |
| Kerberos keytab | mounted `0440` (pod UID + GID 0 only), never world-readable |

**Environment-specific hardening (not defaulted — set per cluster):**

- **Routes.** `route-edge.yaml` terminates TLS at the router, so the router→pod
  hop crosses the SDN in cleartext. For sensitive consoles prefer the
  `*Ssl` **passthrough** routes (`routes.adminSsl` / `routes.boshSsl` → 9091/7443)
  or configure a `reencrypt` route with the pod's CA.
- **NetworkPolicy ingress** for external XMPP clients: enabling the
  LoadBalancer opens the client ports (5222/5223) to `0.0.0.0/0` unless you
  scope `networkPolicy.clientCIDRs` — set it in production. Inbound S2S
  federation is closed until you set `networkPolicy.s2sCIDRs`.
- **NetworkPolicy egress** is port-restricted but not destination-restricted
  (no CIDRs are assumed). Scope the DB/LDAP/KDC egress rules to your directory
  and database CIDRs; the HTTP(S) egress can be dropped entirely (update checks
  and plugin downloads are disabled — plugins are baked into the image).
- **Self-signed cert** is RSA-2048/SHA-256; switch the init `keytool -genkeypair`
  to EC P-384 if your policy requires it.

## Build & validate

Three modes, mirroring the sibling repos ([openfire-oci › build](https://gitlab.com/mkoese/openfire-oci/-/blob/main/docs/build.md), [openfire-authprovider](https://gitlab.com/mkoese/openfire-authprovider#build)).

### 1. Local

Render and lint the charts with Helm before applying (no cluster needed):

```bash
helm lint charts/openfire
helm template openfire charts/openfire -f charts/openfire/values-openshift.yaml   # inspect output
```

### 2. GitLab CI (with internet)

`.gitlab-ci.yml` runs `helm lint` + a `helm template` matrix (embedded/external DB,
AD auth, Kerberos, TLS + extra keypairs, bring-your-own conf secret) on every
push/MR — catching template regressions before they reach a cluster.

The **image itself** is built and pushed by the openfire-oci CI
(GitLab pipeline / GitHub workflow) — see
[openfire-oci](https://gitlab.com/mkoese/openfire-oci); this repo only deploys it.

### 3. Airgapped GitLab (self-hosted, no internet)

The cluster has no internet; mirror the published image into the internal
registry and deploy from there — see [docs/airgapped-setup.md](docs/airgapped-setup.md).

The chart pulls no images at render time, so `helm template | oc apply` needs no
internet — only the deployed image reference (`image.repository`) must resolve
inside the cluster.

## Availability & scaling

**This chart runs a single active node** (`replicas: 1`, `Recreate`). That is a
deliberate default, not a limitation of reach:

- **Durable state lives outside the pod** — external PostgreSQL holds all data;
  the conf PVC persists `openfire.xml`/`security.xml` (incl. the property
  encryption key). A pod or node loss loses no data.
- **OpenShift reschedules** the pod on node failure; the startup/liveness probes
  make recovery fast. **XMPP clients reconnect automatically** by design, so a
  restart is a short blip, not an outage.
- A single well-tuned Openfire node scales to tens of thousands of concurrent
  sessions ([Scalability paper](https://www.igniterealtime.org/about/OpenfireScalability.pdf)).

For most deployments this is the right trade-off: no data SPOF, orchestrator
failover, and none of the operational cost of a live cluster.

### Scaling beyond one node (clustering)

Only needed if you genuinely exceed single-node capacity **or** require
zero-session-loss failover. Openfire clusters via the **Hazelcast plugin**
([db-clustering guide](https://download.igniterealtime.org/openfire/docs/latest/documentation/db-clustering-guide.html),
[Hazelcast plugin readme](https://www.igniterealtime.org/projects/openfire/plugins/2.4.2/hazelcast/readme.html)).
This is a scoped, separate project — **not wired in this chart** — requiring:

1. **Hazelcast plugin** on every node, identical version — add to
   `plugins.txt` (openfire-oci). Embedded DB cannot cluster; external
   PostgreSQL (already supported here) is mandatory and shared by all nodes.
2. **`replicaCount > 1` and drop `Recreate`** (rolling updates once clustered).
3. **Per-node conf/security storage.** The current shared **RWO** conf PVC is
   the blocker — each node needs its own `openfire.xml`/`security.xml` and its
   own encryption key. Move to a **StatefulSet** with per-replica volumes.
4. **Hazelcast networking:** expose inter-node port **5701** via a headless
   Service + a NetworkPolicy allowing intra-pod 5701, and configure **TCP/IP
   discovery** (UDP multicast is normally blocked on OpenShift).
5. **Split-brain hygiene:** synchronous DB replication and the JDBC
   `targetServerType` param to avoid a recovered stale primary.
6. **Session handling:** sticky sessions at the Route for BOSH/WebSocket (7070/7443).

Until those are in place, keep `replicas: 1` — scaling the current chart past 1
would corrupt shared conf state.

## Operations

| Action | Command |
|--------|---------|
| Logs | `oc logs -f deployment/openfire-openfire -n openfire` |
| Init container logs | `oc logs deployment/openfire-openfire -n openfire -c init-conf` |
| Stop / start | `oc scale deployment/openfire-openfire -n openfire --replicas=0` (resp. `1`) |
| Restart | `oc rollout restart deployment/openfire-openfire -n openfire` |
| Rollout status | `oc rollout status deployment/openfire-openfire -n openfire` |
| Re-seed config | delete the `*-openfire-conf` PVC, restart (⚠ discards encryption key + keystore) |
| Backup / restore / migrate DB | see [docs/data-lifecycle.md](docs/data-lifecycle.md) |

## License

[Apache License 2.0](LICENSE)
