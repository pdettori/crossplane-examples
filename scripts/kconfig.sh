#!/bin/bash
set -e

IMAGE=quay.io/open-cluster-management/registration-operator:latest

if [ -z "$1" ]; then
  echo "Usage: $0  <hub_external_api_server> <managed-cluster-name>"
  exit 1
fi
hub_external_api_server=$1
managed_cluster_name=$2
shift

# this would be available when cluster is created, so it needs updating the secret when the EKS cluster becomes available - To Be Done
# managed_cluster_ip=$(kubectl get secret ${managed_cluster_name}  -o json | jq -r '.data.kubeconfig' | base64 -d | yq -r '.clusters[0].cluster.server')
managed_cluster_ip=https://${managed_cluster_name}.gr7.us-west-2.eks.amazonaws.com
bootstrap_secret=$(kubectl get sa -n open-cluster-management cluster-bootstrap -o json | jq -r '.secrets[0].name')
token=$(kubectl get secret ${bootstrap_secret} -n open-cluster-management -o json | jq -r '.data.token' | base64 -d)
ca=$(kubectl get secret ${bootstrap_secret} -n open-cluster-management -o json | jq -r '.data."ca.crt"')

echo $managed_cluster_ip
echo $token
echo $ca

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: ocm-agent-bootstrap
type: Opaque
stringData:
  values.yaml: |
    Image: ${IMAGE}
    Cluster:
      Name: ${managed_cluster_name}
      APIServer: ${managed_cluster_ip}
    Hub:
      APIServer: ${hub_external_api_server}
      CA: ${ca}
      Token: ${token}
EOF



