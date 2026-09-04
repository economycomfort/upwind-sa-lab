# Upwind SA Lab

Supporting assets for the Upwind Solutions Architect take-home technical assessment: a Kubernetes lab deploying OWASP Juice Shop, demonstrating three live OWASP Top 10 exploits, and presenting architecture, exploitation, and hardening/detection recommendations.

## Scope

This repo holds the build and presentation assets for that exercise:

- [LAB_GUIDE.md](./LAB_GUIDE.md): architecture, setup, exploitation, hardening, incident response, lessons learned
- Kubernetes manifests (namespace, deployment, service, Gateway API routing, security tooling)
- Architecture diagram (draw.io source + SVG export)
- Presentation slides / speaker notes / screenshots
- Scripts to stand up and tear down the lab (`scripts/`)

## Environment

- **Cloud:** AWS EKS, v1.36, 2x t3.small managed nodegroup
- **Target application:** [OWASP Juice Shop](https://owasp.org/www-project-juice-shop/), intentionally vulnerable, deployed for authorized demonstration purposes only
- **Ingress:** Gateway API via the [AWS Load Balancer Controller](https://kubernetes-sigs.github.io/aws-load-balancer-controller/), fronted by an AWS ALB. Not `ingress-nginx`, that project was officially retired March 31, 2026; see the lab guide's Architecture section for the full reasoning
- **Detection:** [Falco](https://falco.org) (Helm), DaemonSet, one pod per node, eBPF/kernel-level runtime monitoring
- **Cluster is ephemeral**, provisioned for build/rehearsal sessions and torn down between them; nothing here should be treated as a persistent or production environment

## Structure

```
.
├── LAB_GUIDE.md     # Full build/exploit/hardening guide
├── manifests/       # Kubernetes YAML (namespace, deployment, service, gateway, httproute)
├── diagrams/        # Architecture diagram (drawio source + SVG export)
├── presentation/    # Slides, speaker notes, screenshots
├── scripts/         # bootstrap.sh, teardown.sh
└── README.md
```

## Recordings

Exploit demo recordings (video) are too large for this repo and live in Google Drive instead: [click here](https://drive.google.com/drive/folders/1dxv0Gircm8qBIaSG3OWoAefVsSxF1Y1N?usp=sharing)

**NOTE:** Recordings may show OWASP technique codes from 2021 in some places.  These references have been updated in material within this repository, however it wasn't worth re-recording the demo in service of a superficial change.

## Spin up

```bash
./scripts/bootstrap.sh
```

Provisions the cluster, sets up IRSA and the AWS Load Balancer Controller, installs the Gateway API CRDs and Falco, then deploys the app. One-time per cluster, safe to rerun for a fresh rebuild after `teardown.sh`.

What it does, step by step (see the script itself for the exact commands):

1. Provision the EKS cluster (`t3.small` x2, single NAT Gateway)
2. Associate an OIDC provider (needed for IRSA)
3. Create the AWS Load Balancer Controller's IAM policy
4. Create the IRSA service account bound to that policy
5. Install the AWS Load Balancer Controller, then wait for it to actually be ready (its admission webhook needs live pod endpoints before anything else can apply Service/Gateway objects)
6. Install the Gateway API CRDs
7. Install Falco
8. Deploy the app (`kubectl apply -f manifests/`)
9. Wait for the ALB to be provisioned and confirm it's ready

Full walkthrough, including per-exploit demo steps, lives in [LAB_GUIDE.md](./LAB_GUIDE.md).

## Tear down

```bash
./scripts/teardown.sh
```

Run after every recording/rehearsal session, don't leave the lab running.

What it does: removes the app and Gateway resources, waits for the ALB to actually deprovision, uninstalls Falco and the AWS Load Balancer Controller, deletes the cluster, and deletes the Load Balancer Controller's IAM policy (created outside CloudFormation, so it isn't cleaned up by cluster deletion alone).

Verify no orphaned load balancers remain in the AWS console after teardown regardless, the AWS Load Balancer Controller usually cleans these up on `Gateway` deletion, but confirm before walking away.

## Status

Ingress re-architected: `ingress-nginx` (originally used) was found to be officially retired as of March 31, 2026. Migrated to Gateway API via the AWS Load Balancer Controller; rebuilt and validated end to end.

- [x] A01:2025 Broken Access Control (IDOR via basket ID), demoed and recorded (see Recordings)
- [x] A05:2025 Injection (SQL injection login bypass), demoed and recorded (see Recordings)
- [x] A02:2025 Security Misconfiguration (exposed /ftp directory, plus a bonus null-byte extension-filter bypass), demoed and recorded (see Recordings)

Recordings remain valid despite the ingress migration: all three exploits demonstrate application-layer behavior via curl/browser against the app itself, they don't depend on or showcase the ingress mechanism, only the LB hostname changed.

Architecture diagram updated to reflect the current ingress path (t3.small, Gateway API / AWS Load Balancer Controller). Bootstrap/teardown steps converted into scripts (`scripts/bootstrap.sh`, `scripts/teardown.sh`).

Deck finalized, demos recorded, and the cluster has been torn down. This repo is at its final version.

## AI Disclosure from the Author
AI ([Claude](https://claude.ai) Sonnet 5 and Haiku 5) was used during the creation, test, and documentation of this lab.  

AI is a powerful tool, and I am open about its use:

- Distilling lab requirements into mappable demos
- Help with crafting and validating repeatable lab setup/teardown (with significant iteration)
- Understanding k8s concepts ("Teach me about DaemonSets and provide a self-guided demo using `kind`")
- Critiquing early lab design
- Distilling scratch notes from testing and folding into the overall lab plan.
- Documentation edits, formatting, wording, and cleanup.
- Creating a "branding feel" for the presentation
- Scripting advice ("What's the best way to obfuscate my AWS Account ID from bootstrap.sh before its pushed to Github?")
- Help with analyzing transcripts for feedback on flow, content, and opportunities to improve.

AI cannot replace concept mastery or fill in for decades of technology consultation and field pre-sales experience to a technically adept market.  However, AI enables me to deliver an uplevelled deliverable in comparison to what would be provided without its use, and on a much quicker timeframe.  With this, I acknowledge that the end result is mine, and mistakes in its output are mine, and that I have done as much due diligence as possible to ensure quality output that represents my skillset.

It's with this mindset that I approach the use of AI as a tool in my bag, and I would hope that other practitioners are viewing its use within similar constraints. 
