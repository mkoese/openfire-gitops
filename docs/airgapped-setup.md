# Airgapped deployment

Deploying the chart where the cluster has **no internet**. The image is built
outside (openfire-oci CI) and mirrored into the internal registry.

Companion guides: [openfire-oci airgapped build](https://gitlab.com/mkoese/openfire-oci/-/blob/main/docs/airgapped-setup.md)
and [openfire-authprovider airgapped build](https://gitlab.com/mkoese/openfire-authprovider/-/blob/main/docs/airgapped-setup.md).

## What the deployment needs from inside the cluster

The chart itself pulls **no images at render time** — `helm template | oc apply`
works offline. Only the *deployed* reference must resolve inside the cluster:

| Reference | Where it's set | Airgapped value |
|-----------|----------------|-----------------|
| Openfire image | `image.repository` / `image.tag` | internal registry path |

## 1. Mirror the image into the internal registry

```bash
skopeo copy docker://quay.io/mikailkose/openfire-oci:5.1.1 \
  docker://registry.internal/openfire/openfire-oci:5.1.1
```

Point the chart at them:

```yaml
image:
  repository: registry.internal/openfire/openfire-oci
  tag: "5.1.1"
```

## 2. Deploy the charts

```bash
# Namespace + deployment (no internet needed to render or apply).
# Use your environment overlay + size tier (see README > Multiple environments):
helm template prod ./charts/openfire \
  -f ./charts/openfire/values-openshift.yaml \
  -f envs/prod.yaml -f envs/sizes/30k.yaml \
  --set image.repository=registry.internal/openfire/openfire-oci | oc apply -f -
```

Create the runtime secrets (DB, LDAP, admin, keystore, keytab) from internal
sources as usual — see the [main README](../README.md#production-configuration).
None of them require internet.

## Notes

- Building the image itself in an airgapped GitLab is covered by
  [openfire-oci airgapped build](https://gitlab.com/mkoese/openfire-oci/-/blob/main/docs/airgapped-setup.md).
- Chart values `pullPolicy` can stay `IfNotPresent` to avoid unnecessary registry
  round-trips once the image is present on the node.
