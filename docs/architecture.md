# Architecture

The front-door overview: how the three repos, Active Directory, PostgreSQL, and
Kerberos fit together — at build time and at runtime.

## The three repositories

| Repo | Produces | Consumed by |
|------|----------|-------------|
| [openfire-authprovider](https://gitlab.com/mkoese/openfire-authprovider) | a JAR (AD-gated `AuthProvider`) | pinned in oci `lib.txt` |
| [openfire-oci](https://gitlab.com/mkoese/openfire-oci) | the container image (Openfire + JDBC driver + auth JAR) | deployed by gitops |
| **openfire-gitops** (this repo) | Helm chart | the cluster |

## Build & supply chain

Everything is pinned by sha256 and flows one way — provider JAR → image → deploy.

```mermaid
flowchart LR
  subgraph AP[openfire-authprovider]
    APsrc[Java source] -->|mvn verify + tag| APjar[JAR in GitLab package registry]
  end
  subgraph OCI[openfire-oci]
    libtxt[lib.txt pins JAR + JDBC driver by sha256]
    plugtxt[plugins.txt pins plugins by sha256]
    tarball[Openfire tarball pinned by sha256]
    cf[Containerfile 2-stage build]
    libtxt --> cf
    plugtxt --> cf
    tarball --> cf
    cf -->|buildah, sha-verified| IMG[container image on registry]
  end
  subgraph GO[openfire-gitops]
    chart[Helm chart] -->|renders| K8S[OpenShift / Kubernetes]
  end
  APjar -.pinned in.-> libtxt
  IMG -.deployed as.-> chart
```

- **Content-addressed**: the sha256 pins mean a mirror (airgapped or otherwise) is
  a drop-in — tampered bytes fail the build. See
  [openfire-oci › security](https://gitlab.com/mkoese/openfire-oci/-/blob/main/docs/security.md).
- **Custom `AuthProvider`s ship in `/opt/openfire/lib`**, not as plugins —
  providers load before plugins.

## Runtime topology

A single active Openfire node with all durable state externalized.

```mermaid
flowchart TB
  subgraph ns[Namespace: openfire]
    subgraph pod[Pod: openfire]
      init[initContainer init-conf: seed conf, build keystore, inject secrets] --> of[openfire container]
    end
    confsecret[(conf Secret: openfire.xml + security.xml)] --> init
    dbsecret[(db / ldap / admin / keytab Secrets)] --> init
    of --- confpvc[(conf PVC: openfire.xml + security.xml + keystores)]
    of --- plugpvc[(plugins PVC)]
    np[NetworkPolicy: same-ns + router ingress; scoped egress]
    route[Route/LoadBalancer] --> of
  end
  of -->|JDBC 5432| PG[(External PostgreSQL)]
  of -->|LDAPS 636 / GC 3269| AD[Active Directory - LDAP]
  of -->|Kerberos 88| KDC[Active Directory - KDC]
  client[XMPP clients] --> route
```

- **PostgreSQL** holds nearly all mutable state; the **conf PVC** holds config +
  the property-encryption key + TLS stores. They are a **matched pair** — see
  [data-lifecycle.md](data-lifecycle.md).
- **Init container** seeds config on first boot, builds the keystore/truststore,
  and injects DB/LDAP/admin passwords from Secrets (never rendered into YAML).
- **Single node** by design; clustering is a documented upgrade path
  ([README › Scaling](../README.md#scaling-beyond-one-node-clustering)).

## Authentication

Three SASL mechanisms in parallel, plus a local admin, all gated by Active
Directory for existence. Details:
[openfire-authprovider](https://gitlab.com/mkoese/openfire-authprovider).

```mermaid
flowchart TD
  start([Login attempt]) --> mech{SASL mechanism}
  mech -->|SCRAM-SHA-1| scram[Serve stored SCRAM hash from ofUser]
  mech -->|GSSAPI| gss[Kerberos ticket -> AdGatedAuthorizationPolicy]
  mech -->|PLAIN / console| plain{local-only user?}
  plain -->|yes: admin| local[Local DB hash only]
  plain -->|no| exists{Exists in AD?}
  exists -->|no| reject[Reject]
  exists -->|yes| acct{Local account?}
  acct -->|no| bind[Verify password via AD bind -> create account, store hash]
  acct -->|yes| hash[Verify against stored DB hash]
  gss --> adgate{Exists in AD?}
  adgate -->|no| reject
  adgate -->|yes| jit[JIT-create if missing -> authorized]
```

- First password is **bootstrapped via AD bind**; afterwards the **DB hash is
  authoritative** (may diverge from AD).
- **SCRAM-SHA-1** works from the second login on (enrollment needs PLAIN or GSSAPI
  once). `admin` never touches AD.
- Only SCRAM hashes are stored (`user.scramHashedPasswordOnly=true`).

## Where to go next

| I want to… | Doc |
|------------|-----|
| Deploy it | [README](../README.md#production-configuration) |
| Understand data / backup | [data-lifecycle.md](data-lifecycle.md) |
| Configure TLS | [tls.md](tls.md) |
| Upgrade Openfire | [upgrading.md](upgrading.md) |
| Scrape metrics (Prometheus/Zabbix) | [monitoring.md](monitoring.md) |
| Turn on debug logs | [openfire-oci › logging](https://gitlab.com/mkoese/openfire-oci/-/blob/main/docs/logging.md) |
| Troubleshoot | [debugging.md](debugging.md) |
