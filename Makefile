# goapps-infra Makefile
# Common operations for K8s infrastructure management

.PHONY: help bootstrap install-monitoring install-argocd apply-staging apply-production reset

# Colors
GREEN := \033[0;32m
YELLOW := \033[0;33m
NC := \033[0m

help:
	@echo "$(GREEN)goapps-infra Makefile$(NC)"
	@echo ""
	@echo "$(YELLOW)Bootstrap:$(NC)"
	@echo "  make bootstrap           - Initial K3s cluster setup"
	@echo "  make install-monitoring  - Install Prometheus/Grafana/Loki"
	@echo "  make install-argocd      - Install ArgoCD for GitOps"
	@echo ""
	@echo "$(YELLOW)Deploy (Manual):$(NC)"
	@echo "  make apply-base          - Apply all base configs"
	@echo "  make apply-staging       - Apply staging overlays"
	@echo "  make apply-production    - Apply production overlays"
	@echo ""
	@echo "$(YELLOW)Services:$(NC)"
	@echo "  make deploy-finance-staging     - Deploy finance-service to staging"
	@echo "  make deploy-finance-production  - Deploy finance-service to production"
	@echo ""
	@echo "$(YELLOW)Maintenance:$(NC)"
	@echo "  make status              - Cluster status"
	@echo "  make logs-postgres       - PostgreSQL logs"
	@echo "  make backup-now          - Trigger manual backup"
	@echo ""
	@echo "$(YELLOW)Danger Zone:$(NC)"
	@echo "  make reset               - Uninstall K3s (DESTRUCTIVE!)"

# =============================================================================
# Bootstrap
# =============================================================================

bootstrap:
	@echo "$(GREEN)Running bootstrap script...$(NC)"
	./scripts/bootstrap.sh

install-monitoring:
	@echo "$(GREEN)Installing monitoring stack...$(NC)"
	./scripts/install-monitoring.sh

install-argocd:
	@echo "$(GREEN)Installing ArgoCD...$(NC)"
	./scripts/install-argocd.sh

# =============================================================================
# Apply Configs (Manual)
# =============================================================================

apply-base:
	@echo "$(GREEN)Applying base configs...$(NC)"
	kubectl apply -k base/namespaces/
	kubectl apply -k base/database/
	kubectl apply -k base/backup/

apply-staging: apply-base
	@echo "$(GREEN)Applying staging overlays...$(NC)"
	kubectl apply -k overlays/staging/

apply-production: apply-base
	@echo "$(GREEN)Applying production overlays...$(NC)"
	kubectl apply -k overlays/production/

# =============================================================================
# Service Deployments
# =============================================================================

deploy-finance-staging:
	@echo "$(GREEN)Deploying finance-service to staging...$(NC)"
	kubectl apply -k services/finance-service/overlays/staging/

deploy-finance-production:
	@echo "$(GREEN)Deploying finance-service to production...$(NC)"
	kubectl apply -k services/finance-service/overlays/production/

# =============================================================================
# Status & Monitoring
# =============================================================================

status:
	@echo "$(GREEN)=== Nodes ===$(NC)"
	kubectl get nodes -o wide
	@echo ""
	@echo "$(GREEN)=== Pods (all namespaces) ===$(NC)"
	kubectl get pods -A
	@echo ""
	@echo "$(GREEN)=== HPA ===$(NC)"
	kubectl get hpa -A
	@echo ""
	@echo "$(GREEN)=== ArgoCD Apps ===$(NC)"
	kubectl get applications -n argocd 2>/dev/null || echo "ArgoCD not installed"

logs-postgres:
	kubectl logs -f statefulset/postgres -n database

logs-argocd:
	kubectl logs -f deployment/argocd-server -n argocd

# =============================================================================
# Backup
# =============================================================================

backup-now:
	@echo "$(GREEN)Creating manual backup...$(NC)"
	kubectl create job --from=cronjob/postgres-backup-morning postgres-backup-manual-$(shell date +%Y%m%d%H%M%S) -n database
	@echo "Backup job created. Check status with: kubectl get jobs -n database"

# =============================================================================
# Danger Zone
# =============================================================================

reset:
	@echo "$(YELLOW)WARNING: This will uninstall K3s and delete ALL cluster data!$(NC)"
	@read -p "Type 'yes-delete-everything' to confirm: " confirm && \
	if [ "$$confirm" = "yes-delete-everything" ]; then \
		./scripts/reset-k3s.sh; \
	else \
		echo "Aborted."; \
	fi

# =============================================================================
# Development
# =============================================================================

lint:
	@echo "$(GREEN)Validating Kubernetes manifests...$(NC)"
	kubectl apply --dry-run=client -k base/namespaces/
	kubectl apply --dry-run=client -k base/database/
	kubectl apply --dry-run=client -k base/backup/
	@echo "$(GREEN)All manifests valid!$(NC)"

port-forward-grafana:
	@echo "$(GREEN)Forwarding Grafana to localhost:3000$(NC)"
	kubectl port-forward svc/prometheus-grafana -n monitoring 3000:80

port-forward-argocd:
	@echo "$(GREEN)Forwarding ArgoCD to localhost:8080$(NC)"
	kubectl port-forward svc/argocd-server -n argocd 8080:443
