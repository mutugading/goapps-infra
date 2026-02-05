---
name: 🚀 New Service Request
about: Request deployment configuration for a new service
title: '[SERVICE] Add <service-name>'
labels: 'type: feature, component: services'
assignees: ''
---

## Service Information

### Basic Info
- **Service Name**: 
- **Repository**: `goapps-backend/services/<name>`
- **Container Image**: `ghcr.io/mutugading/<name>:latest`

### Ports
| Port | Protocol | Purpose |
|------|----------|---------|
| 50051 | gRPC | Main API |
| 8080 | HTTP | REST API / Health check |
| 8090 | HTTP | Metrics (/metrics) |

### Dependencies
- [ ] PostgreSQL (schema: ___)
- [ ] Redis
- [ ] RabbitMQ
- [ ] MinIO
- [ ] Oracle (schema: ___)
- [ ] Other services: ___

## Resource Requirements

### Staging
```yaml
resources:
  requests:
    memory: "128Mi"
    cpu: "100m"
  limits:
    memory: "512Mi"
    cpu: "500m"
replicas: 1
```

### Production
```yaml
resources:
  requests:
    memory: "256Mi"
    cpu: "200m"
  limits:
    memory: "1Gi"
    cpu: "1000m"
replicas: 2
```

## Autoscaling

### HPA Configuration
- **Min Replicas**: 
- **Max Replicas**: 
- **Target CPU**: 70%
- **Target Memory**: 80%

## Environment Variables Required
<!-- List all required env vars -->

| Variable | Source | Description |
|----------|--------|-------------|
| `DATABASE_HOST` | ConfigMap | PostgreSQL host |
| `DATABASE_PASSWORD` | Secret | DB password |
| ... | ... | ... |

## Ingress Requirements
- [ ] HTTP endpoint needed
- [ ] gRPC endpoint needed
- **Path prefix**: `/api/v1/<service>`

## Monitoring Requirements
- [ ] ServiceMonitor for Prometheus
- [ ] Custom Grafana dashboard
- [ ] Custom alert rules

## Timeline
- **Target Staging Deployment**: 
- **Target Production Deployment**: 

---

### Checklist
- [ ] Service has been built and can run locally
- [ ] Container image has been pushed to GHCR
- [ ] Proto definitions exist in goapps-shared-proto
- [ ] Database migrations are ready
