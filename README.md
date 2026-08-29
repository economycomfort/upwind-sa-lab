# Upwind SA Lab

Supporting assets for the Upwind Solutions Architect take-home technical assessment: a Kubernetes lab deploying OWASP Juice Shop, demonstrating three live OWASP Top 10 exploits, and presenting architecture, exploitation, and hardening/detection recommendations.

## Scope

This repo holds the build and presentation assets for that exercise:

- Kubernetes manifests (Deployment/Service/Ingress, NetworkPolicy, security tooling)
- Architecture diagrams
- Presentation slides / speaker notes
- Supporting scripts or configuration used to stand up and tear down the lab

## Environment

- **Cloud:** AWS EKS
- **Target application:** [OWASP Juice Shop](https://owasp.org/www-project-juice-shop/), intentionally vulnerable, deployed for authorized demonstration purposes only
- **Cluster is ephemeral**, provisioned for build/rehearsal sessions and torn down between them; nothing here should be treated as a persistent or production environment

## Structure

```
.
├── manifests/       # Kubernetes YAML (app, networking, tooling)
├── diagrams/        # Architecture diagrams
├── presentation/    # Slides, speaker notes, exploit walkthrough scripts
└── README.md
```

(Directories created as content is added.)

## Status

Active. Build in progress ahead of presentation to Upwind.
