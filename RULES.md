# Infrastructure Development Rules

Guidelines for all infrastructure developers working on goapps-infra.

## Golden Rules

1. **Never commit secrets** - Use kubectl create secret manually
2. **Always test in staging first** - Production requires approval
3. **Document all changes** - Update README or create runbook
4. **Use Kustomize overlays** - Don't duplicate manifests
5. **Follow naming conventions** - See below

## Naming Conventions

### Kubernetes Resources

| Resource | Pattern | Example |
|----------|---------|---------|
| Namespace | `<purpose>` | `database`, `monitoring`, `goapps` |
| Deployment | `<service-name>` | `finance-service`, `pgbouncer` |
| Service | `<deployment-name>` | `finance-service`, `postgres` |
| ConfigMap | `<app>-config` | `postgres-config`, `grafana-config` |
| Secret | `<app>-secret` | `postgres-secret`, `minio-secret` |
| HPA | `<deployment>-hpa` | `finance-service-hpa` |
| VPA | `<deployment>-vpa` | `postgres-vpa` |
| PVC | `<app>-data` | `postgres-data`, `minio-data` |
| CronJob | `<purpose>-<schedule>` | `postgres-backup-morning` |

### ArgoCD Applications

| Pattern | Example |
|---------|---------|
| `<service>-<env>` | `finance-service-staging` |
| `infra-<component>` | `infra-database`, `infra-monitoring` |

### Git Branches

| Pattern | Purpose |
|---------|---------|
| `main` | Production-ready configs |
| `infra/<description>` | Infrastructure changes |
| `feat/<service>` | New service setup |
| `fix/<issue>` | Bug fixes |

## Adding New Service

### Step 1: Create Directory Structure

```bash
mkdir -p services/<service-name>/{base,overlays/{staging,production}}
```

### Step 2: Create Base Manifests

Create these files in `services/<service-name>/base/`:

```yaml
# deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: <service-name>
  labels:
    app: <service-name>
spec:
  replicas: 1
  selector:
    matchLabels:
      app: <service-name>
  template:
    metadata:
      labels:
        app: <service-name>
    spec:
      containers:
        - name: <service-name>
          image: ghcr.io/mutugading/<service-name>:latest
          ports:
            - containerPort: 50051  # gRPC
            - containerPort: 8080   # HTTP
          resources:
            requests:
              memory: "128Mi"
              cpu: "100m"
            limits:
              memory: "512Mi"
              cpu: "500m"
```

```yaml
# service.yaml
apiVersion: v1
kind: Service
metadata:
  name: <service-name>
spec:
  selector:
    app: <service-name>
  ports:
    - name: grpc
      port: 50051
    - name: http
      port: 8080
```

```yaml
# hpa.yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: <service-name>-hpa
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: <service-name>
  minReplicas: 1
  maxReplicas: 5
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 70
```

```yaml
# kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - deployment.yaml
  - service.yaml
  - hpa.yaml

commonLabels:
  app.kubernetes.io/name: <service-name>
  app.kubernetes.io/part-of: goapps
```

### Step 3: Create Overlays

**`overlays/staging/kustomization.yaml`:**
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: goapps-staging

resources:
  - ../../base

patches:
  - path: patches/replicas.yaml
```

**`overlays/staging/patches/replicas.yaml`:**
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: <service-name>
spec:
  replicas: 1
```

### Step 4: Add ArgoCD Application

Create `argocd/apps/<service-name>.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: <service-name>-staging
  namespace: argocd
spec:
  project: goapps
  source:
    repoURL: https://github.com/mutugading/goapps-infra.git
    targetRevision: main
    path: services/<service-name>/overlays/staging
  destination:
    server: https://kubernetes.default.svc
    namespace: goapps-staging
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

### Step 5: Add Database Schema (if needed)

Edit `base/database/postgres/configmap.yaml` init-schemas.sql:

```sql
CREATE SCHEMA IF NOT EXISTS <service_name>;
GRANT ALL PRIVILEGES ON SCHEMA <service_name> TO postgres;
```

### Step 6: Commit and Push

```bash
git checkout -b infra/add-<service-name>
git add .
git commit -m "feat(infra): add <service-name> deployment"
git push origin infra/add-<service-name>
# Create PR to main
```

## Updating Existing Service

1. Make changes in appropriate overlay (staging first)
2. Test in staging
3. Copy changes to production overlay
4. Create PR

## Database Changes

### Adding New Schema

1. Edit `base/database/postgres/configmap.yaml`
2. Add CREATE SCHEMA statement
3. Re-deploy PostgreSQL pod (will run init script)

### PostgreSQL Upgrade

1. Backup database
2. Update image version in statefulset
3. Test in staging
4. Apply to production

## Monitoring Changes

### Adding New Dashboard

1. Create JSON file in `base/monitoring/dashboards/`
2. Create ConfigMap with label `grafana_dashboard: "1"`
3. Grafana sidecar auto-loads

### Adding New Alert

1. Edit `base/monitoring/alert-rules/grafana-alerts.yaml`
2. Follow existing alert format
3. Test in staging Grafana

## Backup Verification

Weekly checklist:
- [ ] Check CronJob status: `kubectl get cronjobs -n database`
- [ ] Verify MinIO bucket: `mc ls minio/postgres-backups`
- [ ] Verify Backblaze: Check B2 console
- [ ] Test restore on staging (monthly)

## Emergency Procedures

### Pod CrashLoopBackOff

```bash
kubectl describe pod <pod> -n <namespace>
kubectl logs <pod> -n <namespace> --previous
```

### Database Connection Issues

```bash
kubectl exec -it postgres-0 -n database -- psql -U postgres -d goapps
```

### Rollback Deployment

```bash
kubectl rollout undo deployment/<name> -n <namespace>
# Or with ArgoCD
argocd app rollback <app-name>
```

## Contact

- **On-call**: (define rotation)
- **Escalation**: (define path)
