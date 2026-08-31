#!/bin/bash
#
# https://github.com/economycomfort/upwind-sa-lab/scripts/teardown.sh
#
# Tears down the Upwind Security lab via `eksctl`.
# Witten by 100% human David Brooks <d@vhf.sh>
#
set -e

export AWS_PAGER=""

CLUSTER_NAME="upwind-lab"
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
AWS_REGION="us-east-1"

#echo "DEBUG: $AWS_ACCOUNT_ID"
#exit 0

color='\e[1;33m'
nocolor='\e[0m'

### Check for correct tooling
tooling=(eksctl helm kubectl)
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

echo -e "${color}+++ STEP 1: Remove app + gateway resources${nocolor}"
kubectl delete -f manifests/

echo -e "${color}+++ STEP 2: Wait for the ALB to be deprovisioned before deleting the cluster${nocolor}"
kubectl wait --for=delete gateway/juice-shop-gateway -n juice-shop --timeout=180s || true

echo -e "${color}+++ STEP 3: Remove Falco and the AWS Load Balancer Controller${nocolor}"
helm uninstall falco -n security-tooling
helm uninstall aws-load-balancer-controller -n kube-system

echo -e "${color}+++ STEP 4: Delete the cluster (also removes the node group and VPC), please be patient!${nocolor}"
eksctl delete cluster --name ${CLUSTER_NAME} --region ${AWS_REGION}

echo -e "${color}+++ STEP 5: Delete the Load Balancer Controller's IAM policy (not tied to the cluster, survives cluster deletion otherwise)${nocolor}"
aws iam delete-policy --policy-arn arn:aws:iam::${AWS_ACCOUNT_ID}:policy/AWSLoadBalancerControllerIAMPolicy

echo -e "${color}Done! Verify no orphaned load balancers remain in the AWS console.${nocolor}"
