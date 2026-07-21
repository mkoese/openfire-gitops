# Monitoring (Prometheus / Zabbix)

How to scrape this deployment. Health/liveness for K8s probes is covered in
[README › Operations](../README.md) and [debugging.md](debugging.md).

> **No "actuator".** Openfire is a plain Java app (`java -jar startup.jar` with
> embedded Jetty), **not** Spring Boot — there is no Actuator, no built-in
> `/metrics`, and **no Prometheus exporter plugin exists** (checked the official
> plugin list). The realistic path is the **Prometheus JMX Exporter javaagent**.

## Do you even need an exporter?

**Container CPU and memory come for free** from the platform — kubelet/cAdvisor
exposes `container_cpu_usage_seconds_total`, `container_memory_working_set_bytes`,
etc., and the cluster Prometheus already scrapes them. Combined with the K8s
probes, that covers "is it healthy / how much is it using."

An exporter only adds **JVM-internal** visibility cAdvisor can't see: heap vs the
container limit (RSS ≠ heap), GC pause times/frequency, thread counts, class
loading. That's a **JVM-tuning / GC-debugging** aid — add it if and when you chase
a heap/GC problem, otherwise the pod metrics are enough. The rest of this section
is the recipe for when you want it.

## Prometheus — via the JMX Exporter javaagent (optional)

[`prometheus/jmx_exporter`](https://github.com/prometheus/jmx_exporter) runs
**in-process** as a `-javaagent`, reads the JVM's platform MBean server directly
(no RMI, no `xmpp.jmx.*` needed), and serves `/metrics` over HTTP. The image
passes `JAVA_OPTS` straight to the JVM, so wiring is:

1. **Bake the agent jar into the image** — add it to
   [`lib.txt`](https://gitlab.com/mkoese/openfire-oci/-/blob/main/lib.txt) (pinned
   by sha256 like everything else); it lands in `/opt/openfire/lib/`:
   ```
   jmx_prometheus_javaagent|https://repo1.maven.org/maven2/io/prometheus/jmx/jmx_prometheus_javaagent/1.6.0/jmx_prometheus_javaagent-1.6.0.jar|<sha256>
   ```
2. **Provide a config** `jmx_exporter.yaml` (mount via ConfigMap, or bake it):
   ```yaml
   lowercaseOutputName: true
   lowercaseOutputLabelNames: true
   # no jmxUrl/hostPort => scrape THIS process's MBean server directly
   rules:
     - pattern: ".*"
   ```
3. **Append to `JAVA_OPTS`** (gitops `javaOpts`) — `=<port>:<config>`:
   ```yaml
   javaOpts:
     - -javaagent:/opt/openfire/lib/jmx_prometheus_javaagent-1.6.0.jar=9400:/opt/openfire/conf/jmx_exporter.yaml
     # ...keep the existing flags...
   ```
4. **Expose + scrape** — add a `9400` container port + Service port; Prometheus
   scrapes `http://<pod>:9400/metrics`. With the Prometheus Operator, add a
   `ServiceMonitor` selecting the openfire Service on that port.

**What you get:** JVM metrics (heap, GC, threads, CPU, class loading) and Jetty
metrics — solid for capacity/health. **What you don't get:** a rich set of
Openfire *business* metrics (session counts, packet rates) is **not** guaranteed
over JMX — treat this as JVM/Jetty-centric monitoring.

> Enabling this needs an image rebuild (the agent jar in `lib.txt`). Ask and I'll
> wire an opt-in `metrics` toggle into the chart + image.

## Remote JMX (for JConsole / Zabbix Java gateway)

Only needed for *remote* JMX clients — the jmx_exporter above does **not** need
it. Enable via system properties (verified in Openfire source `JMXManager.java`):

| Property | Default | Meaning |
|----------|---------|---------|
| `xmpp.jmx.enabled` | `false` | master switch (**restart required**) |
| `xmpp.jmx.port` | `1099` | RMI connector port |
| `xmpp.jmx.secure` | `true` | require an Openfire admin login to connect |

```xml
<xmpp><jmx><enabled>true</enabled><port>1099</port><secure>true</secure></jmx></xmpp>
```

⚠️ The built-in connector uses RMI bound to `localhost`, which is fiddly through
containers/firewalls — prefer the jmx_exporter for scraping and reserve remote JMX
for ad-hoc JConsole sessions over `oc port-forward`.

## Zabbix

Two standard approaches (no Openfire-specific template exists):

1. **JMX via the Zabbix Java gateway** — install the gateway, define a JMX
   interface, attach JMX items. Requires remote JMX enabled (above). Zabbix's
   generic "Java JMX" template covers JVM heap/threads/GC. RMI-in-containers
   caveats apply.
2. **HTTP checks** — `web.page.get` / HTTP-agent items against
   `http://<host>:9090/login.jsp` for up/down + latency. No JMX plumbing.

**Pragmatic:** run the jmx_exporter (Prometheus section) and have Zabbix scrape
its HTTP `/metrics` too — one metrics surface, no RMI.

## The Monitoring Service plugin (what it is / isn't)

The official [Monitoring Service](https://www.igniterealtime.org/projects/openfire/plugins/monitoring/readme.html)
plugin (v2.8.0, requires Openfire 5.1.0+) provides **chat archiving** and
**admin-console statistics/reports with graphs**. It is **not** a metrics endpoint
— don't point Prometheus/Zabbix at it. Add it (via `plugins.txt`) if you want
in-console usage stats or message archiving, not for scraping.

## Health / liveness endpoints

- **`GET /login.jsp` on 9090** — what the image `HEALTHCHECK` and the chart probes
  use today. Reliable "Jetty up + console renders" check (a bit heavy).
- **REST API plugin** (`openfire-restAPI-plugin`, not bundled here) adds
  purpose-built `/plugins/restapi/v1/system/liveness` and `/readiness` endpoints
  (deadlock/connection/plugin checks; 200 = healthy). Better-shaped for probes —
  but **confirm their auth requirement on your build first** (the plugin secures
  most endpoints; whether these are exempt is unclear). Until confirmed,
  `/login.jsp` stays the default.

## Log-based monitoring

All logs go to stdout, so any cluster log stack (EFK/Loki, OpenShift Logging)
ingests them with no config. Raise levels via env vars for investigations —
[openfire-oci › logging](https://gitlab.com/mkoese/openfire-oci/-/blob/main/docs/logging.md).
