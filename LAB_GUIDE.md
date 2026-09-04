# Upwind SA Lab Guide

Build guide for the Upwind Solutions Architect take-home technical assessment: a Kubernetes lab deploying OWASP Juice Shop, demonstrating three live OWASP Top 10 exploits, and covering architecture, exploitation, and hardening/detection recommendations. See `Upwind-SA-Tech-Assessment (1).pdf` (assignment brief, not included in this repo) for the original scope.

This guide is intended to stay current with the present state of the lab. It was built over iteration, test build/teardown cycles, and repeated runs through the exploitation steps, not written up in advance, then followed.

## Architecture

**Cloud: AWS EKS.** Most enterprise-credible, matches Upwind's AWS Security Hub partnership, and provides IAM/VPC/IRSA talking points relevant to the SA role.

**Tear the cluster down after recording/rehearsing.** A live Juice Shop instance is an internet-facing vulnerable app and shouldn't stay up longer than needed.

**Topology:**

```
Internet
   │
   ▼
Gateway API (AWS Load Balancer Controller) -> AWS ALB
   │
   ▼
Namespace: juice-shop
   ├─ Deployment: juice-shop (OWASP Juice Shop container)
   ├─ Service: juice-shop-svc (ClusterIP)
   └─ (optional) NetworkPolicy restricting egress
   │
   ▼
Namespace: security-tooling
   └─ DaemonSet: Falco, runtime detection, reads kernel/eBPF events
```

This is the namespace-level view. The presentation diagram (`diagrams/architecture.drawio` / `.svg` in the repo) also includes a node/data-plane view (2× `t3.small` managed nodegroup) underneath this logical layer, showing that Falco runs one pod per node while `juice-shop` and the AWS LBC controller land on whichever node the scheduler picks.

**Design tradeoffs** (upfront decisions with real alternatives weighed; see Lessons Learned for things discovered mid-build rather than decided in advance):

| Decision | Choice | Why | Alternative considered |
|---|---|---|---|
| Deployment method | Declarative manifests (`kubectl apply -f manifests/`) | Repeatable, versioned in the repo, gives a concrete artifact to walk through on screen instead of describing a one-off command | Imperative `kubectl create`/`kubectl expose` (faster to type, nothing to show afterward) |
| Infrastructure provisioning tool | `eksctl` (imperative CLI, wrapped in `scripts/bootstrap.sh`/`teardown.sh` for repeatability) | Single-command cluster bring-up with sane EKS defaults, no state file to manage; a fair tradeoff against the declarative-manifests choice above, that principle was applied where it matters (Kubernetes-level app state), not dogmatically to every layer | Terraform (the more literally declarative choice, real value is plan/apply diffing against tracked state for long-lived, multi-environment infrastructure; not much payoff for a lab rebuilt from scratch every session, and a rewrite this close to presenting is unjustified re-verification risk) |
| App exposure | Gateway API via AWS Load Balancer Controller | `kubernetes/ingress-nginx` (originally chosen) was officially retired March 31, 2026, no further releases or CVE fixes; Gateway API is the Kubernetes project's own recommended successor, and AWS LBC is AWS's supported path for it on EKS, provisions an ALB at comparable cost to the NLB `ingress-nginx` was already creating | Cilium Gateway API support (stronger eBPF-narrative tie-in alongside Falco, but requires swapping EKS's default CNI, too much risk/time this close to presenting); NGINX Gateway Fabric (F5's actively-maintained successor to ingress-nginx, kept the nginx behavior/branding but added a second product to learn instead of using AWS's native path) |
| Node instance size | `t3.small` (2 vCPU, 2GB RAM) | Right-sized to actual workload (Juice Shop + Falco + AWS LBC pods comfortably fit within `t3.small`'s pod/IP limits); the real cost drivers for this lab are fixed-rate components (EKS control plane, NAT Gateway, load balancer), not node size, so this is about proportionality, not meaningful savings | `t3.medium` (more headroom, was the original choice); `t3.micro` (rejected, EKS's ENI-based max-pods limit on `micro` is too low to reliably fit `aws-node`, `kube-proxy`, CoreDNS, Falco, AWS LBC, and the app pod on one node) |
| NAT Gateway mode | `--vpc-nat-mode Single` (one shared NAT Gateway instead of one per AZ) | NAT Gateways are a fixed idle cost regardless of node size, this halves that specific line item; app accessibility is unaffected since inbound ALB traffic never routes through NAT, only outbound node traffic (image pulls) does | Default `HighlyAvailable` mode (one NAT per AZ, survives an AZ outage without losing node egress, real HA value in production, but not a meaningful risk for a lab that exists for a few hours and gets torn down) |

## Lab Setup

Primary interface: `scripts/bootstrap.sh` and `scripts/teardown.sh` in the repo (`scripts/`). Everything below is what those two scripts actually do, kept here as reference/explanation, not as a manual alternative to running them.

### Spin up

Clone this repo, then:

```bash
cd ~/upwind-sa-lab
./scripts/bootstrap.sh
```

What it does, in order:

1. **Provision the cluster** (`eksctl create cluster`): AWS EKS 1.36, 2× `t3.small` managed nodegroup, single NAT Gateway.
2. **Associate an OIDC provider** with the cluster, needed for IRSA (IAM Roles for Service Accounts).
3. **Install the Gateway API CRDs** (`Gateway`, `HTTPRoute`, etc., not built into core Kubernetes), before installing the controller in the next step.
4. **Install the AWS Load Balancer Controller**: create its IAM policy, create an IRSA service account bound to that policy, install via Helm, then wait for the controller deployment to actually be ready before anything else touches the cluster.
5. **Install Falco** (Helm), so it's already running and able to alert live before the exploit demos, not set up after the fact.
6. **Deploy the app** (`kubectl apply -f manifests/`): namespace, deployment, service, `GatewayClass`, `TargetGroupConfiguration`, `LoadBalancerConfiguration`, `Gateway`, `HTTPRoute`, applied in that dependency order (numeric filename prefixes, since `kubectl apply -f <dir>` otherwise applies alphabetically).
7. **Confirm the ALB is provisioned** (`kubectl wait --for=condition=Programmed gateway/juice-shop-gateway ...`), can take a few minutes.

**Manifests:** `00-namespace.yaml`, `10-deployment.yaml`, `20-service.yaml`, `25-gatewayclass.yaml`, `28-targetgroupconfig.yaml`, `29-loadbalancerconfig.yaml`, `30-gateway.yaml`, `40-httproute.yaml`.

**Exposure uses Gateway API via the AWS Load Balancer Controller, not `ingress-nginx`.** `kubernetes/ingress-nginx` was officially retired March 31, 2026, no further releases or CVE fixes, so it's no longer a defensible choice to build on. See Architecture's design tradeoffs table for the full reasoning.

**Speaker notes: Gateway API wiring, not shown on the architecture diagram.** The diagram deliberately keeps this at topology level (Gateway API/AWS LBC → ALB), not every object involved. Worth having ready verbally if design questions come up, or as a footnote/aside rather than its own slide:
- `GatewayClass` (`25-gatewayclass.yaml`) tells Kubernetes which controller owns Gateway objects referencing it, `controllerName: gateway.k8s.aws/alb` is what tells the AWS Load Balancer Controller "this one's mine."
- `TargetGroupConfiguration` (`28-targetgroupconfig.yaml`) and `LoadBalancerConfiguration` (`29-loadbalancerconfig.yaml`) are AWS-specific CRDs that carry settings classic `Ingress` would have expressed as `alb.ingress.kubernetes.io/*` annotations, target-type (`ip` vs. `instance`) and scheme (`internet-facing` vs. `internal`). Gateway API has no vendor-neutral way to express these, so each implementation defines its own config CRDs; annotations don't carry over.
- These aren't optional extras, without them the ALB defaults to instance-mode targeting, which requires a `NodePort`/`LoadBalancer` Service. Our `ClusterIP` Service would fail to attach at all.
- Good one-line summary if asked "why does Gateway API need three extra objects just to expose one app": Gateway API standardizes routing (`Gateway`, `HTTPRoute`), but infrastructure-level knobs like load balancer scheme and target type are inherently cloud-specific, so every implementation (AWS, GCP, Cilium, etc.) still needs its own config CRDs for that part.

To redeploy after any manifest change without a full rebuild: `kubectl apply -f manifests/` again, it's idempotent.

### Tear down

```bash
./scripts/teardown.sh
```

Run after every recording/rehearsal session, don't leave the lab running. What it does: removes the app and Gateway resources, waits for the ALB to actually deprovision before proceeding, uninstalls Falco and the AWS Load Balancer Controller, deletes the cluster, and deletes the Load Balancer Controller's IAM policy (created outside CloudFormation via a raw `aws iam create-policy` call, so it isn't cleaned up by cluster deletion alone, would otherwise break a rerun of `bootstrap.sh` with `EntityAlreadyExists`).

Verify no orphaned load balancers remain in the AWS console after teardown regardless, worth a quick manual check before walking away.

## Exploitation

Juice Shop is built around a challenge scoreboard, so pick exploits that are clean to show live and map directly to named OWASP Top 10 categories. These three give variety (access control, injection, config) without overlapping, and each has a crisp "what an attacker gains" story.

### 1. A01:2025, Broken Access Control (IDOR)

- **What/why:** App trusts a client-supplied ID (basket ID) without verifying the requesting user owns it.
- **Attacker gains:** Read another user's data, classic horizontal privilege escalation.
- **Why it's a good opener:** invisible in the UI, only visible by tracing the actual API call, good setup for "this is why API-level flaws matter even when the app looks fine."

#### Validated demo sequence:
1. Reset Juice Shop to a blank state; create `bob@example.com` and `alice@example.com`.
2. Log in as Bob, add items to his basket. Open dev tools → Network tab, find the `/rest/basket/<id>` request, note his basket ID (`bid`) and grab his token: `localStorage.getItem('token')` in the console.
3. Log in as Alice separately (different window/incognito), add different items, note her `bid` and token the same way.
4. In the terminal: `BOB_TOKEN="<paste>"` and `ALICE_TOKEN="<paste>"`.
5. **Baseline, Bob's own basket with his own token:**
   ```bash
   curl -s http://<your-lb-address>/rest/basket/<bob's bid> \
     -H "Authorization: Bearer $BOB_TOKEN" | jq
   ```
   `UserId` in the response matches Bob, this is the control case.
6. **Baseline, Alice's own basket with her own token**, same idea, confirms her request also behaves normally.
7. **The exploit, Alice's basket ID with Bob's token:**
   ```bash
   curl -s http://<your-lb-address>/rest/basket/<alice's bid> \
     -H "Authorization: Bearer $BOB_TOKEN" | jq
   ```
   Returns Alice's data under Bob's token. The two-baseline-then-exploit sequence makes the mismatch obvious side by side, rather than asking the audience to remember an earlier step.

#### Supporting Notes:
- **Why curl, not the URL bar:** `#/basket` is Angular's client-side route, not the actual data request; the app always fetches the logged-in user's own basket regardless of the URL, so there's no page to point a browser at. "The UI won't show you this, that's the point."
- **Finding `bid` without extra API calls:** it's already in the JWT payload, decode either token directly:
  ```bash
  echo "$BOB_TOKEN" | cut -d. -f2 | tr '_-' '/+' | python3 -c 'import sys, base64, json; s = sys.stdin.read().strip(); s += "=" * (-len(s) % 4); print(json.dumps(json.loads(base64.b64decode(s)), indent=2))'
  ```
- **Bonus finding:** that same decoded payload also has a hashed `password` field, a secondary data-exposure issue worth a mention in the hardening section.
- **Make the mismatch visually obvious:** stage distinctive items in Alice's basket beforehand, products Bob wouldn't plausibly have, so the `Products` array alone reads as "not mine" even without tracking `UserId` closely.
- **Browser-console alternative** to curl, run while still logged in as Bob:
  ```js
  fetch('/rest/basket/<alice\'s bid>', {
    headers: { Authorization: 'Bearer ' + localStorage.getItem('token') }
  }).then(r => r.json()).then(console.log)
  ```

### 2. A05:2025, Injection (SQL injection login bypass)

- **What/why:** Login query concatenates user input directly into SQL instead of using parameterized queries.
- **Attacker gains:** Full account takeover without credentials.
- **Nice contrast with A01:** this one *is* visible in the UI, the logged-in account visibly changes. "This one you can see happen in real time."

#### Validated demo sequence:
1. Reset Juice Shop to default (optional). Confirm no account is logged in.
2. Click Login. In the Email field enter `' or 1=1--`, any text in the password field (won't submit blank), submit.
3. The session is now authenticated as the Admin user (or whichever account was created first), the account indicator visibly changes, that's the "fireworks" moment.
4. Open dev tools → Network tab, click Basket, note the Bearer token from the request.
5. Decode it to prove the takeover:
   ```bash
   echo "$STOLEN_TOKEN" | cut -d. -f2 | tr '_-' '/+' | python3 -c 'import sys, base64, json; s = sys.stdin.read().strip(); s += "=" * (-len(s) % 4); print(json.dumps(json.loads(base64.b64decode(s)), indent=2))'
   ```
   `role: "admin"` in the output is the harder proof beyond a screenshot.

#### Supporting Notes:
- **What's actually happening server-side**, the login query is built by string concatenation:
  ```sql
  SELECT * FROM Users WHERE email = '<input>' AND password = '<hash>'
  ```
  The payload turns it into:
  ```sql
  SELECT * FROM Users WHERE email = '' or 1=1--' AND password = '...'
  ```
  `1=1` is always true, `--` comments out the password check entirely, so the query returns every row and the app authenticates as whichever account comes back first.
- **curl equivalent**, for a terminal-driven demo instead of the form:
  ```bash
  curl -s -X POST http://<your-lb-address>/rest/user/login \
    -H "Content-Type: application/json" \
    -d @- <<'EOF' | jq
  {"email": "' or 1=1--", "password": "irrelevant"}
  EOF
  ```
  Decode the returned `authentication.token` the same way.
- Resetting Juice Shop also clears the Bob/Alice test accounts, recreate them for a combined run with A01.

### 3. A02:2025, Security Misconfiguration

- **What/why:** An exposed directory (`/ftp`) with files that were never meant to be public.
- **Attacker gains:** Information disclosure, potential further foothold.
- **Framing:** no crafted payload needed, just knowing where to look. "The app didn't fail to validate input, it exposed something that should never have shipped."

#### Validated demo sequence:
1. Browse the site normally first, there's no visible link to `/ftp` anywhere. "An attacker doesn't need a bug here, just enumeration."
2. Discovery via `robots.txt`:
   ```bash
   curl -s http://<your-lb-address>/robots.txt
   ```
   Lists `Disallow: /ftp`, ironic since disallowing a path there doesn't restrict access, it just maps out what's sensitive.
3. Browse the directory: `curl -s http://<your-lb-address>/ftp/` (or in the browser). Listing shows files like `package.json.bak`, `coupons_2013.md.bak`, `eastere.gg`, `acquisitions.md`.
4. Try pulling a `.bak` file directly, it's blocked:
   ```bash
   curl -s http://<your-lb-address>/ftp/package.json.bak
   ```
   `403 Error: Only .md and .pdf files are allowed!`, read that message out loud, it discloses the validation rule (an extension allowlist, not a real access restriction).
5. Pull an allowed file instead: `curl -s http://<your-lb-address>/ftp/acquisitions.md`, succeeds, genuinely confidential-sounding content despite the filter. This is the primary finding's "what an attacker gains" story.
6. **Bonus, bypass the extension filter with a null byte:**
   ```bash
   curl -s http://<your-lb-address>/ftp/package.json.bak%2500.md
   ```
   Returns the actual blocked file. Try it against the other blocked files too (`coupons_2013.md.bak%2500.md`, etc.; save binary files with `-o` rather than printing them).

#### Supporting Notes:
- **Why the filter fix was incomplete:** it's a partial mitigation, addressing one flagged file type without fixing the actual problem (the directory shouldn't be public at all). Good talking point for the hardening section.
- **The null-byte reasoning chain** (worth having ready if asked how this bypass was found, it wasn't a guess): suffix-only checks (`endsWith('.md')`) have a well-known historical bypass, null byte injection (CWE-626), since C-backed file calls like `fopen()` treat `0x00` as a string terminator. A raw `%00` gets rejected by the HTTP layer, so the working form is double-encoded, `%2500`. `%25` decodes to `%` at the routing layer, leaving the literal characters `%00` (still passes the `.md` suffix check), then a second, redundant `decodeURIComponent` further down the stack (its own bug class, CWE-172) turns that into an actual null byte before the file read happens.
- Tie back to hardening: this isn't an app-logic bug, it's a deployment/config decision, don't ship debug directories, disable directory listing, don't rely on `robots.txt` for access control.

## Hardening & Detection

The assignment asks for hardening *recommendations*, not a live demo, this section is a talk-through, mapped to each exploit:

| Exploit   | Application fix                                           | K8s / infra control                                               | Detection                                                           |
| --------- | --------------------------------------------------------- | ----------------------------------------------------------------- | ------------------------------------------------------------------- |
| IDOR      | Server-side ownership checks on every object reference    | NetworkPolicy limiting lateral movement if account is compromised | Alert on abnormal sequential ID access patterns in app logs         |
| SQLi      | Parameterized queries / ORM, input validation             | Least-privilege DB service account, secrets not baked into image  | WAF/API-gateway rule on SQL meta-characters in request bodies       |
| Misconfig | Remove debug/verbose error output, restrict exposed paths | Ingress-level path allowlisting, no directory listing             | Alert on requests to non-standard paths (404 spikes, `/ftp` access) |

**Important honesty point for the presentation:** none of the three demoed exploits will actually trigger a default Falco alert. Falco operates at the kernel/syscall layer inside the container runtime, watching process execution, file access, and network syscalls. All three exploits are just normal HTTP requests handled entirely inside the app's own request-handling logic, no unusual process spawned, no unexpected file reads, no privilege escalation. From Falco's point of view they're indistinguishable from legitimate traffic. Worth saying out loud rather than glossing over: "Falco wouldn't catch any of these three as demonstrated, they're application-layer logic flaws. That's the point, runtime/syscall detection is complementary to API-layer controls (WAF, input validation, access-control checks), not a replacement for them." Demonstrating an understanding of a tool's actual boundary is a stronger signal than implying it catches everything.

### Optional: live Falco escalation demo

Not required, the assignment only asks for detection *considerations*, but time permitting, this produces one genuinely live, unstaged alert instead of only talking about detection in the abstract.

Falco is already installed from Lab Setup, running ahead of the exploit demos so it's available if used. Watch alerts live:
```bash
kubectl logs -n security-tooling -l app.kubernetes.io/name=falco -f
```

Frame it explicitly as a hypothetical extension: "if the SQLi had led to further compromise, here's what an attacker gaining a shell looks like to Falco." Exec into the Juice Shop pod to simulate that escalation.

Note: the Juice Shop image ships on a minimal/distroless-style base with no shell binary at all (`kubectl exec ... -- /bin/sh` fails with `stat /bin/sh: no such file or directory`), a real hardening control worth calling out as a positive finding on its own, "notice I can't even pop a shell here, that's the vendor's own container hardening working as intended." Since there's no shell to exec into directly, attach an ephemeral debug container into the pod's process namespace instead, using `busybox` (which does have a shell). `--target` requires an actual running pod name, not the Deployment:
```bash
kubectl debug -it $(kubectl get pods -n juice-shop -l app=juice-shop | grep ^juice | awk '{print $1}') \
  -n juice-shop --image=busybox --target=juice-shop -- sh
```
This is also a better story than a plain `exec` would have been: "an attacker who compromised this specific workload but found no built-in shell needed to bring their own tools," and it's a second hardening talking point for free, `kubectl exec`/`kubectl debug` should be RBAC-restricted so arbitrary users can't attach debug containers to production workloads.

Watch the `stern`/`kubectl logs` window, this should trigger Falco's default **"Terminal shell in container"** rule almost immediately. Optionally also read a sensitive-looking path (e.g. `cat /etc/shadow`) to trigger a second default rule ("Read sensitive file untrusted") for a two-alert moment. Exit the shell (`exit`) once shown.

## Incident Response Walkthrough (Extra Credit)

The assignment asks for a narrated walkthrough, not a live trigger, this is a story to tell, not something to demo. SQLi login bypass is the strongest exploit to use: it's the one with the clearest detection gap to address honestly.

**The narrative, in five beats:**

1. **Detection.** Be upfront about the real gap here rather than glossing over it: the SQLi request itself is an application-layer event, it wouldn't trip Falco, which only sees kernel/syscall activity. In production, detection would come from a WAF or API-gateway rule flagging SQL meta-characters in the request body, or from log-anomaly monitoring on the login endpoint. Falco only enters the picture if the attacker goes further and escalates to actual shell access on the compromised pod, that's a second, later detection opportunity, not the first one.
2. **Triage.** Once alerted, confirm scope fast: which account did the attacker land in (check the token's `role`, admin is worse than a regular user), what data or actions did that session touch, is this still active or a single past event.
3. **Containment.** Rotate any credentials/sessions tied to the compromised account, temporarily block the vulnerable login route at the ingress/Gateway layer if a patch isn't ready immediately, and isolate the pod via NetworkPolicy if there's any sign of further compromise.
4. **Eradication & recovery.** Deploy the actual fix, parameterized queries in place of string concatenation, verify the injection payload no longer works, then restore normal traffic to the route.
5. **Post-incident.** Add a regression test that specifically re-runs the injection payload against CI, turn the detection gap from step 1 into a permanent rule (not just a one-time observation), and write up what happened so the next person doesn't have to rediscover it.

That five-beat shape, detect → triage → contain → recover → learn, is the reusable structure; the SQLi specifics are just the vehicle for telling it concretely instead of abstractly.

## Lessons Learned

Design tradeoffs (upfront decisions with real alternatives weighed) live in Architecture. This section is different: things discovered mid-build, not decided in advance. Good material for a closing slide, this is where "hands-on Kubernetes experience" and "defensive mindset and real-world reasoning" actually show up as lived experience rather than claims.

**Verify tooling is still current before building on it, not after.** The lab was originally built on `ingress-nginx`. Mid-build, discovered it had been officially retired March 31, 2026, no further releases, no CVE fixes. That's not a hypothetical risk, it's a live one: an architecture that was correct when first researched can go stale by the time it's actually presented. Re-architected onto Gateway API via the AWS Load Balancer Controller rather than ship something already deprecated. The broader habit worth stating out loud: re-validate that a reference architecture is still accurate close to delivery, not just at the start of the build.

**Controller feature flags can be silently disabled at startup, with no error.** The AWS Load Balancer Controller checks for the Gateway API CRDs once, at its own process startup, and permanently disables Gateway API support for that process's lifetime if they're missing at that moment. The original build order installed the controller first, then the CRDs. Nothing errored, the controller just ran fine with the feature quietly off. Only a full controller restart after the CRDs existed actually recovered it. Fixed by flipping the order: CRDs before controller.

**A resource stuck "Waiting for controller" may be missing a dependency, not a broken controller.** The `Gateway` manifest referenced a `GatewayClass` by name that nothing had actually created. Kubernetes accepted the object fine, since a `GatewayClass` reference is just a string, not a validated foreign key, and it sat pending indefinitely with no useful error. `kubectl get gatewayclass` showed nothing. Lesson: when a controller-owned object is stuck pending, check its own referenced dependencies exist before assuming the controller itself is broken.

**Ingress annotations don't carry over to Gateway API, and the failure mode looks like something else entirely.** `alb.ingress.kubernetes.io/*` annotations only apply to classic `Ingress` objects; they're silently ignored on `Gateway` resources. Without an explicit target-type, AWS LBC defaulted to instance-mode targeting, which expects a `NodePort`/`LoadBalancer` Service, not the `ClusterIP` one in use, producing a `TargetGroup port is empty` reconcile error that reads like a networking problem, not a configuration-mechanism mismatch. The actual fix required AWS-specific config CRDs (`LoadBalancerConfiguration`, `TargetGroupConfiguration`) referenced via `spec.infrastructure.parametersRef`. Gateway API standardizes routing (`Gateway`, `HTTPRoute`) but deliberately leaves infrastructure-level knobs like load balancer scheme and target type implementation-specific, every vendor needs its own config CRDs for that part.

**"Helm deployed" isn't the same as "pod ready."** The AWS Load Balancer Controller's admission webhook registers as soon as Helm's install is accepted, before the controller pod is actually running. Applying manifests immediately afterward hit `no endpoints available for service`. Fixed with an explicit `kubectl rollout status` wait between install and first use.

**Declarative doesn't mean order-independent.** `kubectl apply -f manifests/` applies files in alphabetical order, not dependency order. A Deployment referencing a not-yet-created namespace failed on the very first full apply. Fixed with numeric filename prefixes. Small, but a good reminder that "declarative" is a guarantee about desired-state convergence, not about the order operations happen in.

## Presentation checklist

- [ ] Architecture diagram (full topology, not a screenshot of `kubectl get all`)
- [ ] Design tradeoffs explained (why this cloud, why this ingress approach, what would change for real production)
- [ ] Live demo x3 (IDOR, SQLi, misconfig), what/why/how/gain for each
- [ ] Hardening recs mapped to each exploit
- [ ] Detection/monitoring shown live if time allows
- [ ] Extra credit IR walkthrough
- [ ] Cluster torn down after rehearsal/recording
