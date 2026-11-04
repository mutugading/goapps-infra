# local.mk - Local Colima k3s cluster targets (profile `k8s`, context `colima-k8s`).
# Included from Makefile via `-include local.mk`. Run `make local-help`.
# Safety: every kubectl uses --context, helm uses --kube-context, never `use-context`,
# never touches colima profile `default` (data layer lives there).

LOCAL_CTX         ?= colima-k8s
LOCAL_PROFILE     ?= k8s
K3S_VERSION       ?= v1.34.13+k3s1
LOCAL_NS          ?= goapps-local
LOCAL_CPU         ?= 4
LOCAL_MEM         ?= 8
LOCAL_DISK        ?= 40
BACKEND_DIR       ?= ../goapps-backend
FRONTEND_DIR      ?= ../goapps-frontend
LOCAL_DOCKER_HOST ?= unix://$(HOME)/.colima/$(LOCAL_PROFILE)/docker.sock
LOCAL_JOB_TIMEOUT ?= 300s
LOCAL_SERVICES    ?= finance-service finance-worker finance-cost-orchestrator finance-cost-worker iam-service ppc-service frontend

# image-name:build-context:dockerfile (mirrors CI: context '.' = repo root, file ./services/<dir>/Dockerfile;
# frontend: context '.', Dockerfile at repo root, no build-args). finance-worker reuses the finance-service image.
LOCAL_IMAGES := \
  finance-service:$(BACKEND_DIR):services/finance/Dockerfile \
  iam-service:$(BACKEND_DIR):services/iam/Dockerfile \
  ppc-service:$(BACKEND_DIR):services/ppc/Dockerfile \
  finance-cost-orchestrator:$(BACKEND_DIR):services/finance-cost-orchestrator/Dockerfile \
  finance-cost-worker:$(BACKEND_DIR):services/finance-cost-worker/Dockerfile \
  goapps-frontend:$(FRONTEND_DIR):Dockerfile

LOCAL_KC := kubectl --context $(LOCAL_CTX)

.PHONY: local-help local-guard-ctx local-cluster-up local-cluster-down local-secrets local-base \
        local-build local-deploy local-status local-logs local-scale-zero local-scale-one \
        local-migrate local-seed local-destroy local-validate local-all

local-help:
	@echo "Local k3s cluster (profile=$(LOCAL_PROFILE) ctx=$(LOCAL_CTX) ns=$(LOCAL_NS))"
	@echo "  make local-cluster-up    - start colima profile + install ingress-nginx"
	@echo "  make local-cluster-down  - stop colima profile"
	@echo "  make local-secrets       - generate base/local/credentials/*.local.env (no overwrite)"
	@echo "  make local-base          - apply namespaces, external endpoints, credentials"
	@echo "  make local-build [SVC=img] - build :local images into the k8s profile docker daemon"
	@echo "  make local-deploy [RESTART=1] - apply all overlays/local (RESTART=1 restarts deployments)"
	@echo "  make local-all           - local-build then local-deploy RESTART=1"
	@echo "  make local-status        - pods/svc/ingress + colima list"
	@echo "  make local-logs SVC=name - follow logs of a deployment"
	@echo "  make local-scale-zero / local-scale-one - scale all deployments"
	@echo "  make local-migrate SVC=finance-service|iam-service|ppc-service CONFIRM=yes (writes SHARED local DB v2)"
	@echo "  make local-seed    SVC=finance-service|iam-service|ppc-service CONFIRM=yes (writes SHARED local DB v2)"
	@echo "  make local-validate      - kustomize build all overlays/local (read-only)"
	@echo "  make local-destroy CONFIRM=yes - delete colima profile $(LOCAL_PROFILE)"

local-guard-ctx:
	@[ "$(LOCAL_CTX)" = "colima-k8s" ] || \
	  { echo "REFUSING: LOCAL_CTX must be colima-k8s (got '$(LOCAL_CTX)')"; exit 1; }
	@kubectl config get-contexts -o name | grep -qx '$(LOCAL_CTX)' || \
	  { echo "ERROR: kube context '$(LOCAL_CTX)' not found (run: make local-cluster-up)"; exit 1; }

local-cluster-up:
	@if colima status -p $(LOCAL_PROFILE) >/dev/null 2>&1; then \
	  echo "colima profile $(LOCAL_PROFILE) already running, skipping start"; \
	else \
	  colima start -p $(LOCAL_PROFILE) --cpu $(LOCAL_CPU) --memory $(LOCAL_MEM) --disk $(LOCAL_DISK) \
	    --runtime docker --kubernetes --kubernetes-version $(K3S_VERSION) --k3s-arg=--disable=traefik; \
	fi
	@$(MAKE) --no-print-directory local-guard-ctx
	@KUBE_CONTEXT=$(LOCAL_CTX) ./scripts/local/install-ingress-nginx.sh
	@echo "NOTE: colima start may switch your current kubectl context. Current: $$(kubectl config current-context 2>/dev/null)"
	@echo "      This Makefile always passes --context $(LOCAL_CTX); it never changes your current context."

local-cluster-down:
	colima stop -p $(LOCAL_PROFILE)

local-secrets:
	./scripts/local/gen-local-secrets.sh

local-base: local-guard-ctx
	$(LOCAL_KC) apply -k base/local/namespaces
	$(LOCAL_KC) apply -k base/local/external
	$(LOCAL_KC) apply -k base/local/credentials

# SVC filters by image name (iam-service, goapps-frontend, ...); finance-worker maps to finance-service.
local-build:
	@sel="$(SVC)"; [ "$$sel" = "finance-worker" ] && sel=finance-service; found=0; \
	for e in $(LOCAL_IMAGES); do \
	  img=$${e%%:*}; rest=$${e#*:}; ctx=$${rest%%:*}; df=$${rest#*:}; \
	  if [ -n "$$sel" ] && [ "$$sel" != "$$img" ]; then continue; fi; \
	  found=1; \
	  echo ">> building ghcr.io/mutugading/$$img:local ($$ctx, $$df)"; \
	  DOCKER_HOST=$(LOCAL_DOCKER_HOST) docker build -f $$ctx/$$df -t ghcr.io/mutugading/$$img:local $$ctx || exit 1; \
	done; \
	[ $$found = 1 ] || { echo "ERROR: unknown SVC='$(SVC)'"; exit 1; }

local-deploy: local-guard-ctx local-base
	@for s in $(LOCAL_SERVICES); do \
	  echo ">> apply services/$$s/overlays/local"; \
	  $(LOCAL_KC) apply -k services/$$s/overlays/local || exit 1; \
	done
	@if [ "$(RESTART)" = "1" ]; then \
	  $(LOCAL_KC) -n $(LOCAL_NS) rollout restart deployment; \
	fi

local-status: local-guard-ctx
	$(LOCAL_KC) get pods,svc,ingress -n $(LOCAL_NS)
	colima list

local-logs: local-guard-ctx
	@[ -n "$(SVC)" ] || { echo "ERROR: SVC=<deployment name> required"; exit 1; }
	$(LOCAL_KC) logs -f deploy/$(SVC) -n $(LOCAL_NS)

local-scale-zero: local-guard-ctx
	$(LOCAL_KC) -n $(LOCAL_NS) scale deployment --all --replicas=0

local-scale-one: local-guard-ctx
	$(LOCAL_KC) -n $(LOCAL_NS) scale deployment --all --replicas=1

# Applies only the Job labelled component=<migration|seeder>,app=$(SVC) from the rendered jobs
# overlay (backfill/createdb jobs have other component labels and are never selected).
define local_job_apply
	@case "$(SVC)" in finance-service|iam-service|ppc-service) ;; \
	  *) echo "ERROR: SVC must be finance-service|iam-service|ppc-service"; exit 1;; esac
	@echo "WARNING: this writes to the SHARED local DB v2 on the host (postgres :5440)."
	@[ "$(CONFIRM)" = "yes" ] || { echo "Re-run with CONFIRM=yes to proceed."; exit 1; }
	@# Jobs have a fixed name + :local tag and ttlSecondsAfterFinished, so a plain apply would
	@# report "unchanged" (no new pod) or fail on the immutable pod template. Delete first.
	@# Selector is component AND app: all services share $(LOCAL_NS), so component alone
	@# would match another service's Job (e.g. finance-migrate while SVC=iam-service).
	kustomize build --load-restrictor LoadRestrictionsNone services/$(SVC)/overlays/local/jobs \
	  | $(LOCAL_KC) delete -f - -l component=$(1),app=$(SVC) --ignore-not-found --wait=true
	kustomize build --load-restrictor LoadRestrictionsNone services/$(SVC)/overlays/local/jobs \
	  | $(LOCAL_KC) apply -f - -l component=$(1),app=$(SVC)
	@job=$$($(LOCAL_KC) -n $(LOCAL_NS) get jobs -l component=$(1),app=$(SVC) -o name); \
	  [ "$$(echo "$$job" | grep -c .)" = 1 ] || { echo "ERROR: expected exactly 1 Job for component=$(1),app=$(SVC), got: $$job"; exit 1; }; \
	  echo "waiting for $$job (timeout $(LOCAL_JOB_TIMEOUT))"; \
	  if $(LOCAL_KC) -n $(LOCAL_NS) wait --for=condition=complete $$job --timeout=$(LOCAL_JOB_TIMEOUT); then \
	    $(LOCAL_KC) -n $(LOCAL_NS) logs $$job --tail=30; \
	  else \
	    echo "ERROR: $$job did not complete"; $(LOCAL_KC) -n $(LOCAL_NS) logs $$job --tail=80; exit 1; \
	  fi
endef

local-migrate: local-guard-ctx
	$(call local_job_apply,migration)

local-seed: local-guard-ctx
	$(call local_job_apply,seeder)

local-destroy:
	@[ "$(LOCAL_PROFILE)" != "default" ] || { echo "REFUSING: profile 'default' holds the data layer"; exit 1; }
	@[ "$(CONFIRM)" = "yes" ] || { echo "Re-run with CONFIRM=yes to delete colima profile $(LOCAL_PROFILE)"; exit 1; }
	colima delete -p $(LOCAL_PROFILE) -f

local-validate:
	@for s in $(LOCAL_SERVICES); do \
	  echo ">> kustomize build services/$$s/overlays/local"; \
	  kustomize build services/$$s/overlays/local >/dev/null || exit 1; \
	done
	@for s in finance-service iam-service ppc-service; do \
	  echo ">> kustomize build services/$$s/overlays/local/jobs"; \
	  kustomize build --load-restrictor LoadRestrictionsNone services/$$s/overlays/local/jobs >/dev/null || exit 1; \
	done
	@for b in namespaces external credentials; do \
	  echo ">> kustomize build base/local/$$b"; \
	  kustomize build base/local/$$b >/dev/null || exit 1; \
	done
	@echo "local-validate OK"

local-all:
	$(MAKE) local-build
	$(MAKE) local-deploy RESTART=1
