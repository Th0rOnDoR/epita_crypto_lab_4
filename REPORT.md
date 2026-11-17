# Lab 4 report

Answer from **your** build: every claim points to a file in this repository or to a line in `evidence/`.

## 1. Inventory

Every key and certificate you created: what it is, algorithm and size, where the key lives, who can read it,
validity, what it is used for.

| Item                                                     | Key location                                               | Readable by                                                                                        | Valid until                                           | Purpose                                                                             |
|----------------------------------------------------------|------------------------------------------------------------|----------------------------------------------------------------------------------------------------|-------------------------------------------------------|-------------------------------------------------------------------------------------|
| root CA, EC P-384, self-signed, `root/certs/ca.cert.pem` | `root/private/ca.key.pem`, encrypted (AES-256, passphrase) | the `root-ca` container (no network); on the host, my user account, but only I know the passphrase | 2046-11-11, 20 years (`openssl x509 -noout -enddate`) | signs the intermediate and the root CRL, nothing else; stopped the rest of the time |

**Lifetimes.** The root lasts 20 years, the intermediate 10, the server and client certificates 90 days.
Justify each number: what would a shorter or a longer lifetime cost you? Why 90 days for the server, and not
1 year, or 7 days?

## 2. Chain

Root, intermediate, leaves, with the extensions that constrain each one (pathlen, nameConstraints, EKU, SAN).

| Certificate | Subject, issuer                                        | Constraining extensions                                                                      | What they prevent                                                                                                                                              |
|-------------|--------------------------------------------------------|----------------------------------------------------------------------------------------------|----------------------------------------------------------------------------------------------------------------------------------------------------------------|
| root CA     | `C=FR, O=EPITA Lab, CN=EPITA Lab Root CA`, self-signed | `basicConstraints: critical, CA:TRUE, pathlen:1`; `keyUsage: critical, keyCertSign, cRLSign` | `pathlen:1`: below the root, one CA level only; a CA signed by the intermediate is refused. `keyUsage`: the root key signs certificates and CRLs, nothing else |

Read them from the certificates, not from the config:
`openssl x509 -in root/certs/ca.cert.pem -noout -subject -issuer -ext basicConstraints,keyUsage`.

## 3. Key compromise

For the server key, a client key, the intermediate key and the root key: how would you notice,
what stops working or becomes unsafe, how do you recover, how long does it take?

### Server key (`identities/www/www.key.pem`)

- How you notice: nothing in this build detects it: no monitoring, no alert. You learn it from outside: the key
  found in a backup, a leak, an intrusion on the host.
- What becomes unsafe: whoever can redirect traffic (DNS, same network) can pose as `www.lab.internal`: clients send
  it their requests and trust its answers. It still cannot reach the API as alice: it has no client key. Past
  sessions stay unreadable: TLS 1.3 key exchange is ephemeral (forward secrecy). Nothing stops working.
- Recovery: new key and CSR in `client`, sign in `issuing-ca`, copy to `identities/www/`, restart nginx. Revoke the
  old serial and publish the CRL, but the clients do not check the server's revocation (`curl` reads no CRL by
  default): the old certificate stays accepted.
- How long: 10 minutes to reissue; the stolen certificate stays usable until it expires, at most 90 days.

### Client key

- How you notice:
- What becomes unsafe:
- Recovery:
- How long:

### Intermediate key

- How you notice:
- What becomes unsafe:
- Recovery:
- How long:

### Root key

- How you notice:
- What becomes unsafe:
- Recovery:
- How long:

## 4. Operational gaps

search answer to those questions/weaknesses

- the root key's passphrase: where is it, who knows it? What if that person leaves the company?
  - It's pretty easy : the passphrase lives in my mind. But i'm the company so i can't leave so it's not an issue. In a real case, might be better to have a very long one (not a simple "pass"), have as few people as possible use/manipulate it and store it in a bank. A different one than the one storing the certificate probably.
- the CRL expires after 7 days: what happens on day 8, and who regenerates it?
  - Nginx stops working i think, the CRL is "too" old and everything become untrust ?
- the lab root is in no trust store: how would every laptop, server and container get it?
  - It depends, you can add it. Either by giving it away and asking people to add it themself or just using ansible/GPO.
- the intermediate's key is not encrypted, unlike the root's. Search how it would be possible to use KMS for intermediate issuing CA.
  -
- the certificate is valid 90 days (default_days). Justify the number in REPORT.md, section 1.
  - it's the one with put in the conf. 7 Days would be better, but require a stronger architecture on that side, as the request flow could be way bigger in big cases like OVH. Here it's just a lab : it's an example.

## 5. Importants notes

The `checks.sh` was edited to allow trash content in the CRL : i revoked two certificate from Alice (1002 & 1003).
All scripts were edited to support podman-compose.