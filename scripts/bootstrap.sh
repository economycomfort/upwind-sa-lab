#!/bin/bash
#
# https://github.com/economycomfort/upwind-sa-lab/scripts/bootstrap.sh
#
# Spins up Upwind Security lab in AWS via `eksctl`.
# Witten by 100% human David Brooks <d@vhf.sh>
#
set -e

CLUSTER_NAME="upwind-lab"
AWS_ACCOUNT_ID=228114682030
AWS_REGION="us-east-1"
NODE_SIZE="t3.small"
NODE_POOL=2
KUBE_VERSION="1.36"

### Check for correct tooling
tooling=(eksctl curl aws helm kubectl)
for t in "${tooling[@]}"; do
  if ! which "$t" >/dev/null 2>&1; then
    echo "$t not found in \$PATH.  Is it installed?"
    exit 1
  fi
done

### Check for manifests
if [ ! -d manifests ]; then
  echo "No manifests directory found."
  exit 1
fi

echo "+++ STEP 1: Provisioning cluster ${CLUSTER_NAME}."
eksctl create cluster \
  --name ${CLUSTER_NAME} --region ${AWS_REGION} --version ${KUBE_VERSION} \
  --nodegroup-name standard-workers --node-type ${NODE_SIZE} --nodes $NODE_POOL --managed \
  --vpc-nat-mode Single

echo "+++ STEP 2: Configuring OIDC provider (needed for IRSA)."
eksctl utils associate-iam-oidc-provider \
  --cluster ${CLUSTER_NAME} --region ${AWS_REGION} --approve

echo "+++ STEP 3: Creating Load Balancer Controller's IAM policy."
curl -o iam-policy.json https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy.json
aws iam create-policy \
  --policy-name AWSLoadBalancerControllerIAMPolicy \
  --policy-document file://iam-policy.json

echo "+++ STEP 4: Create the IRSA service account bound to the Load Balancer's IAM policy."
eksctl create iamserviceaccount \
  --cluster ${CLUSTER_NAME} --region ${AWS_REGION} \
  --namespace kube-system --name aws-load-balancer-controller \
  --attach-policy-arn arn:aws:iam::${AWS_ACCOUNT_ID}:policy/AWSLoadBalancerControllerIAMPolicy \
  --approve

echo "+++ STEP 5: Install the AWS Load Balancer Controller."
helm repo add eks https://aws.github.io/eks-charts
helm repo update
helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  --namespace kube-system \
  --set clusterName=${CLUSTER_NAME} \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller

echo "+++ STEP 6: Install the Gateway API CRDs"
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.1.0/standard-install.yaml

echo "+++ STEP 7: Install Falco (eBPF + kernel runtime detection)"
helm repo add falcosecurity https://falcosecurity.github.io/charts
helm repo update
helm install falco falcosecurity/falco \
  --namespace security-tooling --create-namespace \
  --set tty=true

echo "+++ STEP 8: Deploy the app"
kubectl apply -f manifests/

echo "+++ STEP 9: Confirm the ALB is provisioned (can take a minute or two)"
kubectl wait --for=condition=Programmed gateway/juice-shop-gateway -n juice-shop --timeout=300s
kubectl get gateway juice-shop-gateway -n juice-shop


echo "Done!"
