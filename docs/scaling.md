# Scaling: 100k users / ~30k concurrent on one node

The deliberate architecture: **one tuned node + fast restart**, not clustering
(see [README › Availability & scaling](../README.md#availability--scaling)).
Sized for **100k registered users with ~30k concurrent sessions** (Path A).
This doc holds the estimates behind `envs/prod.yaml`, the hard ceiling of the
single-node design, and the test that turns estimates into facts.

## Size tiers (envs/sizes/)

Capacity is a **size overlay**, layered after the environment file — pick the
tier at or above your expected **concurrent** sessions:

```bash
helm template prod charts/openfire \
  -f charts/openfire/values-openshift.yaml \
  -f envs/prod.yaml -f envs/sizes/10k.yaml | oc apply -f -
```

| Tier | Memory (≈heap) | Direct mem | CPU req | DB pool | Roster cache | User/group |
|------|---------------|-----------|---------|---------|--------------|------------|
| [2k](../envs/sizes/2k.yaml) | 2Gi (1.2Gi) | 512m | 1 | 25 | 10MB | 5MB |
| [5k](../envs/sizes/5k.yaml) | 3Gi (1.8Gi) | 512m | 2 | 50 | 20MB | 5MB |
| [10k](../envs/sizes/10k.yaml) | 4Gi (2.4Gi) | 512m | 2 | 50 | 20MB | 5MB |
| [20k](../envs/sizes/20k.yaml) | 6Gi (3.6Gi) | 1g | 4 | 75 | 40MB | 10MB |
| [30k](../envs/sizes/30k.yaml) | 8Gi (4.8Gi) | 1536m | 4 | 100 | 100MB | 25MB |

All tiers derive from the same per-session estimates:

- **heap** ≈ 0.75Gi base + ~100KB × sessions + caches + GC headroom;
  heap is 60% of the container limit (`MaxRAMPercentage`), request = limit
- **direct memory** — Netty holds TLS buffers in NATIVE memory (~32KB ×
  connections); it is capped explicitly (`MaxDirectMemorySize`) because the
  JVM default (= heap size) lets heap + native exceed the cgroup limit →
  OOMKilled with no Java diagnostics
- **CPU** ≈ storm-driven: reconnect storm = sessions × ~1–2ms TLS handshake;
  steady chat (~5 msg/min/user) is comparatively free. Never CPU-limited.
- **DB pool** ≈ storm logins/s × query time, with **PostgreSQL
  `max_connections` ≥ pool × 1.5**
- **caches** ≈ roster ~2KB × sessions; user/group scale with registered users
- **AD load** — PLAIN logins cost one LDAP search each (the existence gate),
  so a PLAIN-heavy reconnect storm sends up to `logins/s` searches to a DC;
  SCRAM reconnects (the normal case) never touch AD

Preprod must run the **same tier as prod** — otherwise the load test measures
the wrong system. Caches are **seeded at first setup only** — afterwards tune
live in *Server Manager → Cache Summary* (grow anything with low hit rate /
high eviction). Fixed regardless of tier: probes (startup 2s / readiness 5s)
and `pullPolicy: IfNotPresent` (restart never depends on the registry).

## Where the ceiling is (what breaks first)

Single-node limits with this config, in the order you'd hit them:

| # | Limit | Kicks in around | Symptom | Lever |
|---|-------|-----------------|---------|-------|
| 1 | Reconnect-storm duration | >30k concurrent | after a restart, minutes of 100% CPU while TLS handshakes drain | more CPU request, or accept a longer blip |
| 2 | Heap | ~50–60k sessions (at 6Gi heap, ~100KB each) | GC pressure, rising latency, eventually `ExitOnOutOfMemoryError` | bigger limit (12–16Gi) buys a bit more |
| 3 | DB pool / PostgreSQL | login storms > ~1k logins/s | slow logins after restarts | pool + PG sizing |
| 4 | Single-JVM practicality | **~50k concurrent** | GC pauses + restart blast radius stop being a "blip" | **this is the Path B line — Hazelcast clustering, no more single-node tuning** |

Rule of thumb: **designed for 30k, headroom to ~50k, clustering beyond that.**
File descriptors (1 per session) are not on the list — verify once with
`oc exec … -- sh -c 'ulimit -n'` (needs ≫ 60k; OpenShift default is far above).

## The restart story (what users experience)

Total blip ≈ termination (seconds) + scheduling + cached-image start + init
(~2–5s) + Openfire boot + probe tick (≤2s): **well under a minute**. Then the
storm: 30k reconnects ≈ 15–30s of TLS + login work on 4 cores. SCRAM
reconnects don't touch AD; refused connections during the blip are not failed
logins (no lockouts). Clients reconnect automatically.

## Off-chart checklist (infrastructure)

- **LB idle timeout** must exceed Openfire's keepalive interval (XEP-0199,
  default ~6 min) or idle chats die silently — raise the LB timeout or lower
  `xmpp.client.idle` via `conf.extraXml`.
- **PostgreSQL**: `max_connections` ≥ 150; the DB is the real SPOF — its HA is
  an infrastructure topic.
- **LB / conntrack**: 30k long-lived TCP connections through the LoadBalancer —
  check the LB's connection table and node conntrack limits once.

## Prove it (Tsung)

Estimates are not evidence. Against **preprod** (mirrors prod sizing):

1. [Tsung](http://tsung.erlang-projects.org/) XMPP scenario: ramp to
   **30k sessions** (e.g. 300/s), hold 30 min, exchange messages.
2. Mid-test: `oc delete pod -l app.kubernetes.io/name=openfire -n openfire-preprod`
   — measure time-to-Ready and time until all sessions re-established.
3. Watch: heap (< 80% sustained), DB pool saturation, session-count recovery.

Pass = full recovery under ~2 minutes with no errors after re-establishment.
Bonus run: ramp to 50k to see ceiling #1/#2 with your own eyes — that number
is the objective trigger for Path B.
