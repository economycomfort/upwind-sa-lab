# Upwind SA Lab

Supporting assets for the Upwind Solutions Architect take-home technical assessment: a Kubernetes lab deploying OWASP Juice Shop, demonstrating three live OWASP Top 10 exploits, and presenting architecture, exploitation, and hardening/detection recommendations.

## Scope

This repo holds the build and presentation assets for that exercise:

- Kubernetes manifests (namespace, deployment, service, Gateway API routing, security tooling)
- Architecture diagram (draw.io source + SVG export)
- Presentation slides / speaker notes / screenshots
- Supporting scripts or configuration used to stand up and tear down the lab

## Environment

- **Cloud:** AWS EKS, v1.36, 2x t3.medium managed nodegroup
- **Target application:** [OWASP Juice Shop](https://owasp.org/www-project-juice-shop/), intentionally vulnerable, deployed for authorized demonstration purposes only
- **Ingress:** Gateway API via the [AWS Load Balancer Controller](https://kubernetes-sigs.github.io/aws-load-balancer-controller/), fronted by an AWS ALB. Not `ingress-nginx`, that project was officially retired March 31, 2026; see the lab guide's design decisions log for the full reasoning
- **Detection:** [Falco](https://falco.org) (Helm), DaemonSet, one pod per node, eBPF/kernel-level runtime monitoring
- **Cluster is ephemeral**, provisioned for build/rehearsal sessions and torn down between them; nothing here should be treated as a persistent or production environment

## Structure

```
.
├── manifests/       # Kubernetes YAML (namespace, deployment, service, gateway, httproute)
├── diagrams/        # Architecture diagram (drawio source + SVG export)
├── presentation/    # Slides, speaker notes, screenshots
└── README.md
```

## Spin up

One-time per cluster, then reusable across rebuilds:

```bash
# 1. Provision the cluster
eksctl create cluster \
  --name upwind-lab --region us-east-1 --version 1.36 \
  --nodegroup-name standard-workers --node-type t3.medium --nodes 2 --managed

# 2. Associate an OIDC provider (needed for IRSA)
eksctl utils associate-iam-oidc-provider \
  --cluster upwind-lab --region us-east-1 --approve

# 3. Create the AWS Load Balancer Controller's IAM policy
curl -o iam-policy.json https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy.json
aws iam create-policy \
  --policy-name AWSLoadBalancerControllerIAMPolicy \
  --policy-document file://iam-policy.json

# 4. Create the IRSA service account bound to that policy
eksctl create iamserviceaccount \
  --cluster upwind-lab --region us-east-1 \
  --namespace kube-system --name aws-load-balancer-controller \
  --attach-policy-arn arn:aws:iam::<account-id>:policy/AWSLoadBalancerControllerIAMPolicy \
  --approve

# 5. Install the AWS Load Balancer Controller
helm repo add eks https://aws.github.io/eks-charts
helm repo update
helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  --namespace kube-system \
  --set clusterName=upwind-lab \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller

# 6. Install the Gateway API CRDs
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.1.0/standard-install.yaml

# 7. Install Falco
helm repo add falcosecurity https://falcosecurity.github.io/charts
helm repo update
helm install falco falcosecurity/falco \
  --namespace security-tooling --create-namespace \
  --set tty=true

# 8. Deploy the app
kubectl apply -f manifests/

# 9. Confirm the ALB is provisioned (can take a minute or two)
kubectl get gateway juice-shop-gateway -n juice-shop
```

Full walkthrough, including per-exploit demo steps, lives in the lab guide (vault note, not in this repo).

## Tear down

Run after every recording/rehearsal session, don't leave this running:

```bash
# Remove app + Gateway resources
kubectl delete -f manifests/

# Remove Falco and the AWS Load Balancer Controller
helm uninstall falco -n security-tooling
helm uninstall aws-load-balancer-controller -n kube-system

# Delete the cluster (also removes the ALB/NLB and node group)
eksctl delete cluster --name upwind-lab --region us-east-1
```

Verify no orphaned load balancers remain in the AWS console after teardown, the AWS Load Balancer Controller usually cleans these up on `Gateway` deletion, but confirm before walking away.

## Status

Re-architecting ingress: `ingress-nginx` (originally used) was found to be officially retired as of March 31, 2026. Migrating to Gateway API via the AWS Load Balancer Controller before rebuilding and re-recording.

- [x] A01:2021 Broken Access Control (IDOR via basket ID), demoed and recorded
- [x] A03:2021 Injection (SQL injection login bypass), demoed and recorded
- [x] A05:2021 Security Misconfiguration (exposed /ftp directory, plus a bonus null-byte extension-filter bypass), demoed and recorded
- [ ] Re-record exploit demos against the rebuilt cluster (new ALB address, Gateway API instead of ingress-nginx)

Architecture diagram and presentation bullets drafted, both need a small update to reflect the new ingress path.

Remaining: rebuild cluster on Gateway API, re-verify all three exploits, re-record, final deck assembly, full rehearsal run-through, cluster teardown after recording.
