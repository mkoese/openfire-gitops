# TLS & certificates

How the chart builds Openfire's keystores, how to use a real CA certificate,
extra keypairs, trusted CAs, rotation, and cert-manager.

> Not to be confused with **property encryption** (`security.xml`, the DB/LDAP
> password encryption key) — that's a separate mechanism, see
> [data-lifecycle.md](data-lifecycle.md).

## The model

Openfire keeps two JKS stores in `/opt/openfire/resources/security` (persisted on
the conf PVC):

| Store | Holds | Built from |
|-------|-------|------------|
| `keystore` | the server's **identity** (cert + private key) | self-signed, or your `tls.secretName` |
| `truststore` | **trusted CA** certs (for S2S / LDAPS validation) | stock CAs + your `tls.trustedCAConfigMap` |

The init container (`templates/configmap-init.yaml`) builds these on startup. The
store password comes from `tls.keystorePasswordSecret` (else the Java default
`changeit`).

## Default: self-signed

With nothing configured, the init container generates a self-signed cert on first
boot (RSA-2048 / SHA-256, SANs = service FQDN + `localhost`, 5-year validity).
Fine for internal/testing; browsers and federated servers won't trust it.

## Which names to order — and where the URLs come from

Before ordering a certificate you need to know **which hostnames** it must
cover. There are two kinds, from two different places:

| Name | Set where | Presented by | Used for |
|------|-----------|--------------|----------|
| XMPP FQDN, e.g. `chat.example.com` | `xmpp.fqdn` in values | the **pod keystore** (this doc) | XMPP clients (5222/5223), S2S federation, passthrough routes |
| Route URL(s), e.g. `openfire-openfire-admin-openfire.apps.<cluster-domain>` | OpenShift **generates** them | depends on route type, see below | admin console / BOSH in the browser |

**Where the route URL comes from:** if `routes.<name>.host` is *not* set in
values, OpenShift generates it as
`<release>-openfire-<route>-<namespace>.apps.<cluster-domain>`. Look them up:

```bash
oc get route -n openfire                                      # actual HOST/PORT column
oc get ingresses.config/cluster -o jsonpath='{.spec.domain}'  # the apps.<cluster-domain> part
```

Setting `routes.<name>.host: chat.example.com` overrides the generated name —
then DNS for that name must point to the cluster's router.

**What that means for ordering:**

- **Edge routes** (`routes.admin`, `routes.bosh`) are terminated by the
  **router**, which presents the cluster's wildcard certificate
  (`*.apps.<cluster-domain>`). With generated hosts you order **nothing** —
  it's already covered.
- **Passthrough routes** (`routes.adminSsl`, `routes.boshSsl`) and the **direct
  XMPP ports** present the **pod keystore** certificate — the certificate you
  order must cover `xmpp.fqdn` **plus** every passthrough route host.

So the typical order is one certificate with SANs =
`chat.example.com` (+ passthrough hosts if they differ).

## Ordering a certificate

**Option A — cert-manager** (if installed): no CSR handling, auto-renewal; see
[cert-manager](#cert-manager) below. Put the names from the section above into
`dnsNames`.

**Option B — CSR to your CA** (corporate CA, or any public CA):

```bash
# 1. Key + CSR with all required SANs (CN alone is not enough -- browsers/JVMs check SANs)
openssl req -new -newkey rsa:2048 -nodes \
  -keyout server.key -out server.csr \
  -subj "/CN=chat.example.com" \
  -addext "subjectAltName=DNS:chat.example.com"

# 2. Submit server.csr to the CA; you receive server.crt (+ intermediate chain)

# 3. Bundle leaf + intermediates (root not needed) and create the secret
cat server.crt intermediate.crt > fullchain.crt
oc create secret tls openfire-tls --cert=fullchain.crt --key=server.key -n openfire
```

Then reference it (next section). Keep `server.key` out of git — it exists only
in the secret.

## Use a CA-issued certificate

Provide a standard Kubernetes TLS secret (keys `tls.crt`, `tls.key`):

```bash
oc create secret tls openfire-tls --cert=server.crt --key=server.key -n openfire
```

```yaml
tls:
  secretName: openfire-tls
```

The init container imports it into the keystore **on every start**, so a renewed
certificate is picked up on the next pod restart (see [Rotation](#rotation)).

### cert-manager

With [cert-manager](https://cert-manager.io) installed, "ordering" is declaring
a `Certificate` — cert-manager builds the CSR, talks to the CA, stores the
result in the secret, and renews it before expiry.

**1. Find an issuer.** The cluster admin usually provides one (corporate CA via
ACME/Vault/Venafi, or Let's Encrypt):

```bash
oc get clusterissuer                 # cluster-wide issuers
oc get issuer -n openfire            # namespace-local issuers
```

> Let's Encrypt with HTTP-01 only works for **publicly reachable** route hosts;
> internal names need a corporate issuer or DNS-01.

**2. Declare the Certificate** (the `dnsNames` come from
[Which names to order](#which-names-to-order--and-where-the-urls-come-from)):

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: openfire
  namespace: openfire
spec:
  secretName: openfire-tls          # cert-manager writes tls.crt/tls.key here
  dnsNames:
    - chat.example.com              # xmpp.fqdn
    # - openfire-openfire-admin-openfire.apps.<cluster-domain>  # passthrough hosts, if any
  privateKey:
    algorithm: RSA
    size: 2048
  issuerRef:
    name: my-issuer
    kind: ClusterIssuer             # or Issuer
```

```bash
oc apply -f certificate.yaml
oc get certificate -n openfire      # wait for READY=True
oc describe certificate openfire -n openfire   # troubleshooting: Events at the bottom
```

**3. Reference the secret in values** and deploy:

```yaml
tls:
  secretName: openfire-tls
```

cert-manager renews the secret automatically (default: at 2/3 of lifetime); the
init container imports it **on every pod start**, so a renewal is picked up on
the next restart/rollout — restart proactively after renewal, or schedule
rollouts more frequent than the cert lifetime:

```bash
oc rollout restart deployment/<release>-openfire -n openfire
```

## Extra keypairs

Import additional private/public keypairs into the keystore under distinct
aliases — e.g. a dedicated S2S/federation identity:

```yaml
tls:
  extraKeypairs:
    - secretName: xmpp-federation-keypair   # keys: tls.crt, tls.key
      alias: federation
```

Each is re-imported (delete + import per alias) on every start, so rotations apply
on restart.

## Trusted CAs (truststore)

Import CA certificates so Openfire trusts them for S2S federation and LDAPS:

```yaml
tls:
  trustedCAConfigMap: config-trusted-cabundle   # each .crt/.pem key is imported
```

Duplicates are skipped. On OpenShift, the injected `config-trusted-cabundle`
ConfigMap is a common source.

## Custom keystore password

The self-signed keystore otherwise uses `changeit`. Set a real password:

```bash
oc create secret generic openfire-keystore-password \
  --from-literal=keystore-password=<strong-pw> -n openfire
```
```yaml
tls:
  keystorePasswordSecret: openfire-keystore-password
```

> **The chart tells Openfire the password automatically** — `keypass`/
> `trustpass` are templated into the chart-managed `openfire.xml` and kept in
> sync on every pod start. Only a bring-your-own conf (`conf.existingSecret`)
> must set them itself; without them Openfire can't open the store.

## Rotation

Certs and stores are rebuilt/re-imported on **pod start**, so rotation = a pod
restart after the source secret changes:

```bash
oc rollout restart deployment/<release>-openfire -n openfire
```

The `keystore` (from `tls.secretName`) is rebuilt from scratch each boot; the
`truststore` and `extraKeypairs` are re-synced. The self-signed cert is only
(re)generated if the keystore doesn't already exist.

## Client-facing TLS (Routes)

Terminating TLS at the OpenShift Route is separate from the pod keystore:

- **Edge** (`route-edge.yaml`) — router terminates TLS; router→pod hop is
  cleartext on the SDN.
- **Passthrough** (`route-passthrough.yaml`, the `*Ssl` routes → 9091/7443) — TLS
  goes end-to-end to the pod (browser sees the pod cert).

For sensitive consoles prefer passthrough or a reencrypt route. See
[README › Security](../README.md#security).

## Verify

```bash
oc exec deployment/<release>-openfire -n openfire -- \
  keytool -list -keystore /opt/openfire/resources/security/keystore \
  -storepass "$KEYSTORE_PASS"
# from outside:
openssl s_client -connect <host>:5223 -servername <fqdn> </dev/null | openssl x509 -noout -subject -dates
```
