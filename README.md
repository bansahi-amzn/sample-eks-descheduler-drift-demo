# EKS pod distribution drift demo

Companion repository for the AWS Containers blog post
**"Fix pod distribution drift in Amazon EKS with the Kubernetes descheduler"**.

Reproduces the full experiment: a three-Deployment web fleet (1,000 pods
combined) driven by HPAs under randomized load, each Deployment carrying its
own soft topology spread constraint; a node-availability gap in one AZ
(induced by draining the zone's nodes — `scripts/induce-window.sh` — with an AWS
FIS template as the realistic-interruption variant; see `fis/README-fis.md` for
why a controlled drain is the more predictable instrument against a managed node
group); a control
experiment proving running pods do not relocate when capacity returns; and the
descheduler restoring each workload's configured `maxSkew`.

The experiment runs at two scales with the same manifests:

| | Full-scale | Small-scale |
|---|---|---|
| Fleet | 1,000 pods (500/300/200) | 100 pods (50/30/20) |
| Nodes | 21 × m5.2xlarge (7/AZ), node group `ng-drift-1000` | 3 × m5.2xlarge (1/AZ), node group `ng-drift-100` |
| HPAs | `workload/hpa-1000.yaml` | `workload/hpa-100.yaml` |
| Everything else | identical | identical |

> **Cost warning:** the full-scale run's 21 m5.2xlarge nodes are the dominant
> cost. Estimate with the [AWS Pricing Calculator](https://calculator.aws/),
> run in one sitting, and remove the nodegroup promptly. The small-scale run
> reproduces the same behavior at a fraction of the cost.

## Prerequisites

- An existing Amazon EKS cluster — Kubernetes 1.36 or later, spanning **three Availability Zones**, created with any tool (console, Terraform, CDK, eksctl). This repo does not create clusters; if you need one, follow [Creating an Amazon EKS cluster](https://docs.aws.amazon.com/eks/latest/userguide/create-cluster.html).
- `kubectl`, `helm`, and the AWS CLI installed and configured.
- `metrics-server` running and serving metrics — the HPAs read CPU from it. Without it they report `<unknown>/50%` and never scale.
- For the FIS path: an IAM role FIS can assume (see `fis/README-fis.md`).

### Verify your cluster before starting

The repo defaults to `us-east-1a/b/c`. **Check that your cluster spans three distinct AZs** — the topology spread constraints and the AZ-unavailability window both require three zones.

Set these two variables once — every later step in this README reuses them:

```bash
export CLUSTER=<cluster-name>
export AWS_REGION=us-east-1        # your cluster's Region
```

Confirm the cluster name resolves:

```bash
aws eks list-clusters --region "$AWS_REGION" --output table
```

Look up the cluster's subnets and confirm **three distinct AZs** appear. The
`${SUBNET_IDS:?}` guard prevents `describe-subnets` from listing every subnet in
the account if the lookup returns empty:

```bash
SUBNET_IDS=$(aws eks describe-cluster --name "$CLUSTER" --region "$AWS_REGION" \
  --query 'cluster.resourcesVpcConfig.subnetIds' --output text) &&
aws ec2 describe-subnets --region "$AWS_REGION" --subnet-ids ${SUBNET_IDS:?} \
  --query 'sort_by(Subnets,&AvailabilityZone)[].[SubnetId,AvailabilityZone]' \
  --output table
```

Verify `metrics-server` is running and serving data — `kubectl top nodes` must
return numbers, not an error:

```bash
kubectl -n kube-system get deploy metrics-server
kubectl top nodes
```

If your AZs differ from `us-east-1a/b/c`, override them in two places: export
`AZ_A`/`AZ_B`/`AZ_C` in the shell running `scripts/watch-distribution.sh`, and
edit the `Placement.AvailabilityZone` filter in the FIS template.
`scripts/induce-window.sh` takes the AZ as an argument, so it needs no change.

## Repository layout

```
cluster/        node group requirements + AWS CLI commands (tool-agnostic)
monitoring/     kube-prometheus-stack values, Grafana dashboard, recording rules, alerts
workload/       namespace, 3-Deployment web fleet (Services + PDBs), HPAs, load generator
descheduler/    Helm values: CronJob mode for the demo (fast convergence, scoped
                to `demo` ns) and a Deployment-mode variant for live metrics
production/     pilot + production DeschedulerPolicy files and PDB templates
fis/            AWS FIS experiment templates for the AZ unavailability window
scripts/        induce-window.sh (drain/restore an AZ), watch-distribution.sh
                (30s per-AZ + per-deployment skew CSV), snapshot.sh (phase
                captures), export-prom.sh (chart data as CSV), mark.sh
                (timestamped run timeline)
```

**Demo vs production:** `descheduler/descheduler-values.yaml` is tuned so
convergence is watchable in minutes (2-minute schedule, 200-eviction budget).
For a real rollout, start from `production/policy-pilot.yaml` (one tolerant
namespace, tight budgets), graduate to `production/policy-production.yaml`
after 48–72 clean hours, and put a PDB on every in-scope workload first
(`production/pdb-examples.yaml`). `monitoring/prometheus-alerts.yaml` carries
the alert set — note the CronJob-mode metrics caveat in its header.

## Quick start

Set the raw base once, then every `kubectl`/`helm` step below applies manifests
straight from this repo. For a private repo, clone it and use local paths instead.

```bash
export RAW=https://raw.githubusercontent.com/aws-samples/sample-eks-descheduler-drift-demo/main
```

### Step 1 — Create the node group

Enable prefix delegation **first**, then create the node group. Replace the
subnet IDs and node role ARN with your own (lookup steps: `cluster/README.md`).

```bash
kubectl set env daemonset aws-node -n kube-system \
  ENABLE_PREFIX_DELEGATION=true WARM_PREFIX_TARGET=1
```

```bash
aws eks create-nodegroup --cluster-name "$CLUSTER" --region "$AWS_REGION" \
  --nodegroup-name ng-drift-1000 \
  --scaling-config minSize=21,maxSize=24,desiredSize=21 \
  --instance-types m5.2xlarge --disk-size 30 \
  --subnets <subnet-1a> <subnet-1b> <subnet-1c> \
  --node-role <NODE_ROLE_ARN> --labels role=drift-demo
```

Wait for the nodes to join:

```bash
aws eks wait nodegroup-active --cluster-name "$CLUSTER" --region "$AWS_REGION" \
  --nodegroup-name ng-drift-1000
kubectl get nodes -l role=drift-demo
```

### Step 2 — Install monitoring

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
```

```bash
helm install monitoring prometheus-community/kube-prometheus-stack \
  --namespace monitoring --create-namespace \
  --version 90.0.0 \
  --values "$RAW/monitoring/kube-prometheus-stack-values.yaml"
```

```bash
kubectl apply -f "$RAW/monitoring/pod-distribution-dashboard.yaml"
kubectl apply -f "$RAW/monitoring/recording-rule-per-az.yaml"
```

Open Grafana (port-forward only — see Security notes):

```bash
kubectl -n monitoring port-forward svc/monitoring-grafana 3000:80
```

### Step 3 — Deploy the workload fleet

```bash
kubectl apply -f "$RAW/workload/namespace.yaml"
kubectl apply -f "$RAW/workload/web-app.yaml"
kubectl apply -f "$RAW/workload/hpa-1000.yaml"   # or hpa-100.yaml for small-scale
kubectl apply -f "$RAW/workload/load-generator.yaml"
```

Drive the fleet up to scale. The load generator ships at 20 replicas, which is
sized for the full-scale (1,000-pod) run. Scale it and the HPAs climb toward
their ceilings within a few minutes:

```bash
kubectl -n demo scale deploy/load-generator --replicas=45   # full-scale run
```

On the **small-scale** (100-pod) run, 20 generators saturate every HPA
permanently and the churn baseline flatlines — scale *down* instead:

```bash
kubectl -n demo scale deploy/load-generator --replicas=4    # small-scale run only
```

Leave the traffic randomized (the file's defaults). The random burst/idle
pattern is what keeps the HPAs cycling up and down, and that churn is what
produces drift once a zone goes away — a fleet pinned flat never drifts. Only
pin the load flat (`IDLE_MIN=0 IDLE_MAX=0`, see `workload/load-generator.yaml`)
if you specifically want steady numbers for a still screenshot.

Confirm the fleet is up and evenly spread before inducing drift:

```bash
kubectl -n demo get hpa
kubectl -n demo get pods -o wide | wc -l
```

Start the distribution logger **in a spare terminal and leave it running for the
rest of the session** — it appends a per-AZ CSV row every 30s and is the source
of every before/after number:

```bash
./scripts/watch-distribution.sh captures/distribution.csv 30
```

### Step 4 — Induce the AZ-unavailability window

Use **your** third AZ name. `induce-window.sh open` **drains** the nodes — it
cordons them *and* evicts their running pods in one action, honouring PDBs. A
bare cordon only blocks new pods and leaves the running ones in place, so the
zone never empties; draining is what forces the pods to reschedule onto the
surviving AZs, which is closer to real instance loss than deleting pods by hand.
At full scale this evicts a large number of pods and proceeds in PDB-throttled
waves, so give it a minute or two to finish.

```bash
./scripts/induce-window.sh open us-east-1c
```

Grafana now shows the third zone empty and skew above `maxSkew: 1`. Return the
capacity — the nodes are healthy again:

```bash
./scripts/induce-window.sh close us-east-1c
```

### Step 5 — Control experiment

Wait 5–10 minutes. **Nothing moves back.** Kubernetes does not relocate running
pods to satisfy a soft (`ScheduleAnyway`) topology spread constraint. This is the
drift the descheduler exists to correct.

Watch the logger from Step 3 — the skew column stays flat:

```bash
tail -f captures/distribution.csv
```

### Step 6 — Install the descheduler (suspended)

Install **suspended** so the 2-minute CronJob schedule does not start correcting
drift before you have observed it.

```bash
helm repo add descheduler https://kubernetes-sigs.github.io/descheduler/
helm repo update
```

```bash
helm install descheduler descheduler/descheduler \
  --namespace kube-system \
  --version 0.36.0 \
  --values "$RAW/descheduler/descheduler-values.yaml" \
  --set suspend=true
```

### Step 7 — Trigger one descheduler pass

The timestamped job name avoids a collision on re-run.

```bash
kubectl -n kube-system create job descheduler-$(date +%H%M%S) --from=cronjob/descheduler
```

Check what it evicted:

```bash
kubectl -n kube-system logs \
  $(kubectl -n kube-system get jobs --sort-by=.metadata.creationTimestamp -o name \
    | grep desched | tail -1) \
  | grep -E "totalEvicted|violate the pod's disruption budget" | tail -5
```

PDBs cap evictions per pass, so **repeat this step** until per-workload skew
reaches `maxSkew`.

### Step 8 — Resume the schedule

Hand control back to the CronJob for the steady-state finish:

```bash
kubectl -n kube-system patch cronjob descheduler -p '{"spec":{"suspend":false}}'
```

The full experiment sequence — unavailability window, control experiment,
convergence, and what to capture at each phase — is in the blog post.

## Cleanup

### Step 1 — Stop the workload

```bash
kubectl delete namespace demo
```

### Step 2 — Remove the tooling

```bash
helm uninstall descheduler -n kube-system
helm uninstall monitoring -n monitoring
kubectl delete namespace monitoring   # helm leaves the namespace and PVCs
```

### Step 3 — Remove the node group

This is the dominant cost — do it promptly.

```bash
aws eks delete-nodegroup --cluster-name "$CLUSTER" --region "$AWS_REGION" \
  --nodegroup-name ng-drift-1000
```

```bash
aws eks wait nodegroup-deleted --cluster-name "$CLUSTER" --region "$AWS_REGION" \
  --nodegroup-name ng-drift-1000
```

### Step 4 — Delete the cluster (optional)

Only if the cluster was created solely for this demo. `delete-cluster` fails
while a node group is still attached, so complete Step 3 first.

```bash
aws eks delete-cluster --name "$CLUSTER" --region "$AWS_REGION"
```

### Step 5 — Check for leftover billing

Three things outlive the commands above and keep billing:

- **NAT gateway** — survives cluster deletion and bills hourly plus data processing. Delete it if you created one for the node subnets.
- **kube-prometheus-stack CRDs** — `helm uninstall` deliberately leaves these in place. Remove them with: `kubectl delete crd -l app.kubernetes.io/part-of=kube-prometheus-stack`
- **Prefix delegation** on the VPC CNI — still enabled after cleanup. Disable it if your cluster did not use it before the demo.

## Security notes

- Grafana ships with a placeholder admin password in the values file. Change it,
  and reach Grafana via `kubectl port-forward` only — do not expose it with a
  LoadBalancer without authentication in front.
- The FIS template requires an IAM role; see `fis/README-fis.md`.
- Never commit credentials. `captures/`, `run-*/`, and local credential files are
  git-ignored.
- **The web pods run as root**, and security scanners will flag it. The upstream
  [`registry.k8s.io/hpa-example`](https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale-walkthrough/)
  image runs Apache, which binds port 80 as root — setting `runAsNonRoot` stops
  the pod from starting. Do not carry these containers into production.
- Probes are TCP, not HTTP, on purpose: a `GET /` against `hpa-example` runs its
  CPU-burning handler, which would distort the HPA measurements this demo takes.

## License

MIT-0 (see LICENSE). Sample code; not intended for production use as-is.

