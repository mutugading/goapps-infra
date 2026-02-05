# Contributing to goapps-infra

Thank you for your interest in contributing to `goapps-infra`! This document contains complete guidelines for contributing to the infrastructure repository.

---

## 📋 Table of Contents

1. [Getting Started](#getting-started)
2. [Development Environment](#development-environment)
3. [Contribution Workflow](#contribution-workflow)
4. [Pull Request Guidelines](#pull-request-guidelines)
5. [Code Review Process](#code-review-process)
6. [Testing Requirements](#testing-requirements)
7. [Documentation Standards](#documentation-standards)
8. [Commit Message Conventions](#commit-message-conventions)
9. [Release Process](#release-process)
10. [Getting Help](#getting-help)

---

## Getting Started

### Prerequisites

Before contributing, make sure you have:

1. **Git** - Version control
2. **kubectl** - Kubernetes CLI
3. **kustomize** - Kubernetes configuration management
4. **helm** - Package manager for Kubernetes
5. **yamllint** - YAML linter
6. **Editor** - VSCode with extensions (YAML, Kubernetes)

### Install Tools

```bash
# Install kustomize (Linux/macOS)
curl -s "https://raw.githubusercontent.com/kubernetes-sigs/kustomize/master/hack/install_kustomize.sh" | bash
sudo mv kustomize /usr/local/bin/

# Install kubectl
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl

# Install helm
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# Install yamllint
pip install yamllint
```

### Clone Repository

```bash
# Via HTTPS
git clone https://github.com/mutugading/goapps-infra.git
cd goapps-infra

# Or via SSH
git clone git@github.com:mutugading/goapps-infra.git
cd goapps-infra
```

### Recommended VSCode Extensions

```json
{
  "recommendations": [
    "redhat.vscode-yaml",
    "ms-kubernetes-tools.vscode-kubernetes-tools",
    "Tim-Koehler.helm-intellisense",
    "googlecloudtools.cloudcode"
  ]
}
```

---

## Development Environment

### Local Validation

Before committing, always validate manifests:

```bash
# Validate all kustomizations
make lint

# Manual validation
kustomize build base/database/
kustomize build overlays/staging/
kustomize build services/finance-service/overlays/staging/

# YAML lint
yamllint -c .yamllint.yml .
```

### Local Kubernetes (Optional)

For local testing, you can use:

- **minikube**: `minikube start`
- **kind**: `kind create cluster`
- **k3d**: `k3d cluster create`

```bash
# Create local cluster with kind
kind create cluster --name goapps-dev

# Apply manifests
kubectl apply -k base/namespaces/
kubectl apply -k base/database/

# Cleanup
kind delete cluster --name goapps-dev
```

---

## Contribution Workflow

### 1. Create Issue (Recommended)

For major changes or bug reports, use the available issue templates:

| Template | Usage |
|----------|-------|
| [🐛 Bug Report](../../.github/ISSUE_TEMPLATE/bug_report.md) | Report bugs or infrastructure issues |
| [✨ Feature Request](../../.github/ISSUE_TEMPLATE/feature_request.md) | Request features or enhancements |
| [🚀 New Service](../../.github/ISSUE_TEMPLATE/new_service.md) | Request new service deployment |
| [🚨 Incident Report](../../.github/ISSUE_TEMPLATE/incident_report.md) | Report production incidents |

You can also create an issue manually with this format:

```markdown
### Description
Explain what you want to change/add

### Motivation
Why is this change needed?

### Proposed Solution
How do you plan to implement it?

### Alternatives Considered
Other alternatives you've considered

### Checklist
- [ ] I have read RULES.md
- [ ] I have read CONTRIBUTING.md
```

### 2. Create Feature Branch

```bash
# Update main branch
git checkout main
git pull origin main

# Create feature branch
git checkout -b <type>/<description>

# Examples:
git checkout -b feat/iam-service
git checkout -b fix/backup-cronjob-timing
git checkout -b infra/upgrade-prometheus
git checkout -b docs/update-architecture
```

### 3. Make Changes

```bash
# Edit files
vim base/database/postgres/statefulset.yaml

# Validate changes
kustomize build base/database/

# Stage changes
git add .

# Commit with conventional message
git commit -m "feat(postgres): increase memory limit to 2Gi"
```

### 4. Push and Create PR

```bash
# Push branch
git push origin <branch-name>

# Create PR via GitHub UI or GitHub CLI
gh pr create --title "feat(postgres): increase memory limit to 2Gi" \
  --body "## Description
  Increase PostgreSQL memory limit to handle larger workloads.
  
  ## Changes
  - Updated statefulset.yaml memory limits
  
  ## Testing
  - [ ] Validated with kustomize build
  - [ ] Tested on local cluster"
```

---

## Pull Request Guidelines

### PR Template

This repository uses an automatic [Pull Request Template](.github/PULL_REQUEST_TEMPLATE.md).

When creating a PR, the template will be automatically filled with the following fields:

```markdown
## Description
Describe the changes briefly.

## Type of Change
- [ ] 🐛 Bug fix (non-breaking change that fixes an issue)
- [ ] ✨ New feature (non-breaking change that adds functionality)
- [ ] 💥 Breaking change (fix or feature that changes existing functionality)
- [ ] 📚 Documentation update
- [ ] 🔧 Chore (maintenance, dependencies, etc.)

## Changes Made
- Change 1
- Change 2
- Change 3

## Testing Performed
- [ ] Kustomize build passes (`kustomize build <path>`)
- [ ] YAML lint passes (`yamllint .`)
- [ ] Tested on local cluster (if applicable)
- [ ] Tested on staging cluster (if applicable)

## Staging Verification (for production changes)
- [ ] Deployed to staging
- [ ] Verified functionality for 24+ hours
- [ ] No alerts triggered
- [ ] Screenshots/logs attached if UI changes

## Rollback Plan
Describe how to rollback if issues occur.

## Related Issues
Fixes #123
Related to #456

## Checklist
- [ ] I have read RULES.md
- [ ] I have read CONTRIBUTING.md
- [ ] Code follows naming conventions
- [ ] Documentation updated if needed
- [ ] No secrets committed
```

### PR Requirements

| Requirement | Description |
|-------------|-------------|
| **CI Passing** | All checks must be green |
| **Review Approval** | Minimum 1 approval from maintainer |
| **No Conflicts** | Branch must be up-to-date with main |
| **Description Complete** | PR description must be clear |
| **Labels Applied** | Use appropriate labels |

### Labels

| Label | Description |
|-------|-------------|
| `type: feature` | New feature |
| `type: bug` | Bug fix |
| `type: docs` | Documentation |
| `type: chore` | Maintenance |
| `priority: critical` | Very urgent |
| `priority: high` | Urgent |
| `priority: medium` | Normal |
| `priority: low` | Not urgent |
| `status: needs-review` | Waiting for review |
| `status: approved` | Approved, ready to merge |
| `status: changes-requested` | Needs revision |
| `env: staging` | Affects staging |
| `env: production` | Affects production |

---

## Code Review Process

### Review Checklist (for Reviewers)

#### Security
- [ ] No hardcoded secrets
- [ ] Secrets use secretKeyRef
- [ ] Minimal RBAC permissions required
- [ ] Network policies defined if needed

#### Best Practices
- [ ] Naming conventions followed
- [ ] Proper labels
- [ ] Resource limits defined
- [ ] Health checks configured
- [ ] Documentation updated

#### Kustomize
- [ ] Base has no environment-specific values
- [ ] Overlays are minimal (only necessary overrides)
- [ ] kustomization.yaml is valid

#### Operations
- [ ] Will not cause downtime
- [ ] Rollback plan is clear
- [ ] Monitoring/alerting updated if needed
- [ ] Backward compatible

### Review SLA

| PR Type | SLA | Reviewers |
|---------|-----|-----------|
| Hotfix | 2 hours | Any available maintainer |
| Bug fix | 24 hours | 1 maintainer |
| Feature | 48 hours | 1-2 maintainers |
| Large refactor | 1 week | 2+ maintainers |

### Providing Feedback

#### Constructive Comments

```markdown
# ✅ Good
"Consider using `secretKeyRef` instead of hardcoding the database host. 
This allows different values per environment."

# ❌ Not helpful
"This is wrong."
```

#### Suggestion Format

```markdown
```suggestion
          resources:
            requests:
              memory: "256Mi"  # Increased for better performance
              cpu: "100m"
```

### Resolving Feedback

1. Address all comments
2. Reply to each comment with explanation or acknowledgment
3. Request re-review after changes
4. Don't resolve conversations - let reviewer resolve them

---

## Testing Requirements

### Required Tests

| Level | Test | Tool | Required |
|-------|------|------|----------|
| Syntax | YAML validation | yamllint | ✅ |
| Build | Kustomize build | kustomize | ✅ |
| Security | Vulnerability scan | Trivy | ✅ (non-blocking) |
| Dry-run | kubectl dry-run | kubectl | Recommended |
| Integration | Deploy to staging | ArgoCD | For production changes |

### Running Tests Locally

```bash
# 1. YAML Lint
yamllint -c .yamllint.yml .

# 2. Kustomize Build (all paths)
for dir in base/*/; do
  if [ -f "${dir}kustomization.yaml" ]; then
    echo "Validating ${dir}..."
    kustomize build "${dir}" > /dev/null || exit 1
  fi
done

# 3. Kubectl Dry-run (requires cluster access)
kustomize build base/database/ | kubectl apply --dry-run=client -f -

# 4. Trivy scan
trivy config .
```

### Staging Verification

For changes going to production:

1. Deploy to staging via ArgoCD
2. Monitor for minimum 24 hours
3. Verify:
   - [ ] Pods running without restarts
   - [ ] No OOM events
   - [ ] No errors in logs
   - [ ] Metrics normal in Grafana
   - [ ] No alerts triggered

---

## Documentation Standards

### When to Update Documentation

- ✅ Adding new service
- ✅ Changing architecture
- ✅ New scripts or automation
- ✅ Breaking changes
- ✅ New environment variables
- ✅ New secrets requirements

### Documentation Files

| File | Content |
|------|---------|
| `README.md` | Overview, architecture, quick start |
| `RULES.md` | Conventions, patterns, guidelines |
| `CONTRIBUTING.md` | How to contribute (this file) |
| `docs/deployment-guide.md` | Step-by-step deployment |
| `docs/vps-reset-guide.md` | Complete VPS reset procedure |
| `docs/runbooks/*.md` | Operational runbooks |

### Documentation Format

```markdown
# Title

Brief description of what this document covers.

## Prerequisites
- Requirement 1
- Requirement 2

## Steps

### Step 1: First Step
\`\`\`bash
command to run
\`\`\`

Expected output:
\`\`\`
output example
\`\`\`

### Step 2: Second Step
...

## Troubleshooting

### Problem 1
**Symptom**: Description of the problem
**Cause**: Root cause
**Solution**: How to fix

## Related Documents
- [Link to related doc](./related.md)
```

### Diagrams

Use ASCII art or Mermaid for diagrams:

```markdown
# ASCII Art
\`\`\`
┌─────────────┐     ┌─────────────┐
│  Service A  │────▶│  Service B  │
└─────────────┘     └─────────────┘
\`\`\`

# Mermaid
\`\`\`mermaid
graph LR
    A[Service A] --> B[Service B]
    B --> C[Database]
\`\`\`
```

---

## Commit Message Conventions

### Format

```
<type>(<scope>): <subject>

[optional body]

[optional footer]
```

### Types

| Type | Description | Example |
|------|-------------|---------|
| `feat` | New feature | `feat(finance-service): add staging deployment` |
| `fix` | Bug fix | `fix(backup): correct minio endpoint` |
| `docs` | Documentation | `docs(readme): update architecture diagram` |
| `style` | Formatting, missing semicolons, etc | `style: fix yaml indentation` |
| `refactor` | Code refactoring | `refactor(base): reorganize database configs` |
| `perf` | Performance improvement | `perf(postgres): optimize connection pool` |
| `test` | Adding tests | `test: add kustomize validation` |
| `chore` | Maintenance | `chore(deps): upgrade prometheus to 67.0` |
| `ci` | CI/CD changes | `ci: add trivy security scan` |

### Scopes

| Scope | Description |
|-------|-------------|
| `postgres` | PostgreSQL configs |
| `redis` | Redis configs |
| `minio` | MinIO configs |
| `prometheus` | Prometheus/Grafana |
| `argocd` | ArgoCD configs |
| `backup` | Backup CronJobs |
| `ingress` | Ingress configs |
| `<service-name>` | Specific service |

### Examples

```bash
# Feature
feat(iam-service): add base deployment manifests

Add deployment, service, HPA, and kustomization for IAM service.
Includes staging and production overlays.

Refs: #123

# Bug fix
fix(backup): correct timezone in cronjob schedule

Change timezone from UTC to Asia/Jakarta for backup
schedules to align with business hours.

Fixes: #456

# Breaking change
feat(postgres)!: upgrade to PostgreSQL 18

BREAKING CHANGE: PostgreSQL upgraded from 16 to 18.
Requires database migration before deployment.

# Documentation
docs(readme): add troubleshooting section

Add common issues and solutions for debugging
pod startup failures and database connections.

# Chore
chore(deps): upgrade kube-prometheus-stack to 67.0.0

Includes Grafana 11.x and Prometheus 2.54
```

---

## Release Process

### Versioning

This repository uses **Calendar Versioning (CalVer)**:

- Format: `YYYY.MM.DD`
- Example: `2024.01.15`

### Release Workflow

1. **Prepare Release**
   ```bash
   git checkout main
   git pull origin main
   
   # Create release branch
   git checkout -b release/2024.01.15
   ```

2. **Update CHANGELOG**
   ```markdown
   # Changelog
   
   ## [2024.01.15]
   
   ### Added
   - New feature 1
   - New feature 2
   
   ### Changed
   - Updated component X
   
   ### Fixed
   - Bug fix 1
   
   ### Security
   - Security patch 1
   ```

3. **Create PR**
   ```bash
   git add CHANGELOG.md
   git commit -m "chore: prepare release 2024.01.15"
   git push origin release/2024.01.15
   # Create PR
   ```

4. **Tag Release** (after merge)
   ```bash
   git checkout main
   git pull origin main
   git tag -a v2024.01.15 -m "Release 2024.01.15"
   git push origin v2024.01.15
   ```

5. **Create GitHub Release**
   - Go to Releases
   - Create new release from tag
   - Add release notes from CHANGELOG

---

## Getting Help

### Channels

| Channel | Purpose | Response Time |
|---------|---------|---------------|
| GitHub Issues | Bug reports, feature requests | 24-48 hours |
| GitHub Discussions | Questions, ideas | 48-72 hours |
| Slack #devops-goapps | Quick questions | Real-time |

### Before Asking

1. ✅ Search existing issues
2. ✅ Read documentation (README, RULES, this file)
3. ✅ Check troubleshooting guides
4. ✅ Try to reproduce the issue

### How to Ask

```markdown
### Environment
- VPS: Staging/Production
- Kubernetes version: v1.xx
- Helm version: v3.xx

### What I'm trying to do
Clear description of the goal.

### What I've tried
1. Step 1
2. Step 2
3. Step 3

### What happened
Error message or unexpected behavior.

### Expected behavior
What should have happened.

### Logs/Screenshots
\`\`\`
Relevant logs here
\`\`\`
```

---

## Code of Conduct

### Our Standards

- 🤝 Be respectful and inclusive
- 💡 Give constructive feedback
- 📝 Document your changes
- 🔒 Never commit secrets
- ✅ Test before pushing
- 🙋 Ask if unsure

### Reporting Issues

If you encounter problems with another contributor's behavior, contact maintainers privately.

---

## Maintainers

| Name | Role | GitHub |
|------|------|--------|
| TBD | Lead Maintainer | @username |
| TBD | Maintainer | @username |

---

Thank you for contributing to `goapps-infra`! 🚀
