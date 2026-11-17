#!/bin/sh
# Encrypt or decrypt the private keys of the identities (identities/*/*.key.pem), with age.
#   ./keys.sh seal   encrypt each key to every recipient of recipients.txt: <key>.age, to commit
#   ./keys.sh open   decrypt each <key>.age, with the age private key from $AGE_KEY (its content)
#                    or from the file $AGE_KEY_FILE
#
# Only the identities' keys travel, encrypted. The CA keys (root/private, intermediate/private)
# are never committed, in clear or encrypted: they stay on their machine.
#
# Runs inside a temporary client container (age, OpenSSL): nothing to install.

if [ "$1" != "--in" ]; then
  case "$1" in seal|open) ;; *) echo "usage: $0 seal|open" >&2; exit 2 ;; esac
  cd "$(dirname "$0")" || exit 2
  if podman-compose --version >/dev/null 2>&1; then compose="podman-compose"; elif docker compose version >/dev/null 2>&1; then compose="docker compose"; else compose="docker-compose"; fi
  set -- "$1"
  if [ -n "$AGE_KEY_FILE" ]; then
    exec $compose run --rm --no-deps -T -v "$PWD:/lab" -v "$AGE_KEY_FILE:/run/age.key:ro" client sh /lab/keys.sh --in "$1"
  fi
  exec $compose run --rm --no-deps -T -v "$PWD:/lab" -e "AGE_KEY=$AGE_KEY" client sh /lab/keys.sh --in "$1"
fi

cd /lab || exit 2
case $2 in
  seal)
    n=$(grep -c '^age1' recipients.txt)
    if [ "$n" -lt 3 ]; then
      echo "recipients.txt lists $n keys, 3 needed: the trainer's, the CI's (age-keygen -y ci.key) and yours" >&2
      exit 1
    fi
    for k in identities/*/*.key.pem; do
      [ -f "$k" ] || continue
      age -R recipients.txt -o "$k.age" "$k" && echo "sealed  $k.age  (for $n recipients)"
    done
    ;;
  open)
    if [ -n "$AGE_KEY" ]; then
      printf '%s\n' "$AGE_KEY" > /tmp/age.key && id=/tmp/age.key
    elif [ -f /run/age.key ]; then
      id=/run/age.key
    else
      echo "no age private key: set AGE_KEY (its content) or AGE_KEY_FILE (its path)" >&2
      exit 1
    fi
    for f in identities/*/*.key.pem.age; do
      [ -f "$f" ] || continue
      age -d -i "$id" -o "${f%.age}" "$f" && chmod 600 "${f%.age}" && echo "opened  ${f%.age}"
    done
    ;;
esac
