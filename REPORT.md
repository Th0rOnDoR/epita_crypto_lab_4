# Lab 4 report

Answer from **your** build: every claim points to a file in this repository or to a line in `evidence/`.

## 1. Inventory

| Item                                                                                                 | Key location                                                       | Readable by                                            | Valid until            | Purpose                                                   |
|------------------------------------------------------------------------------------------------------|--------------------------------------------------------------------|--------------------------------------------------------|------------------------|-----------------------------------------------------------|
| Root CA `root/certs/ca.cert.pem` (P-384, self-signed)                                                | `root/private/ca.key.pem`, AES-256 encrypted, `chmod 600`, dir 700 | only me                                                | 2046-11-12 (20 y)      | signs the issuing CA and the root CRL                     |
| Issuing CA `intermediate/certs/int.cert.pem` (P-384, serial 1000, pathlen 0)                         | `intermediate/private/int.key.pem`                                 | the `issuing-ca` container                             | 2036-11-14 (10 y)      | signs server/client certs, publishes the intermediate CRL |
| Server cert `identities/www/www.cert.pem` (P-256, serial 1000, serverAuth, SAN `www.lab.internal`)   | `identities/www/www.key.pem`, sealed as `.age`                     | nginx only at runtime; age recipients: trainer, CI, me | 2027-02-15 (90 d)      | TLS for `www.lab.internal`                                |
| Client certs `identities/{alice,bob,billing}/*.cert.pem` (P-256, clientAuth, SANs)                   | `identities/<u>/<u>.key.pem`, `.age` sealed                        | owners + age recipients                                | 2027-02-15 (90 d)      | mTLS identity: alice=admin, bob=user, billing=service     |
| Revoked alice certs, serials 1002, 1003 (`R`, keyCompromise)                                         | none deployed                                                      |                                                        | revoked 2026-11-17     | evidence of the incident; in `int.crl.pem`                |
| Cert `CN=evil.example.com` (serial 1001)                                                             | `identities/evil/evil.key.pem`                                     |                                                        | 2027-02-15             | shows nameConstraints: issued, refused at verify          |
| CRLs: `root/crl/root.crl.pem` (180 d), `intermediate/crl/int.crl.pem` (7 d), bundle `crl-bundle.pem` |                                                                    | nginx, client                                          | per `Last/Next Update` | revocation                                                |

**Lifetimes.**
- Root 20 y: it is offline and barely used; rotating a trust anchor is expensive, so it is long. Cost: a leaked root key is dangerous for decades.
- Intermediate 10 y: online but smaller blast radius than the root; when it dies only leaves under it are affected.
- Leaves 90 d: reissue is cheap (~10 min), so short lifetimes cap the damage window of a stolen key. 1 year is too long: a stolen laptop is trusted for a year. 7 days is safer but create signing server availability issues.

## 2. Chain

| Certificate           | Subject -> issuer                   | Constraining extensions                                                                                                                      | What they prevent                                                                                                                      |
|-----------------------|-------------------------------------|----------------------------------------------------------------------------------------------------------------------------------------------|----------------------------------------------------------------------------------------------------------------------------------------|
| Root CA               | `CN=EPITA Lab Root CA`, self-signed | `basicConstraints: CA:TRUE, pathlen:1` (crit), `keyUsage: keyCertSign, cRLSign` (crit)                                                       | no CA below the issuing level; the root key cannot sign anything but certs and CRLs                                                    |
| Issuing CA            | `CN=EPITA Lab Issuing CA` <- root   | `CA:TRUE, pathlen:0` (crit), `keyUsage: digitalSignature, keyCertSign, cRLSign` (crit), `nameConstraints: permitted;DNS:lab.internal` (crit) | the issuing CA cannot delegate (no third tier); it cannot certify `evil.example.com`  nginx refuses it despite it being validly signed |
| `www.lab.internal`    | leaf <- issuing CA                  | `basicConstraints: CA:FALSE`, `keyUsage: digitalSignature` (crit), `EKU: serverAuth` (crit), `SAN: DNS:www.lab.internal`                     | a leaf cannot act as a CA; it cannot be used as a client certificate (curl with it -> 400)                                             |
| alice / bob / billing | leaf <- issuing CA                  | `CA:FALSE`, `keyUsage: digitalSignature` (crit), `EKU: clientAuth` (crit), `SAN: email:...` / `URI:spiffe://lab.internal/billing`            | cannot authenticate a server; role tied to CN, identity to SAN                                                                         |

Read from the certs, not the config:
`openssl x509 -in root/certs/ca.cert.pem -noout -subject -issuer -ext basicConstraints,keyUsage`.

## 3. Key compromise

For the server key, a client key, the intermediate key and the root key: how would you notice,
what stops working or becomes unsafe, how do you recover, how long does it take?

### Server key

- **Notice:** nothing detects it.
- **Unsafe:** anyone with the key can pose as `www.lab.internal` on the internal network (DNS redirect). Clients trust it, but it still cannot impersonate a client (no clientAuth). Past sessions stay unreadable: TLS 1.3 has forward secrecy.
- **Recover:** new key + CSR -> sign in issuing-ca. Revoking the old serial works only for clients that check the CRL;
- **Time:** ~10 min to reissue; the stolen cert is usable until revoked or expired, at most 90 days.

### Client key

- **Notice:** unusual API calls in `docker compose logs -f api`, or a successful impersonation report. Same gap as the server: no detection, only logs.
- **Unsafe:** key + cert = full access to the API with that role (alice can reach `/admin`).
- **Recover:** revoke serial (`openssl ca -revoke`), regenerate `int.crl.pem`, rebuild `crl-bundle.pem`, restart nginx -> nginx rejects the old cert (400). Then new key + CSR + sign + copy.
- **Time:** ~10 min. This is `broken` -> `fixed` cycle.

### Intermediate key

- **Notice:** certificates appearing in `intermediate/index.txt` that nobody requested; forged certs accepted by nginx.
- **Unsafe:** an attacker can mint any cert within the nameConstraints : impersonate the server or every client. All 6 issued leaves are compromised.
- **Recover:** the root revokes the issuing CA itself (serial 1000) in its CRL; generate a new intermediate key and CSR, sign it with the root, redistribute `ca-chain.pem`, re-enroll every identity. Trust stores must get the new chain.
- **Time:** hours to a day; every leaf must be reissued.

### Root key

- **Notice:** same as above, but at the anchor: a new "root-signed" CA appearing anywhere.
- **Unsafe:** total: the attacker can build their own issuing CA and forge everything; the whole chain of trust is dead.
- **Recover:** there is no fix, only a rebuild: new root, new intermediate, reissue everything, replace the root cert in every trust store, laptop, and container.
- **Time:** days. That is why the root is offline, stopped after phase 2, encrypted, with the passphrase held by one person.

## 4. Operational gaps

search answer to those questions/weaknesses

- the root key's passphrase: where is it, who knows it? What if that person leaves the company?
  - It's pretty easy : the passphrase lives in my mind. But i'm the company so i can't leave so it's not an issue. In a real case, might be better to have a very long one (not a simple "pass"), have as few people as possible use/manipulate it and store it in a bank. A different one than the one storing the certificate probably.
- the CRL expires after 7 days: what happens on day 8, and who regenerates it?
  - Nginx stops working i think, the CRL is "too" old and everything become untrust ?
- the lab root is in no trust store: how would every laptop, server and container get it?
  - It depends, you can add it. Either by giving it away and asking people to add it themself or just using ansible/GPO.
- the intermediate's key is not encrypted, unlike the root's. Search how it would be possible to use KMS for intermediate issuing CA.
  - Using an HSM : API calls to sign a certificate, nothing more, nothing less : completely separate server, with firewall etc...
- the certificate is valid 90 days (default_days). Justify the number in REPORT.md, section 1.
  - it's the one with put in the conf. 7 Days would be better, but require a stronger architecture on that side, as the request flow could be way bigger in big cases like OVH. Here it's just a lab : it's an example.

## 5. Importants notes

The `checks.sh` was edited to allow trash content in the CRL : i revoked two certificate from Alice (1002 & 1003).
All scripts were edited to support podman-compose.