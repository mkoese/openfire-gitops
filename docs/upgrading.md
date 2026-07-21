# Upgrade & release runbook

The repeatable process for bumping Openfire (and base images / dependencies)
across the three repos, plus how versioning/releases work. Two audiences:
**operators** roll out a released version (first section — nothing else
needed); **maintainers** produce those versions (everything after).

## Operator runbook — rollout in 3 steps

No git access needed — only `helm`, `oc`, and network access to quay.io.
Inputs: **environment** and **chart version** (both come from the promotion
commit / change ticket — operators execute, maintainers decide).

### 1. Pull

```bash
helm pull oci://quay.io/mikailkose/openfire --version 0.13.0 --untar
```

### 2. Apply

```bash
oc whoami && oc project openfire-prod    # right cluster, right namespace?
helm template prod openfire \
  -f openfire/values-openshift.yaml \
  -f openfire/envs/prod.yaml -f openfire/envs/sizes/30k.yaml | oc apply -f -
```

Release name = env name, and always env file **plus** its size tier — never mix:

| Env | After `-f openfire/values-openshift.yaml` add |
|-----|-----------------------------------------------|
| dev | `-f openfire/envs/dev.yaml` |
| preprod | `-f openfire/envs/preprod.yaml -f openfire/envs/sizes/30k.yaml` |
| prod | `-f openfire/envs/prod.yaml -f openfire/envs/sizes/30k.yaml` |

`Recreate` strategy: expect a short outage while the pod restarts — that is by
design (single-writer DB), clients reconnect automatically.

### 3. Verify

```bash
oc rollout status deployment/prod-openfire -n openfire-prod
oc logs deployment/prod-openfire -n openfire-prod --tail=50   # clean startup?
# smoke: XMPP login (PLAIN + SCRAM), admin console reachable
```

**Rollback** = the same 3 steps with the previous version number — published
chart versions are immutable and stay pullable. **Which versions exist:**
`skopeo list-tags docker://quay.io/mikailkose/openfire` (or the Quay UI);
`helm show chart oci://quay.io/mikailkose/openfire` shows the newest.

## What changed → how to roll it out

| Change | Path to an artifact | Then |
|--------|---------------------|------|
| Java (authprovider) | tag `vX.Y.Z` → CI publishes the JAR → update `lib.txt` in openfire-oci (URL + sha256) | continue on the image row ↓ |
| Image content (Containerfile, `plugins.txt`/`lib.txt`/`exclude.txt`, base digest) | push openfire-oci → CI builds + scans; the build job prints the **digest** | pin `image.digest` in `envs/{preprod,prod}.yaml`, bump chart `version`, push → chart republishes → 3-step rollout |
| Chart / env YAML | bump chart `version`, push → validated + republished | 3-step rollout |

Forgetting the version bump cannot slip through: the publish job diffs the
packaged chart against the already-published version — identical content is a
quiet skip, changed content **fails the pipeline** ("bump version in
Chart.yaml"). A published version is never overwritten.

Two YAML-change gotchas:

- A change that only touches the conf Secret (not the pod template) does not
  restart anything — follow the apply with
  `oc rollout restart deployment/<release>-openfire`.
- XML-seeded Openfire properties (`ldap.*`, `adAuth.*`, caches) reach the DB
  **only at first setup**. On an initialized environment change them in the
  admin console (*System Properties*); a values change alone does nothing.
  Reserved settings (DB connection, fqdn) do apply from the file on restart.

## Staging & promotion

Trunk-based: one `main` per repo, short-lived MRs (the MR pipeline runs the
full validation matrix before merge), releases are tags/versions —
**environments are files, never branches.**

- **Promote artifacts, not rebuilds** — the image tag + chart version smoke-
  tested in dev is byte-identical in prod.
- **dev floats, preprod/prod pin.** dev runs the moving `main` image tag (the
  oci CI updates it on every branch build; refresh =
  `oc rollout restart deployment/dev-openfire -n openfire-dev`). **preprod/prod pin the image
  DIGEST** (`image.digest` in `envs/*.yaml` — UBI model: tags roll, digests
  pin; the digest comes from the oci build job's log). One commit per
  promotion is the audit trail — and `git revert` of that commit is the
  rollback recipe.
- **Jars are never snapshots, not even in dev** — the image always contains a
  released, sha256-pinned jar (`lib.txt`). Snapshot iteration lives in local
  podman ([openfire-oci › local-dev](https://gitlab.com/mkoese/openfire-oci/-/blob/main/docs/local-dev.md)).
- Promotion order dev → preprod → prod. Preprod runs the **prod size tier**,
  so load/reconnect-storm/GSSAPI tests belong there. Batch changes; promote
  tested states, not every commit.

## CVE response (Log4Shell-class)

First question: **which layer is affected?** Each layer has a different fix
and a different speed — check them fastest-first:

| Layer (example) | Fix | Speed |
|---|---|---|
| A JVM-flag mitigation exists (Log4Shell's `formatMsgNoLookups`) | add the flag to `javaOpts` in the env values, bump chart version, roll out | **minutes — no rebuild** (env-var change restarts the pod) |
| Unused bundled jar (the mssql-jdbc case) | add a glob to `exclude.txt` (openfire-oci) → rebuild | ~1 h |
| Pinned jar — JDBC driver, plugin, authprovider | bump its `lib.txt`/`plugins.txt` line (new URL + sha256) → rebuild | ~1 h |
| OS package in the base image (openssl, curl, glibc) | wait for the Red Hat erratum → bump both `FROM …@sha256:` digests in the Containerfile, **empty `.trivyignore`** → rebuild | erratum-dependent (hours–days) |
| Openfire itself | full [version bump](#openfire-version-bump--step-by-step) | days — needs the upstream release |

The authprovider jar has **zero runtime dependencies** (Openfire provides
everything, test-scope deps never ship) — a "Maven dependency CVE" always
lands in one of the rows above, never inside the jar itself.

**Emergency promotion** (actively exploited): compress the ladder, don't skip
it. dev picks the rebuild up through `main` automatically; smoke preprod in
minutes instead of days; pin the new digest in `envs/prod.yaml` and roll prod
in a same-day window — the `Recreate` outage is acceptable when the
alternative is an exploitable prod. Rollback stays one digest away in git
history.

Verify on both channels: the trivy gate is green on the new build **and** the
Quay security tab (Clair) agrees. And the Log4Shell precedent is baked in as
defense-in-depth — `-Dlog4j2.formatMsgNoLookups=true` is permanent in
`JAVA_OPTS`: a mitigation flag may stay even after the real fix lands.

## Versioning at a glance

| Repo | Version(s) | Drives |
|------|-----------|--------|
| openfire-authprovider | `pom.xml` `<version>` (semver) + `openfire.version` | the released JAR |
| openfire-oci | `OPENFIRE_VERSION` (Containerfile ARG + CI) + `OPENFIRE_SHA256` | image build + tag |
| openfire-gitops | chart `version` (semver) + `appVersion` (= Openfire version) + `image.digest` (preprod/prod) / `image.tag: main` (dev) | the deployment |

## Check for newer versions

```bash
# Openfire — latest stable
curl -fsSL https://api.github.com/repos/igniterealtime/Openfire/releases/latest | grep tag_name
# PostgreSQL JDBC — latest on Maven Central
curl -fsSL https://repo1.maven.org/maven2/org/postgresql/postgresql/maven-metadata.xml | grep -E '<latest>'
# UBI base images — newest tags
skopeo list-tags docker://registry.access.redhat.com/ubi9/ubi | tail
skopeo list-tags docker://registry.access.redhat.com/ubi9/openjdk-17-runtime | tail
```

Confirm the **Java baseline** in the Openfire changelog before assuming 17 still
works — a minimum-Java bump is the one breaking change to watch for (5.x has kept
17; a future major could require 21, which would mean the `openjdk-21-runtime`
base image).

## Openfire version bump — step by step

Do this in order; the compat gate protects everything downstream.

### 1. Compat-gate the auth provider (do this FIRST)

```bash
cd openfire-authprovider
# edit pom.xml: <openfire.version>NEW</openfire.version>
mvn verify        # MUST pass — proves the AuthProvider/SCRAM API is unchanged
```

If `mvn verify` fails, the Openfire API changed — resolve that before touching the
image or chart. (See [openfire-authprovider › local-dev](https://gitlab.com/mkoese/openfire-authprovider/-/blob/main/docs/local-dev.md).)

### 2. Release a new auth provider

```bash
# bump <version> in pom.xml (e.g. 0.2.0 -> 0.2.1), commit
git tag v0.2.1 && git push origin main v0.2.1     # -> GitLab package registry
```

Grab the published JAR's sha256:

```bash
curl -fsSL -o ap.jar "<package-registry-url>/openfire-authprovider-0.1.4.jar"
shasum -a 256 ap.jar
```

### 3. Bump openfire-oci

- `Containerfile`: both `ARG OPENFIRE_VERSION=NEW`
- `.gitlab-ci.yml` + `.github/workflows/build.yml`: `OPENFIRE_VERSION` and
  `OPENFIRE_SHA256` (get the new tarball sha):
  ```bash
  V=NEW; VF=$(echo $V | tr . _)
  curl -fsSL -o of.tgz "https://github.com/igniterealtime/Openfire/releases/download/v$V/openfire_${VF}.tar.gz"
  shasum -a 256 of.tgz
  ```
- `lib.txt`: point the authprovider line at the new version URL **and** sha256 from step 2.
- README version references.

Push → the pipeline builds and pushes the new image. Verify:

```bash
skopeo inspect --override-os linux --override-arch amd64 \
  docker://quay.io/mikailkose/openfire-oci:NEW | grep -i version
```

### 4. Bump openfire-gitops

- `charts/openfire/Chart.yaml`: `appVersion: "NEW"`, bump `version:` (minor)
- `charts/openfire/values.yaml` + `values-openshift.yaml`: `image.tag: "NEW"`

Validate: `helm lint` + the render matrix ([local-dev.md](local-dev.md)).

### 5. Deploy — per environment, promotion order

Always deploy with the environment overlay **and** its size tier — a bare
`helm template openfire charts/openfire …` would create a *new* default
instance instead of upgrading. Promote dev → preprod → prod:

```bash
helm template dev charts/openfire \
  -f charts/openfire/values-openshift.yaml -f envs/dev.yaml | oc apply -f -
oc rollout status deployment/dev-openfire -n openfire-dev
# smoke-test, then preprod (same size tier as prod!), then prod:
helm template prod charts/openfire \
  -f charts/openfire/values-openshift.yaml \
  -f envs/prod.yaml -f envs/sizes/30k.yaml | oc apply -f -
oc rollout status deployment/prod-openfire -n openfire-prod
```

**Schema migration is automatic** — on first boot of the new version Openfire's
`SchemaManager` applies the DB migration scripts; watch for the upgrade line in
the logs. No manual SQL. Fresh databases are created at the new version directly.

### Rollout from the registry (no git checkout)

Every chart version is also published as an **OCI artifact** to
`oci://quay.io/mikailkose/openfire` (CI job `publish-chart`), with all
environment presets bundled — the same registry the cluster pulls the image
from. A machine with only `helm`, `oc` and Quay access rolls out with:

```bash
helm pull oci://quay.io/mikailkose/openfire --version 0.13.0 --untar
helm template prod openfire \
  -f openfire/values-openshift.yaml \
  -f openfire/envs/prod.yaml -f openfire/envs/sizes/30k.yaml | oc apply -f -
oc rollout status deployment/prod-openfire -n openfire-prod
```

Published chart versions are **immutable** — a rollback is a `helm pull` of the
previous version with the same commands. Newest version:
`helm show chart oci://quay.io/mikailkose/openfire`; all versions:
`skopeo list-tags docker://quay.io/mikailkose/openfire` (or the Quay UI).
Publishing to a Nexus later is the same mechanism — charts are plain OCI
artifacts, only the URL changes.

## Base image (UBI) bump

Lower risk, self-contained to oci. Base images are pinned by **digest**
(tags are rebuilt in place by Red Hat), so a bump = new tag **and** new digest:

```bash
skopeo inspect --raw docker://registry.access.redhat.com/ubi9/ubi:NEW | sha256sum
```

- `Containerfile`: `FROM ubi9/ubi:NEW@sha256:<digest>` (builder) and
  `openjdk-17-runtime:NEW@sha256:<digest>` (runtime)
- `.gitlab-ci.yml`: `buildah:NEW@sha256:<digest>`
- README references

The runtime base (`openjdk-17-runtime`) and PostgreSQL driver bump the same way
(their pins in the Containerfile / `lib.txt`).

## Rollback

- **Image**: redeploy the previous `image.digest` (git history of
  `envs/*.yaml` lists every digest ever promoted; the unique build tag keeps
  each digest referenced in the registry).
- **Chart**: `helm rollback` if you install with Helm, or re-apply the previous
  rendered manifests.
- **Database**: a schema that has been migrated forward is **not** auto-downgraded
  — a rollback across a schema change needs a DB restore ([data-lifecycle.md](data-lifecycle.md)).
  Back up before a major upgrade.

## Post-upgrade checklist

- [ ] `mvn verify` green (authprovider compat gate)
- [ ] new image on the registry with the expected version label
- [ ] `lib.txt` sha256 matches the CI-published JAR (not a local build)
- [ ] `helm template` matrix renders
- [ ] pod healthy; logs show the schema migration line (if a version jump)
- [ ] a real login works (PLAIN + SCRAM), admin console reachable
