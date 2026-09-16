#!/usr/bin/env bash
#
# Generates a private key and a certificate signing request for submission to
# the enterprise CA.
#
# Usage:  sudo ./make-csr.sh [fqdn]

set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "must run as root" >&2; exit 1; }

FQDN="${1:-servername.example.com}"
KEY="/etc/ssl/private/servername.key"
CSR="/etc/ssl/certs/servername.csr"

ORG="${ORG:-Example Organisation}"
OU="${OU:-IT}"
COUNTRY="${COUNTRY:-NL}"

[[ -f $KEY ]] && { echo "$KEY already exists — refusing to overwrite" >&2; exit 1; }

umask 077
openssl req -new -newkey rsa:3072 -nodes \
    -keyout "$KEY" \
    -out "$CSR" \
    -subj "/C=${COUNTRY}/O=${ORG}/OU=${OU}/CN=${FQDN}" \
    -addext "subjectAltName=DNS:${FQDN}" \
    -addext "keyUsage=critical,digitalSignature,keyEncipherment" \
    -addext "extendedKeyUsage=serverAuth"

chmod 0600 "$KEY"
chmod 0644 "$CSR"

cat <<MSG

Key: $KEY  (0600, never leaves this host)
CSR: $CSR

Submit the CSR to the enterprise CA, then install the issued certificate as:

    /etc/ssl/certs/servername.fullchain.pem

IMPORTANT — that file must contain the leaf certificate FOLLOWED BY the
intermediate chain, in that order. A leaf-only file works in browsers that
already cached the intermediate and fails everywhere else, which presents as
an intermittent, hard-to-reproduce trust error.

Verify before reloading nginx:

    openssl crl2pkcs7 -nocrl -certfile /etc/ssl/certs/servername.fullchain.pem \\
      | openssl pkcs7 -print_certs -noout

That should list at least two certificates: the leaf, then the issuer.

Check that the key matches the certificate:

    openssl x509 -noout -modulus -in /etc/ssl/certs/servername.fullchain.pem | openssl md5
    openssl rsa  -noout -modulus -in $KEY | openssl md5

Renewal is manual — there is no ACME on this network. Record the expiry date
in a shared calendar with a month of lead time:

    openssl x509 -noout -enddate -in /etc/ssl/certs/servername.fullchain.pem

MSG
