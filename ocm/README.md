# OCM and Crossplane

## Create a kind cluster and install OCM manager

### Prerequistes:

- an AWS account with enough permissions to create an AWS cluster
- AWS CLI
- Docker
- Kind
- Kubectl
- helm

### Steps

Clone the repo https://github.com/pdettori/crossplane-examples

Follow instructions in https://open-cluster-management.io/getting-started/quick-start/ to install Hub cluster,
however, in order to expose API server port externally, cluster should be created with config file as follows:

```shell
export HUB_CLUSTER_NAME=hub
export CTX_HUB_CLUSTER=kind-hub
export MANAGED_CLUSTER_NAME=platform-ref-aws-cluster
kind create cluster --config ocm/resources/kind-hub.yaml
```

Download and extract the clusteradm binary, then install the OCM Cluster Manager:

```shell
clusteradm init --context ${CTX_HUB_CLUSTER}
```

Check OCM manager pods are all running

```
kubectl get pods -n open-cluster-management
kubectl get pods -n open-cluster-management-hub
```

Create the boostratp secret used later on by the Crossplane provider to deploy the agent:

```shell
HUB_APISERVER_URL=<public URL for hub API server>   # e.g. HUB_APISERVER_URL=https://18.119.156.43:50443
scripts/kconfig.sh ${HUB_APISERVER_URL} ${MANAGED_CLUSTER_NAME}
```

Update the CA for the kind cluster to add new external IP fpr Hub:

```shell
HUB_EXTERNAL_IP=<public ip for hub server> # e.g. HUB_EXTERNAL_IP=18.119.156.43
scripts/update_ca.sh ${HUB_CLUSTER_NAME} 0.0.0.0 ${HUB_EXTERNAL_IP}
```

Follow instructions in https://crossplane.io/docs (Install & Configure) to install a self hosted Crossplane:

```shell
kubectl create namespace crossplane-system

helm repo add crossplane-stable https://charts.crossplane.io/stable
helm repo update

helm install crossplane --namespace crossplane-system crossplane-stable/crossplane
```

Install the Crossplane CLI:

```shell
curl -sL https://raw.githubusercontent.com/crossplane/crossplane/master/install.sh | sh
```

Install the patched Crossplane configuration for AWS (forked from https://github.com/upbound/platform-ref-aws).
The patch is created from the https://github.com/pdettori/platform-ref-aws fork, and it adds
the installation of the OCM management agent after the EKS cluster is provisioned.

```shell
kubectl crossplane install configuration pdettori/platform-ref-aws:latest
```

Check installed configuration and providers status with:

```shell
kubectl get configurations
kubectl get providers
```

Configure the AWS provider as explained in https://github.com/upbound/platform-ref-aws#configure-providers-in-your-platform

```shell
AWS_PROFILE=default && echo -e "[default]\naws_access_key_id = $(aws configure get aws_access_key_id --profile $AWS_PROFILE)\naws_secret_access_key = $(aws configure get aws_secret_access_key --profile $AWS_PROFILE)" > ${HOME}/creds.conf
```

```shell
kubectl create secret generic aws-creds -n crossplane-system --from-file=key=${HOME}/creds.conf
```

Clone https://github.com/pdettori/platform-ref-aws on another directory, then `cd platform-ref-aws` and:

```shell
kubectl apply -f examples/aws-default-provider.yaml
```

Then, create a network and EKS cluster:

```shell
kubectl apply -f examples/network.yaml 
kubectl apply -f examples/cluster.yaml 
```

Check status of created resources

```shell
kubectl get aws
```

To see the claims status:

```shell
kubectl get network
kubectl get cluster
```

Wait until cluster becomes ready (it may take at least 20 minutes or more):

```shell
kubectl get cluster

NAME                       READY   CONNECTION-SECRET          AGE
platform-ref-aws-cluster   True    platform-ref-aws-cluster   20m
```

Chck status of installed helm releases on EKS cluster:

```shell
kubectl get releases

NAME                                   CHART                   VERSION   SYNCED   READY   STATE      REVISION   DESCRIPTION        AGE
platform-ref-aws-cluster-h6626-blg6q   kube-prometheus-stack   10.0.2    True     True    deployed   1          Install complete   23m
platform-ref-aws-cluster-h6626-dfsc4   klusterlet              0.1.1     True     True    deployed   1          Install complete   23m
```

Get EKS kubeconfig:

```shell
kubectl get secret platform-ref-aws-cluster -o json | jq -r '.data.kubeconfig' | base64 -d > ${HOME}/aws-kubeconfig
```

(Note that auth token expires, so you may need to periodically re-run the above command)
Then check if OCM agent is running:

```shell
kubectl --kubeconfig=${HOME}/aws-kubeconfig get pods -n open-cluster-management-agent

NAME                                             READY   STATUS    RESTARTS   AGE
klusterlet-registration-agent-79b6b9d8f4-68nr7   1/1     Running   2          29m
klusterlet-work-agent-cdf78d9b8-h4d7w            1/1     Running   7          29m
```

Now check certificate signing request from EKS cluster to join OCM hub:

```shell
kubectl get csr

NAME        AGE   SIGNERNAME                                    REQUESTOR                       CONDITION
platform-ref-aws-cluster-8lrsn   6m12s   kubernetes.io/kube-apiserver-client           system:serviceaccount:open-cluster-management:cluster-bootstrap   Pending
```

Approve the request with:

```shell
clusteradm accept --clusters ${MANAGED_CLUSTER_NAME}
```

Now check that cluster has been added to OCM managed clusters:

```shell
kubectl get managedclusters

NAME                       HUB ACCEPTED   MANAGED CLUSTER URLS                                               JOINED   AVAILABLE   AGE
platform-ref-aws-cluster   true           https://platform-ref-aws-cluster.gr7.us-west-2.eks.amazonaws.com   True     True        5m48s
```

Finally, deploy a pod on the managed cluster using OCM. Change directory backm to the `crossplane-examples` repo, then run:

```shell
kubectl apply -f ocm/resources/manifest-work.yaml
```

check status of the remote deployment with:

```shell
kubectl describe manifestwork -n ${MANAGED_CLUSTER_NAME}
```

verify that pod is running on managed cluster:

```shell
kubectl --kubeconfig=${HOME}/aws-kubeconfig get pods
```

