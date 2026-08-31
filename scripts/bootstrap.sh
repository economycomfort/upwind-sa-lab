#!/bin/bash
#
# https://github.com/economycomfort/upwind-sa-lab/scripts/bootstrap.sh
#
# Spins up Upwind Security lab in AWS via `eksctl`.
# Witten by 100% human David Brooks <d@vhf.sh>
#
set -e

export AWS_PAGER=""

CLUSTER_NAME="upwind-lab"
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
AWS_REGION="us-east-1"
NODE_SIZE="t3.small"
NODE_POOL=2
KUBE_VERSION="1.36"
GATEWAY_API_VERSION="v1.6.1"

#echo "DEBUG: $AWS_ACCOUNT_ID"
#exit 0

color='\e[1;33m' # bright yellow
nocolor='\e[0m'

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

echo -e "${color}+++ STEP 1: Provisioning cluster ${CLUSTER_NAME}${nocolor}"
eksctl create cluster \
  --name ${CLUSTER_NAME} --region ${AWS_REGION} --version ${KUBE_VERSION} \
  --nodegroup-name standard-workers --node-type ${NODE_SIZE} --nodes $NODE_POOL --managed \
  --vpc-nat-mode Single

echo -e "${color}+++ STEP 2: Configuring OIDC provider (needed for IRSA)${nocolor}"
eksctl utils associate-iam-oidc-provider \
  --cluster ${CLUSTER_NAME} --region ${AWS_REGION} --approve

echo -e "${color}+++ STEP 3: Creating Load Balancer Controller's IAM policy${nocolor}"
curl -o iam-policy.json https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy.json
aws iam create-policy \
  --policy-name AWSLoadBalancerControllerIAMPolicy \
  --policy-document file://iam-policy.json
rm -f iam-policy.json

echo -e "${color}+++ STEP 4: Create the IRSA service account bound to the Load Balancer's IAM policy${nocolor}"
eksctl create iamserviceaccount \
  --cluster ${CLUSTER_NAME} --region ${AWS_REGION} \
  --namespace kube-system --name aws-load-balancer-controller \
  --attach-policy-arn arn:aws:iam::${AWS_ACCOUNT_ID}:policy/AWSLoadBalancerControllerIAMPolicy \
  --approve

echo -e "${color}+++ STEP 5: Install the Gateway API CRDs${nocolor}"
# Must happen BEFORE the controller is installed
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml

echo -e "${color}+++ STEP 6: Install the AWS Load Balancer Controller${nocolor}"
helm repo add eks https://aws.github.io/eks-charts
helm repo update
helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  --namespace kube-system \
  --set clusterName=${CLUSTER_NAME} \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller

echo -e "${color}+++ STEP 6b: Waiting for the controller to be ready${nocolor}"
kubectl -n kube-system rollout status deployment/aws-load-balancer-controller --timeout=180s

echo -e "${color}+++ STEP 7: Install Falco (eBPF + kernel runtime detection)${nocolor}"
helm repo add falcosecurity https://falcosecurity.github.io/charts
helm repo update
helm install falco falcosecurity/falco \
  --namespace security-tooling --create-namespace \
  --set tty=true

echo -e "${color}+++ STEP 8: Deploy the app${nocolor}"
# manifests/ includes, in apply order: namespace, deployment, service,
# GatewayClass, TargetGroupConfiguration, LoadBalancerConfiguration, Gateway,
# HTTPRoute.
kubectl apply -f manifests/

echo -e "${color}+++ STEP 9: Confirm the ALB is provisioned (can take a few minutes)${nocolor}"
kubectl wait --for=condition=Programmed gateway/juice-shop-gateway -n juice-shop --timeout=300s
kubectl get gateway juice-shop-gateway -n juice-shop

echo -e "${color}Done!${nocolor}"
shop_url=$(kubectl get gateway juice-shop-gateway -n juice-shop | grep ^juice-shop | awk '{print $3}')
echo "Your Juice Shop URL: http://${shop_url}"
echo "Happy hunting!"
