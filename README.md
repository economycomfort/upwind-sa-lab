# Upwind SA Lab

Supporting assets for the Upwind Solutions Architect take-home technical assessment: a Kubernetes lab deploying OWASP Juice Shop, demonstrating three live OWASP Top 10 exploits, and presenting architecture, exploitation, and hardening/detection recommendations.

## Scope

This repo holds the build and presentation assets for that exercise:

- Kubernetes manifests (Deployment/Service/Ingress, security tooling)
- Architecture diagram (draw.io source + SVG export)
- Presentation slides / speaker notes / screenshots
- Supporting scripts or configuration used to stand up and tear down the lab

## Environment

- **Cloud:** AWS EKS, v1.36, 2x t3.medium managed nodegroup
- **Target application:** [OWASP Juice Shop](https://owasp.org/www-project-juice-shop/), intentionally vulnerable, deployed for authorized demonstration purposes only
- **Ingress:** ingress-nginx (Helm) fronted by an AWS Elastic Load Balancer
- **Detection:** Falco (Helm), DaemonSet, one pod per node, eBPF/kernel-level runtime monitoring
- **Cluster is ephemeral**, provisioned for build/rehearsal sessions and torn down between them; nothing here should be treated as a persistent or production environment

## Structure

```
.
├── manifests/       # Kubernetes YAML (namespace, deployment, service, ingress)
├── diagrams/        # Architecture diagram (drawio source + SVG export)
├── presentation/    # Slides, speaker notes, screenshots
└── README.md
```

## Status

Build complete. All three exploits demonstrated and recorded:

- [x] A01:2021 Broken Access Control (IDOR via basket ID)
- [x] A03:2021 Injection (SQL injection login bypass)
- [x] A05:2021 Security Misconfiguration (exposed /ftp directory, plus a bonus null-byte extension-filter bypass)

Architecture diagram finalized. Presentation bullets and supporting screenshots drafted.

Remaining: final deck assembly, full rehearsal run-through, cluster teardown after recording.
