#!/bin/bash
set -e

# updates the API certificate with new DNSs and IPs
# 1. fetch CA + existing cert
# 2. extract AltNames and update AltNames
# 3. create new cert
# 4. upload and use it in API pod

if [ -z "$1" ]; then
  echo "Usage: $0 <kind-cluster-name> <old-name> <new-name> [REMOVE <remove-name> ...]"
  exit 1
fi
kube_context=kind-$1
docker_prefix=$1
shift

# extractAltNames: returns unique key=value pairs (DNS:foo\nIP:bar)
function extractAltNames() {
  # input: openssl x509 -in apiserver.crt -text | grep 'DNS:' | tr -d " "
  local raw=$1
  # output: key=value pairs
  (IFS=","
  for an in $raw; do
    if [ "${an/:*/}" == "IPAddress" ]; then
      echo "IP=${an/*:/}"
    else
      echo "${an/:*/}=${an/*:/}"
    fi
  done) | sort | uniq
}

# updateAltName: returns key=value pairs with added/updated value
function updateAltName() {
  # input: key=value pairs
  local alts=$1
  # input: old dns/ip address -> new dns/ip address
  local old=$2
  local new=$3
  # output: same key=value pair incl. new dns/ip address

  (found=0
  IFS="
"
  for a in $alts; do
    if [ "${a/*=/}" == "$old" ]; then
      found=1
      echo "${a/=*/}=$new"
    else
      echo "$a"
    fi
  done
  if [ $found -eq 0 ]; then
    if [ -z "${new/[1-9]*/}" ]; then
      echo "IP=$new"
    else
      echo "DNS=$new"
    fi
  fi)
}

# removeAltName: returns key=value pairs with given value removed if found
function removeAltName() {
  local alts=$1
  local del=$2

  (IFS="
"
  for a in $alts; do
    if [ "${a/*=/}" == "$del" ]; then
      continue
    fi
    echo "$a"
  done)
}

# exportAltnames -> DNS.1-n, IP.1-n
function exportAltNames() {
  local alts=$1

  # DNS.x=

  (dns=0
  IFS="
"
  for a in $alts; do
    if [ "${a/=*/}" == "IP" ]; then
      continue
    fi
    dns=$((dns+1))
    echo "DNS.$dns=${a/*=/}"
  done)
  # IP.x=
  (ips=0
  IFS="
"
  for a in $alts; do
    if [ "${a/=*/}" == "DNS" ]; then
      continue
    fi
    ips=$((ips+1))
    echo "IP.$ips=${a/*=/}"
  done)
}

#######################################################################
# 1. fetch into subdirectory
mkdir -p ./${docker_prefix}; cd ${docker_prefix}
## get CA certificate
docker cp ${docker_prefix}-control-plane:/etc/kubernetes/pki/ca.crt ./
docker cp ${docker_prefix}-control-plane:/etc/kubernetes/pki/ca.key ./
## get API certificate
docker cp ${docker_prefix}-control-plane:/etc/kubernetes/pki/apiserver.crt ./apiserver.crt.bak
docker cp ${docker_prefix}-control-plane:/etc/kubernetes/pki/apiserver.key ./apiserver.key.bak

# 2. extract and update alt names
orig_alts=$(extractAltNames "$(openssl x509 -in apiserver.crt.bak -text | grep 'DNS:' | tr -d " ")")
alts="$orig_alts"
while [ $# -gt 0 ]; do
  if [ $# -lt 2 ]; then
    break
  fi
  old=$1
  new=$2
  shift 2
  if [ "$old" == "REMOVE" ]; then
    alts=$(removeAltName "$alts" "$new")
  elif [ -n "$old" -a -n "$new" ]; then
    alts=$(updateAltName "$alts" $old $new)
  fi
done
echo -e "Alternative names:\n$alts"
if [ "$alts" == "$orig_alts" ]; then
  echo "No change. aborting..."
  exit 0
fi

# 3. create new cert
echo "[req]
req_extensions = v3_req
distinguished_name = req_distinguished_name
[req_distinguished_name]
[v3_req]
basicConstraints = CA:FALSE
keyUsage = nonRepudiation, digitalSignature, keyEncipherment
subjectAltName = @alt_names
[alt_names]
$(exportAltNames "$alts")" > openssl.cnf

# create signing request
openssl genrsa -out apiserver.key 2048
openssl req -new -key apiserver.key -out apiserver.csr -subj "/CN=kube-apiserver" -config openssl.cnf
# sign with CA
openssl x509 -req -in apiserver.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out apiserver.crt -days 365 -extensions v3_req -extfile openssl.cnf

# 4. upload and restart
docker cp apiserver.crt ${docker_prefix}-control-plane:/etc/kubernetes/pki/apiserver.crt
docker cp apiserver.key ${docker_prefix}-control-plane:/etc/kubernetes/pki/apiserver.key
docker exec ${docker_prefix}-control-plane chown root:root /etc/kubernetes/pki/apiserver.crt /etc/kubernetes/pki/apiserver.key
echo "Restarting ${docker_prefix}-control-plane..."
docker restart ${docker_prefix}-control-plane
