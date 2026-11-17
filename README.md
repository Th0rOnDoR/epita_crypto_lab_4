# Lab 4: an internal PKI end to end

Lab 4 of Applied Cryptography (EPITA), 4 hours. You build a two-tier PKI with the OpenSSL CLI, put a TLS server
in front of an internal API, give certificates to two people and one service, then go through an incident:
a stolen key, a revocation, a new certificate.

Every state you reach is committed and tagged in git: `working`, `broken`, `fixed`. That is what is graded.

## Contents

- [Start](#start) · [The machines](#the-machines) · [Schedule](#schedule)
- [Phase 1 · The CA config file and the offline root](#phase-1--the-ca-config-file-and-the-offline-root)
- [Phase 2 · The issuing CA](#phase-2--the-issuing-ca) · [Phase 3 · The server certificate](#phase-3--the-server-certificate)
- [Phase 4 · Mutual TLS](#phase-4--mutual-tls-tag-working) · [Phase 5 · Break](#phase-5--break-tag-broken) · [Phase 6 · Fix](#phase-6--fix-tag-fixed)
- [Phase 7 · Report](#phase-7--report) · [What you hand in](#what-you-hand-in) · [Troubleshooting](#troubleshooting)

## Start

Needs Docker with Compose (`docker compose`, or the older `docker-compose`). The containers bring OpenSSL 3.5, curl and age:
nothing else to install.

```bash
git clone git@github.com:zesk06/epita_crypto_lab_4.git && cd epita_crypto_lab_4
git remote set-url origin git@github.com:<you>/<your-private-repo>.git   # you hand in through your repo
docker compose up -d --build
docker exec -it pki-lab_root-ca_1 sh        # a shell on one machine, in /pki
```

`nginx` stops at once until phase 3 gives it a certificate: that is expected.

## The machines

| Service      | Role                                       | Network           | Sees                                           |
|--------------|--------------------------------------------|-------------------|------------------------------------------------|
| `root-ca`    | offline root CA, stopped after phase 2     | none              | `root/`, `exchange/`                           |
| `issuing-ca` | intermediate CA: signs servers and clients | none              | `intermediate/`, `exchange/`, `root/certs`     |
| `client`     | workstation: creates keys and CSRs, tests  | frontend          | `identities/`, `exchange/`, CA certificates    |
| `nginx`      | TLS front end for `www.lab.internal`       | frontend, backend | its key and certificate, CA certificates, CRLs |
| `api`        | internal API (`api/app.py`)                | frontend, backend | nothing                                        |

Open a shell on a machine with `docker compose exec -it <service> sh`. Every machine starts in `/pki`, and every
command below is run from there. The shell is `sh`: there is no `{a,b}` expansion, write each path.

**A private key never leaves the machine that created it.** Only CSRs and certificates travel, through `exchange/`.

## Schedule

| Phase | Work                                | Time   | Tag       |
|-------|-------------------------------------|--------|-----------|
| 1     | The CA config file, offline root    | 35 min |           |
| 2     | Issuing CA                          | 25 min |           |
| 3     | Server certificate, nameConstraints | 30 min |           |
| 4     | Mutual TLS in front of the API      | 55 min | `working` |
| 5     | Break: revoke alice                 | 20 min | `broken`  |
| 6     | Fix: reissue alice                  | 20 min | `fixed`   |
| 7     | Report                              | 30 min |           |

---

## Phase 1 · The CA config file and the offline root

### Why a config file

`openssl x509 -req` signs a CSR and forgets it. `openssl ca` keeps a **database**, `index.txt`: one line per
certificate it signs. Without that database there is no revocation and no CRL, and phase 5 needs both.

`openssl ca` reads everything from a configuration file: paths, rules, extensions.
`root/openssl.cnf` and `intermediate/openssl.cnf` are skeletons. **Replace every `TODO`.** Each line has a comment.

| Section                                                                          | What it holds                                                                                                                                                                                                         |
|----------------------------------------------------------------------------------|-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `[ ca ]`, `[ CA_default ]`                                                       | where the CA lives: `database` (`index.txt`), `serial`, `crlnumber`, `new_certs_dir`, its key and certificate; `default_md` (signature hash), `default_days` (validity of what it signs), `policy`, `copy_extensions` |
| `[ policy_* ]`                                                                   | what a subject must contain: `match` (same as the CA), `supplied` (present), `optional`                                                                                                                               |
| `[ req ]` and the subject section                                                | used by `openssl req`; `prompt = no` takes the subject from the file                                                                                                                                                  |
| extension sections (`v3_ca`, `v3_intermediate_ca`, `server_cert`, `client_cert`) | what goes into a certificate; chosen with `-extensions <section>`                                                                                                                                                     |

### Step 1 · Complete `root/openssl.cnf`

Before any command: open `root/openssl.cnf` in your editor, on your machine (the `root-ca` machine sees the same
file as `/pki/root/openssl.cnf`). Replace its seven `TODO`s:

| Where                                      | What to decide                                                 |
|--------------------------------------------|----------------------------------------------------------------|
| `[ CA_default ]` `default_md`              | the hash used in the root's signatures, for a P-384 key        |
| `[ CA_default ]` `default_days`            | how long the intermediate it signs is valid: 10 years, in days |
| `[ root_dn ]` `commonName`                 | the root's name                                                |
| `[ v3_ca ]` `pathlen`                      | how many CA levels may exist below the root                    |
| `[ v3_ca ]` `keyUsage`                     | what the root key may do                                       |
| `[ v3_intermediate_ca ]` `pathlen`         | may the intermediate create another CA?                        |
| `[ v3_intermediate_ca ]` `nameConstraints` | the only DNS names the intermediate may certify                |

A `TODO` left in the file stops OpenSSL, and the error names it (`name=pathlen, value=TODO`).

### Step 2 · Create the root

In `root-ca`:

```bash
mkdir -p root/certs root/crl root/newcerts root/private
chmod 700 root/private
touch root/index.txt
echo 1000 > root/serial
echo 1000 > root/crlnumber
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-384 \
  -aes-256-cbc -out root/private/ca.key.pem # -aes-256-cbc: encrypt the key using passphrase
openssl req -config root/openssl.cnf -key root/private/ca.key.pem \
  -new -x509 -days 7300 -sha384 -extensions v3_ca -out root/certs/ca.cert.pem
openssl x509 -in root/certs/ca.cert.pem -noout -subject -dates -ext basicConstraints,keyUsage
```

The root key is encrypted: you choose a passphrase. Where does it live? Who has it? What happens when the one
person who knows it leaves? (Report, section 4.)

---

## Phase 2 · The issuing CA

### Complete `intermediate/openssl.cnf`

Same work as in phase 1, for the issuing CA. Replace its six `TODO`s:

| Where                                                   | What to decide                                                               |
|---------------------------------------------------------|------------------------------------------------------------------------------|
| `[ CA_default ]` `default_md`                           | the hash used in its signatures of servers, clients and CRLs                 |
| `[ CA_default ]` `default_days`                         | how long server and client certificates are valid. Short: why?               |
| `[ intermediate_dn ]` `countryName`, `organizationName` | its subject: the root's `policy_strict` requires the same values as the root |
| `[ server_cert ]` `extendedKeyUsage`                    | what a server certificate is for                                             |
| `[ client_cert ]` `extendedKeyUsage`                    | what a client certificate is for                                             |

### Key and CSR

In `issuing-ca`: its folders, its key, its CSR.

```bash
mkdir -p intermediate/certs intermediate/crl intermediate/newcerts intermediate/private
chmod 700 intermediate/private
touch intermediate/index.txt
echo 1000 > intermediate/serial
echo 1000 > intermediate/crlnumber
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-384 -out intermediate/private/int.key.pem
openssl req -config intermediate/openssl.cnf -new -key intermediate/private/int.key.pem \
  -out exchange/int.csr.pem
```

In `root-ca`: sign it, and publish the root's CRL (empty for now, valid 180 days).

```bash
openssl ca -config root/openssl.cnf -extensions v3_intermediate_ca -notext \
  -in exchange/int.csr.pem -out exchange/int.cert.pem
cat root/serial          # 1001: the intermediate took 1000, the next certificate gets 1001
openssl ca -config root/openssl.cnf -gencrl -out root/crl/root.crl.pem
# issuer, Last Update and Next Update (180 days later), CRL Number, "No Revoked Certificates."
openssl crl -in root/crl/root.crl.pem -noout -text
cp root/crl/root.crl.pem exchange/
```

In `issuing-ca`: collect and check.

```bash
cp exchange/int.cert.pem intermediate/certs/
cp exchange/root.crl.pem intermediate/crl/
cat intermediate/certs/int.cert.pem root/certs/ca.cert.pem > intermediate/certs/ca-chain.pem
openssl verify -CAfile root/certs/ca.cert.pem intermediate/certs/int.cert.pem
```

### Stop the root

On your machine:

```bash
docker compose stop root-ca
```

The root stays stopped for the rest of the lab. If you need it, you designed something wrong.

---

## Phase 3 · The server certificate

In `client` (the server's key is created here and stays here):

```bash
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out identities/www/www.key.pem
openssl req -new -key identities/www/www.key.pem -subj /CN=www.lab.internal \
  -addext subjectAltName=DNS:www.lab.internal -out exchange/www.csr.pem
```

The SAN comes from the CSR: the issuing CA uses `copy_extensions = copy`, which takes from the CSR only what its
extension section does not set. In `issuing-ca`, read the request before signing it:

```bash
openssl req -in exchange/www.csr.pem -noout -text
openssl ca -config intermediate/openssl.cnf -extensions server_cert -notext \
  -in exchange/www.csr.pem -out exchange/www.cert.pem
openssl ca -config intermediate/openssl.cnf -gencrl -out intermediate/crl/int.crl.pem   # first CRL: empty
```

In `client`:

```bash
cp exchange/www.cert.pem identities/www/
cat identities/www/www.cert.pem intermediate/certs/int.cert.pem > identities/www/www.fullchain.pem
```

The certificate is valid 90 days (`default_days`). **Justify the number** in `REPORT.md`, section 1.

### Deploy and verify

- Complete `nginx/default.conf`
- `docker compose up -d nginx`

```bash
# in client container
openssl s_client -connect www.lab.internal:443 -servername www.lab.internal \
  -CAfile root/certs/ca.cert.pem -verify_hostname www.lab.internal -showcerts </dev/null
#  0 s:CN=www.lab.internal
#  1 s:C=FR, O=EPITA Lab, CN=EPITA Lab Issuing CA
# Verify return code: 0 (ok)

# Testing TLS, then API
curl --cacert root/certs/ca.cert.pem https://www.lab.internal/whoami
# {"error": "no verified client certificate"}
```

The API answers with an error because mutual TLS is not on yet: that is expected.

### nameConstraints, tested

`www.lab.internal` works. The intermediate may only certify names under `lab.internal`: now try a name outside
it. In `client`:

```bash
mkdir -p identities/evil
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out identities/evil/evil.key.pem
openssl req -new -key identities/evil/evil.key.pem -subj /CN=evil.example.com \
  -addext subjectAltName=DNS:evil.example.com -out exchange/evil.csr.pem
```

In `issuing-ca`:

```bash
openssl ca -config intermediate/openssl.cnf -extensions server_cert -notext \
  -in exchange/evil.csr.pem -out exchange/evil.cert.pem
```

It signs. Signing is not the check. In `client`, as any validating client would:

```bash
openssl verify -CAfile root/certs/ca.cert.pem -untrusted intermediate/certs/int.cert.pem exchange/evil.cert.pem
```

Expected: `permitted subtree violation`. This is what makes an internal CA safe to trust: it cannot vouch for a
name outside its domain.

---

## Phase 4 · Mutual TLS (tag `working`)

### Three identities

| Identity | Subject      | SAN                                 | Role in the API      |
|----------|--------------|-------------------------------------|----------------------|
| alice    | `CN=alice`   | `email:alice@lab.internal`          | admin: `/admin`      |
| bob      | `CN=bob`     | `email:bob@lab.internal`            | user: `/whoami` only |
| billing  | `CN=billing` | `URI:spiffe://lab.internal/billing` | service: `/invoices` |

`billing` is a service, not a person: services authenticate with certificates too. The URI SAN is the SPIFFE
format of service meshes, see more on [spiffe.io](https://spiffe.io/). Our nginx passes only the subject, so the
API reads the CN.

In `client`, a key and a CSR for each:

```bash
for u in alice bob billing; do
  mkdir -p identities/$u
  openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out identities/$u/$u.key.pem
done
openssl req -new -key identities/alice/alice.key.pem -subj /CN=alice \
  -addext subjectAltName=email:alice@lab.internal -out exchange/alice.csr.pem
openssl req -new -key identities/bob/bob.key.pem -subj /CN=bob \
  -addext subjectAltName=email:bob@lab.internal -out exchange/bob.csr.pem
openssl req -new -key identities/billing/billing.key.pem -subj /CN=billing \
  -addext subjectAltName=URI:spiffe://lab.internal/billing -out exchange/billing.csr.pem
```

In `issuing-ca`, sign them as clients:

```bash
for u in alice bob billing; do
  openssl ca -config intermediate/openssl.cnf -extensions client_cert -notext \
    -in exchange/$u.csr.pem -out exchange/$u.cert.pem
done
```

In `client`:

```bash
for u in alice bob billing; do cp exchange/$u.cert.pem identities/$u/; done
```

### nginx checks, the API decides

In `nginx/default.conf`, uncomment and complete the phase 4 lines. With the `location` block already there:

```nginx
ssl_client_certificate /etc/nginx/ca/ca-chain.pem;   # client certificates must chain to these
ssl_verify_client on;
ssl_verify_depth 2;

location / {
    proxy_pass http://api:8080;
    proxy_set_header X-Client-Verify $ssl_client_verify;   # SUCCESS
    proxy_set_header X-Client-DN     $ssl_client_s_dn;     # CN=alice
}
```

- nginx does the cryptography: chain, signatures, dates, extended key usage.
- It passes the result to the API in two headers: `X-Client-Verify` (`SUCCESS`) and `X-Client-DN` (`CN=alice,…`).
- The API **authorises**: the CN gives the role (`api/app.py`).
- Testing auth on next step.

### Test matrix

In `client`, for each line (`<u>` = alice, bob or billing):

```bash
curl --cacert root/certs/ca.cert.pem --cert identities/<u>/<u>.cert.pem \
  --key identities/<u>/<u>.key.pem https://www.lab.internal/<path>
# to generate a self-signed certificate for alice
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
  -keyout /tmp/m.key -out /tmp/m.crt -subj /CN=alice -days 1
# to connect with the server's certificate as a client
curl --cacert root/certs/ca.cert.pem --cert identities/www/www.cert.pem \
  --key identities/www/www.key.pem https://www.lab.internal/whoami
```

| Client                                    | Path        | Expected                                 |
|-------------------------------------------|-------------|------------------------------------------|
| no certificate                            | `/whoami`   | 400 No required SSL certificate was sent |
| alice                                     | `/admin`    | 200                                      |
| bob                                       | `/admin`    | 403 forbidden                            |
| billing                                   | `/invoices` | 200                                      |
| a self-signed certificate with `CN=alice` | `/admin`    | 400 The SSL certificate error            |
| the server's certificate (EKU serverAuth) | `/whoami`   | 400 The SSL certificate error            |

### The bypass

The API trusts its headers. Who else can send them? In `client`:

```bash
curl -H 'X-Client-Verify: SUCCESS' -H 'X-Client-DN: CN=alice' http://api:8080/admin
# {"user": "alice", "role": "admin", "path": "/admin"}
```

Admin, without any certificate. **Fix it:** only nginx may reach the API.

- In `docker-compose.yml`, put the `api` service on the `backend` network only.
- `docker compose up -d api`, then `docker compose restart nginx`: nginx kept the API's old address.
- The same curl must now fail: `Could not resolve host: api`.

Header-based identity is safe only if nothing can reach the application without the proxy.

### Before the first tag: encrypted keys and the CI

Each tag you push runs `.github/workflows/check.yml` on GitHub: it decrypts the identities' keys, starts nginx and
the API, and runs `check.sh`. The keys travel encrypted with age (Lab 2), never in clear. Once:

```bash
age-keygen -o ci.key      # the CI's age key; ci.key never leaves your machine (.gitignore)
# no age installed? docker compose run --rm --no-deps -T -v "$PWD:/lab" -w /lab client age-keygen -o ci.key
```

- `recipients.txt` needs 3 public keys (`age1…`): Nicolas's (already there: **keep it**), the CI's (printed above),
  and yours: your Lab 2 key, or a new one with `age-keygen -o ~/.config/age/keys.txt`.
- On GitHub: **Settings → Secrets and variables → Actions → New repository secret**, name `AGE_KEY`,
  value: the content of `ci.key`.

### Tag `working`

```bash
./check.sh working | tee evidence/working.txt     # must end with: 0 failed
./keys.sh seal                                    # encrypt the identities' keys to recipients.txt
                                                  # at least 3 recipients: you, the CI and Nicolas
git status                                        # no private key in clear listed
git add -A && git commit -m "working: PKI, server, mTLS"
git push origin main && git tag working && git push origin working   # the commit first, then the tag: it starts the CI
```

---

## Phase 5 · Break (tag `broken`)

Incident: alice's laptop is stolen, with her private key. Revoke her certificate.

In `issuing-ca`:

```bash
grep CN=alice intermediate/index.txt                    # her serial: the number just before "unknown"
openssl ca -config intermediate/openssl.cnf -revoke intermediate/newcerts/<serial>.pem \
  -crl_reason keyCompromise
openssl ca -config intermediate/openssl.cnf -gencrl -out intermediate/crl/int.crl.pem
openssl crl -in intermediate/crl/int.crl.pem -noout -text
```

In `nginx/default.conf`, uncomment the phase 5 line with `int.crl.pem`. nginx reads CRLs at startup only: publish,
then restart: `docker compose restart nginx`.

```bash
# in client, test alice and bob: <u> = alice, then bob
curl --cacert root/certs/ca.cert.pem --cert identities/<u>/<u>.cert.pem \
  --key identities/<u>/<u>.key.pem https://www.lab.internal/whoami
# alice: 400 The SSL certificate error
# bob:   400 The SSL certificate error
```

Look at what happens to bob, and explain it. Hint: nginx checks revocation at every level of the chain, the client
**and** the intermediate. The fix is one file with both CRLs, in `issuing-ca`:

```bash
cat intermediate/crl/int.crl.pem intermediate/crl/root.crl.pem > intermediate/crl/crl-bundle.pem
```

Point `ssl_crl` to `crl-bundle.pem`, restart nginx. alice must be refused, bob and billing must work.

```bash
./check.sh broken | tee evidence/broken.txt
./keys.sh seal
git add -A && git commit -m "broken: alice revoked"
git push origin main && git tag broken && git push origin broken   # the commit first, then the tag: it starts the CI
```

---

## Phase 6 · Fix (tag `fixed`)

alice gets a **new key**: the stolen one stays stolen. In `client`: a new key and a new CSR, exactly as in phase 4.
In `issuing-ca`: sign it. In `client`: copy the certificate into `identities/alice/`.

No change in nginx: the CRL still lists the old serial, and the new one is not in it. `index.txt` now shows both:
the old certificate `R` (revoked), the new one `V` (valid).

```bash
./check.sh fixed | tee evidence/fixed.txt
./keys.sh seal                                    # alice has a new key: encrypt it too
git add -A && git commit -m "fixed: alice reissued"
git push origin main && git tag fixed && git push origin fixed   # the commit first, then the tag: it starts the CI
```

Revocation does not end the incident. The new certificate and the new key do.

---

## Phase 7 · Report

Complete `REPORT.md` from **your** build: inventory, chain, key compromise, operational gaps.
Every claim points to a file in the repository or a line in `evidence/`.

## What you hand in

Your private repository, with:

| Part                                     | Evidence                                                                                 |
|------------------------------------------|------------------------------------------------------------------------------------------|
| Three tags: `working`, `broken`, `fixed` | `evidence/<tag>.txt`: `check.sh` output, 0 failed                                        |
| The PKI                                  | configuration files, certificates, CRLs, `intermediate/index.txt`                        |
| The identities' keys, encrypted          | `identities/*/*.key.pem.age`, for every key of `recipients.txt`                          |
| No private key in clear                  | no `*.key.pem`, `*.key` or `private/` anywhere in `git log --all`                        |
| The CI                                   | the `check` job is green on each tag (**Actions** tab)                                   |
| The report                               | `REPORT.md`: based on **your** build (files, dates, commands), weaknesses stated clearly |

**A private key in clear in the repository fails the lab** (Lab 2). `.gitignore` excludes `private/`, `*.key.pem`
and `*.key`: never force them in. The CA keys are never committed, not even encrypted: they stay on their machine.
Before each push, check with `git status` and `betterleaks git .`.

## check.sh

```bash
./check.sh working     # or broken, fixed
```

It checks the certificates' extensions, then connects as each client through nginx, and checks that the API
cannot be reached directly. At `broken` and `fixed` it also checks the CRLs and `index.txt`. On a clone without
the private keys, the connection tests are skipped and only the files are checked.

GitHub runs it on each tag, after decrypting the keys. To do the same on any clone (the trainer grades this way):

```bash
AGE_KEY_FILE=~/.config/age/keys.txt ./keys.sh open    # any key listed in recipients.txt
docker compose up -d --build api nginx
./check.sh fixed
```

## Troubleshooting

- **`keys.sh seal`: recipients.txt lists 2 keys, 3 needed:** add the missing one, Nicolas's, the CI's or yours.
  Without the CI's key, the CI cannot decrypt. Without Nicolas's, he cannot grade.
- **No CI run after the tag push:** the workflow and the tag arrived in the same push. Push the tag again:
  `git push origin :refs/tags/<tag> && git push origin <tag>`.
- **The CI says `no identity matched any of the recipients`:** the `AGE_KEY` secret is not a key of
  `recipients.txt`, or the keys were sealed before you added it. Run `./keys.sh seal`, commit, and move the tag:
  `git tag -f <tag> && git push -f origin <tag>`.
- **The CI refuses every client at `broken` or `fixed`, a week later:** the intermediate's CRL expired (7 days).
  Publish a new one and rebuild `crl-bundle.pem` (phase 5), commit, move the tag.
- **nginx does not start, or answers nothing:** `docker compose logs nginx`. It names the line and the file.
- **502 Bad Gateway after changing the API's network:** `docker compose restart nginx`.
- **`Stale file handle`** inside a machine: a folder it mounts (`root/certs`, `intermediate/certs`, …) was deleted
  and created again while it ran. Reattach the machines: `docker compose up -d --force-recreate`. Your files stay.
- **`openssl ca` asks `Sign the certificate? [y/n]`:** answer `y`, twice. Add `-batch` to skip the questions.
- **`/pki/intermediate/serial: No such file or directory`** (or `root/…`): the CA's folders and files were not
  created. Run the `mkdir`, `touch` and `echo` lines of phase 1 or 2.
- **Linux hosts:** files created inside the containers belong to root on the host. If git complains:
  `sudo chown -R "$USER" .`
