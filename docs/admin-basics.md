# Admin basics

The prerequisite skills for operating this stack, each covered for **Windows
and Linux**: sha256 checksums, PostgreSQL connectivity, LDAP/AD checks
(including the search filter), TLS certificate inspection, Kerberos sanity
checks, and Kubernetes secrets gotchas. For the one-time acceptance tests
before going live, see [go-live-checklist.md](go-live-checklist.md).

## Checksums (sha256)

Why you need this: the image build refuses unverified bytes — the Openfire
tarball is pinned via the `OPENFIRE_SHA256` build arg, plugins/libs via the
`sha256` column in `plugins.txt`/`lib.txt` (openfire-oci repo). On every
version bump you compute the new checksum and update the pin
([upgrading.md](upgrading.md)).

The idea: a sha256 hash is a fingerprint of the file's **bytes**. Same bytes =
same hash, one flipped bit = completely different hash. Compare the *entire*
hash against a trusted source (the project's release page, or the pins in
these repos) — if it differs, the file is not what you think it is: don't use it.

### Linux

```bash
# create
sha256sum openfire_5_1_1.tar.gz
#   d930be11c93c...  openfire_5_1_1.tar.gz

# verify a single file against an expected hash (note: TWO spaces)
echo "d930be11c93c...  openfire_5_1_1.tar.gz" | sha256sum -c -
#   openfire_5_1_1.tar.gz: OK

# verify many files from a checksum file
sha256sum -c checksums.txt
```

macOS: same patterns with `shasum -a 256`.

### Windows (PowerShell)

```powershell
# create (SHA256 is the default algorithm)
Get-FileHash .\openfire_5_1_1.tar.gz
# compare (case-insensitive -eq, Get-FileHash prints uppercase)
(Get-FileHash .\openfire_5_1_1.tar.gz).Hash -eq 'D930BE11C93C...'
```

Classic cmd alternative:

```bat
certutil -hashfile openfire_5_1_1.tar.gz SHA256
```

## PostgreSQL connectivity

Connections fail in **layers** — test them in order and you know exactly what
to fix:

| Layer | Test | If it fails |
|-------|------|-------------|
| 1. DNS / routing | ping | wrong hostname, DNS, routing |
| 2. TCP port 5432 | nc / Test-NetConnection | firewall, `listen_addresses`, wrong port |
| 3. Server accepts | pg_isready | server down/starting, connection limit |
| 4. Login + DB | psql | password, `pg_hba.conf`, missing database |

> **ping ≠ database reachable**: ICMP is often blocked while 5432 is open (and
> vice versa). Ping only proves name resolution and basic routing — always
> test the port too.

### Linux

```bash
ping -c3 pg.example.com                                   # layer 1
nc -vz pg.example.com 5432                                # layer 2
pg_isready -h pg.example.com -p 5432                      # layer 3
psql "host=pg.example.com port=5432 dbname=openfire user=openfire sslmode=require" \
  -c 'select version();'                                  # layer 4
```

`pg_isready`/`psql` come with the client package: `dnf install postgresql`
(RHEL) / `apt install postgresql-client` (Debian). No `nc`? Bash can do it:
`timeout 3 bash -c '</dev/tcp/pg.example.com/5432' && echo open`.

### Windows (PowerShell)

```powershell
Test-Connection pg.example.com -Count 3                   # layer 1 (= ping)
Test-NetConnection pg.example.com -Port 5432              # layer 2 (TcpTestSucceeded: True)
pg_isready -h pg.example.com -p 5432                      # layer 3
psql -h pg.example.com -p 5432 -U openfire -d openfire -c "select version();"   # layer 4
```

`pg_isready`/`psql` ship with the [PostgreSQL installer](https://www.postgresql.org/download/windows/)
("Command Line Tools" component) — add `C:\Program Files\PostgreSQL\<ver>\bin`
to `PATH`.

### From inside the cluster

What matters for the chart is reachability **from the openfire namespace**, not
from your workstation (different network, different firewall rules):

```bash
oc run pg-check --rm -it --restart=Never -n openfire \
  --image=registry.access.redhat.com/ubi9/ubi-minimal:9.8 -- \
  bash -c 'timeout 3 bash -c "</dev/tcp/pg.example.com/5432" && echo OPEN || echo CLOSED'
```

If that says OPEN but the Openfire pod still can't connect, check the
credentials path instead ([debugging.md](debugging.md),
[secret-rotation.md](secret-rotation.md)) — and remember the DB password is
injected on **first boot only**.

## LDAP / Active Directory

Same layered approach as PostgreSQL: reach the DC → bind as the service
account → run the **actual search filter**. Test the filter *before* deploying
— it decides who can log in ([values.yaml](../charts/openfire/values.yaml)
`auth.ldap.searchFilter`).

### Linux (`ldapsearch` from `openldap-clients` / `ldap-utils`)

```bash
nc -vz dc1.example.com 636                                # LDAPS port

# Bind as the service account (proves DN + password)
ldapsearch -H ldaps://dc1.example.com:636 \
  -D "CN=svc-openfire,OU=Service,DC=example,DC=com" -W \
  -b "OU=Users,DC=example,DC=com" -s base "(objectClass=*)" dn

# Run the ACTUAL filter for a known user ({0} replaced by the username)
ldapsearch -H ldaps://dc1.example.com:636 \
  -D "CN=svc-openfire,OU=Service,DC=example,DC=com" -W \
  -b "OU=Users,DC=example,DC=com" \
  "(&(sAMAccountName=jsmith)(!(userAccountControl:1.2.840.113556.1.4.803:=2)))" \
  sAMAccountName userAccountControl
```

What to verify: an **enabled** user returns exactly one entry; a **disabled**
user returns nothing (that's the point of the filter); with a `memberOf`
clause, a non-member returns nothing. If TLS trust fails, point the client at
your CA (`LDAPTLS_CACERT=ca.crt ldapsearch …`) — use `LDAPTLS_REQCERT=never`
only for a quick connectivity test, never as a fix.

### Windows (PowerShell, RSAT AD module)

```powershell
Test-NetConnection dc1.example.com -Port 636
(Get-ADUser jsmith).Enabled                               # true/false
# Run the actual filter -- returns the user only if the gate would pass:
Get-ADUser -LDAPFilter '(&(sAMAccountName=jsmith)(!(userAccountControl:1.2.840.113556.1.4.803:=2)))'
```

## TLS certificate inspection

Order → deploy → **verify what is actually served**
(companion to [tls.md](tls.md)):

```bash
# Direct TLS (5223): subject, issuer, validity, SANs
openssl s_client -connect chat.example.com:5223 -servername chat.example.com </dev/null 2>/dev/null \
  | openssl x509 -noout -subject -issuer -dates -ext subjectAltName

# STARTTLS on 5222 (openssl negotiates the XMPP stream itself)
openssl s_client -connect chat.example.com:5222 -starttls xmpp -name chat.example.com </dev/null 2>/dev/null \
  | openssl x509 -noout -dates

# Full presented chain (leaf + intermediates -- root should NOT be served)
openssl s_client -connect chat.example.com:5223 -showcerts </dev/null

# Expiry guard: exit code 1 if the cert expires within 30 days
openssl s_client -connect chat.example.com:5223 </dev/null 2>/dev/null \
  | openssl x509 -noout -checkend 2592000

# What's in the pod keystore
oc exec deployment/<release>-openfire -n openfire -- \
  keytool -list -keystore /opt/openfire/resources/security/keystore -storepass "$KEYSTORE_PASS"
```

**Windows:** `certutil -dump server.crt` decodes a certificate file; for live
endpoints use the browser padlock (routes) or `openssl.exe` — it ships with
Git for Windows (`C:\Program Files\Git\usr\bin\openssl.exe`), same commands as
above.

## Kerberos sanity checks

The three things that actually break GSSAPI, in order of likelihood:

```bash
# 1. TIME SKEW -- Kerberos fails silently beyond 5 minutes
chronyc tracking                            # Linux ("System time" offset)

# 2. KDC reachable
nc -vz dc1.example.com 88

# 3. Keytab is valid: list entries, then authenticate WITH it
klist -kt openfire.keytab                   # entries + KVNO
kinit -kt openfire.keytab xmpp/chat.example.com@EXAMPLE.COM && klist && kdestroy
```

```powershell
w32tm /query /status                        # 1. time skew
Test-NetConnection dc1.example.com -Port 88 # 2. KDC
setspn -L EXAMPLE\svc-openfire              # 3. SPN registered on the account?
setspn -Q xmpp/chat.example.com             #    ...and held by exactly ONE account
```

Gotchas: a **duplicate SPN** (two accounts holding `xmpp/…`) breaks GSSAPI for
everyone; the SPN host must equal `xmpp.fqdn` exactly; a keytab is invalidated
when the account password changes (KVNO bumps — regenerate with `ktpass`,
[README › Kerberos](../README.md#kerberos-sso-gssapi-against-active-directory)).

## Kubernetes secrets gotchas

**See what is *actually* in a secret** (base64 is encoding, not encryption):

```bash
oc get secret openfire-ldap -n openfire -o jsonpath='{.data.password}' | base64 -d | od -c | tail -2
```

`od -c` exists to expose the classic trap — a **trailing newline** in the
password, which produces "wrong password" errors that look right everywhere
else:

```bash
echo "hunter2"    | ...                       # WRONG: appends \n
printf '%s' "hunter2" | ...                   # correct
oc create secret generic x --from-literal=password=hunter2    # safe (no newline)
# --from-file: careful, most editors add a trailing newline to the file
```

PowerShell equivalent of the trap: `Set-Content` adds a newline — use
`Set-Content -NoNewline` when writing password files.

And the rule this chart lives by: **updating a secret does not update a
running install** — DB/LDAP/admin credentials are injected on first boot only
([secret-rotation.md](secret-rotation.md)).
