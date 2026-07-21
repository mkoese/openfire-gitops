# Local developer environment

Developing and validating the Helm charts — most of it needs **no cluster**.

## Prerequisites

- `helm` 3.x
- `python3` + `PyYAML` (for the render assertions below) — optional
- `oc` / `kubectl` only when applying to a real dev cluster

## Lint + render (no cluster)

```bash
helm lint charts/openfire
helm template openfire charts/openfire -f charts/openfire/values-openshift.yaml | less
```

### Render matrix — exercise every feature branch

The combinations the CI (`.gitlab-ci.yml`) checks (CI additionally asserts
that the adminPassword / kerberos-requires-auth guards fail when they should):

```bash
# embedded DB, default auth
helm template t charts/openfire >/dev/null
# external PostgreSQL
helm template t charts/openfire --set database.host=pg --set database.existingSecret=pg >/dev/null
# full stack: PG + AD auth + Kerberos (adminPasswordSecret required by the guard)
helm template t charts/openfire \
  --set database.host=pg --set database.existingSecret=pg \
  --set adminPasswordSecret=adm \
  --set auth.enabled=true --set auth.ldap.existingSecret=ldap \
  --set kerberos.enabled=true --set kerberos.keytabSecret=kt \
  --set xmpp.domain=chat.example.com --set xmpp.fqdn=chat.example.com >/dev/null
# TLS + extra keypairs + admin secret + RO rootfs
helm template t charts/openfire \
  --set tls.secretName=tls --set 'tls.extraKeypairs[0].secretName=kp' \
  --set 'tls.extraKeypairs[0].alias=fed' --set adminPasswordSecret=adm \
  --set security.readOnlyRootFilesystem=true >/dev/null
# bring-your-own conf
helm template t charts/openfire --set conf.existingSecret=my-conf >/dev/null
# OpenShift values (routes) + LoadBalancer with scoped CIDRs
helm template t charts/openfire -f charts/openfire/values-openshift.yaml >/dev/null
helm template t charts/openfire -f charts/openfire/values-openshift.yaml \
  --set loadBalancer.enabled=true \
  --set 'networkPolicy.clientCIDRs[0]=10.0.0.0/8' \
  --set 'networkPolicy.s2sCIDRs[0]=192.0.2.0/24' \
  --set routes.adminSsl.enabled=true --set routes.boshSsl.enabled=true >/dev/null
```

### Syntax-check the rendered init script

The init container's `init.sh` is templated — verify the rendered shell parses:

```bash
python3 - <<'EOF'
import yaml
for d in yaml.safe_load_all(open('/tmp/render.yaml')):
    if d and d.get('kind')=='ConfigMap' and 'init.sh' in d.get('data',{}):
        open('/tmp/init.sh','w').write(d['data']['init.sh'])
EOF
sh -n /tmp/init.sh && echo "init.sh OK"
```

(First `helm template ... > /tmp/render.yaml`.)

## Apply to a dev cluster

```bash
oc new-project openfire            # or: kubectl create ns openfire
helm template openfire charts/openfire -f charts/openfire/values-openshift.yaml | oc apply -f -
oc get pods -n openfire -w
```

Tear down — **⚠ full reset**: the rendered stream contains the Namespace and the
PVCs, so this deletes everything including the property-encryption key, the
keystores, and an embedded DB. Never run against a production namespace — see
[data-lifecycle.md](data-lifecycle.md).

```bash
helm template openfire charts/openfire -f charts/openfire/values-openshift.yaml | oc delete -f -
```

To tear down but **keep the data** (PVCs and namespace survive):

```bash
oc delete deployment,svc,route,networkpolicy,cm,secret,sa \
  -l app.kubernetes.io/name=openfire -n openfire
```

## Editing the chart

- `helm template` after every change — the render matrix above catches most breaks.
- Bump `version:` in `charts/openfire/Chart.yaml` on any change; bump
  `appVersion:` only when the Openfire image version changes.
- The init script lives in `templates/configmap-init.yaml` (templated shell) —
  keep it `sh`-compatible (no bashisms) and re-run `sh -n` on the rendered output.
