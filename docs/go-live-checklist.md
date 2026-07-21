# Go-live checklist

One-time acceptance tests after deploying the chart to the production cluster.
Run top to bottom — each layer depends on the previous one. Command reference:
[admin-basics.md](admin-basics.md).

## 1. Pod healthy

- [ ] `oc rollout status deployment/<release>-openfire -n <namespace>` — Ready
- [ ] `oc logs deployment/<release>-openfire -n <namespace> -c init-conf` — conf
      seeded, keystore built, no errors
- [ ] `oc logs deployment/<release>-openfire -n <namespace> | grep -i error` — triage
      anything that shows up

## 2. DNS

- [ ] `dig +short chat.example.com` → the LoadBalancer / router IP
- [ ] `dig +short SRV _xmpp-client._tcp.chat.example.com` — points clients at
      host + port 5222 (recommended; without it clients guess the hostname)
- [ ] Federation only: `dig +short SRV _xmpp-server._tcp.chat.example.com`

## 3. Ports

- [ ] `nc -vz chat.example.com 5222` and `5223` (through the LoadBalancer —
      also proves `networkPolicy.clientCIDRs` is right)
- [ ] Route hosts answer on 443 (`curl -fsSI https://<admin-route>/login.jsp`)

## 4. TLS

- [ ] Cert on 5223 has the right subject/SANs (= `xmpp.fqdn`) and full chain
- [ ] `openssl x509 -checkend 2592000` — not expiring within 30 days
- [ ] Passthrough routes (if enabled) present the pod cert, not the router wildcard

## 5. Protocol endpoints

- [ ] `openssl s_client -connect chat.example.com:5222 -starttls xmpp` — the
      handshake completing proves a live XMPP stream, not just an open port
- [ ] `curl -k https://chat.example.com:7443/http-bind/` returns an **HTTP 400**
      — that is success (BOSH expects POST; any HTTP answer proves the
      listener; connection refused/timeout is the failure)

## 6. Logins — the real test

- [ ] PLAIN first login with an **enabled AD user** → succeeds (enrollment via
      AD bind, hash stored)
- [ ] Same user, second login → succeeds via SCRAM-SHA-1
- [ ] **Disabled AD user** → rejected (proves `auth.ldap.searchFilter`)
- [ ] Non-group member → rejected (only if using the `memberOf` clause)
- [ ] `admin` login on the admin console → works without touching AD
- [ ] Wrong password 5× → account locks (Openfire `LockOutManager`)
- [ ] Kerberos: SSO login works, **including a mixed-case `sAMAccountName`**
      (e.g. `JSmith` — known risk, see
      [openfire-authprovider README](https://gitlab.com/mkoese/openfire-authprovider#configuration-system-properties))

## 7. Data & operations

- [ ] PostgreSQL schema was created on first boot (`psql … -c '\dt'` shows
      `of*` tables) and the logs show no schema errors
- [ ] Backup executed once for real ([data-lifecycle.md](data-lifecycle.md))
      — **and restored into a scratch namespace**: an untested backup is a wish
- [ ] Secrets contain what you think (`base64 -d | od -c`,
      [admin-basics.md](admin-basics.md#kubernetes-secrets-gotchas))
- [ ] A pod delete (`oc delete pod …`) recovers on its own and users can log
      in again afterwards
