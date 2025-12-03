# Quick Setup Checklist

## ✅ Pre-Deployment Checklist

### 1. Repository Setup
- [ ] Create/verify `AppDirect/SecurityUtils` repository exists
- [ ] Upload `security-triage-orchestrator.yml` to `.github/workflows/`
- [ ] Upload `simple_cursor_triage.sh` to `.github/tools/`
- [ ] Verify file structure matches:
  ```
  .github/
  ├── workflows/
  │   └── security-triage-orchestrator.yml
  └── tools/
      └── simple_cursor_triage.sh
  ```

### 2. GitHub Personal Access Token (PAT)
- [ ] Create PAT at: https://github.com/settings/tokens
- [ ] Name: `Security Triage Orchestrator - Production`
- [ ] Scopes selected:
  - [ ] ✅ `repo` (Full control)
  - [ ] ✅ `security_events` (Read and write)
- [ ] Token copied and stored securely
- [ ] Expiration date noted

### 3. Cursor API Key
- [ ] Cursor API key obtained
- [ ] Key copied and stored securely

### 4. Repository Secrets
- [ ] Navigate to: https://github.com/AppDirect/SecurityUtils/settings/secrets/actions
- [ ] Add secret: `PAT_TOKEN` = [Your PAT token]
- [ ] Add secret: `CURSOR_API_KEY` = [Your Cursor API key]
- [ ] Verify both secrets are listed

### 5. Workflow Configuration
- [ ] Production repos list updated in workflow (lines 108-118)
- [ ] Verify repos have CodeQL scanning enabled
- [ ] Verify repos have open CodeQL alerts

### 6. Initial Test
- [ ] Go to: https://github.com/AppDirect/SecurityUtils/actions
- [ ] Manually trigger workflow with:
  - `auto_dismiss: false`
  - `use_test_repos: true`
- [ ] Monitor workflow execution
- [ ] Check `discover-repos-with-alerts` job succeeds
- [ ] Verify repos are discovered
- [ ] Check triage jobs complete
- [ ] Download and review artifacts

### 7. Validation
- [ ] Review triage results in artifacts
- [ ] Verify classifications (FP/TP/UNCERTAIN) look reasonable
- [ ] Check for any errors in logs
- [ ] Verify no authentication errors

### 8. Production Deployment
- [ ] Test with `auto_dismiss: false` on all repos
- [ ] Review results thoroughly
- [ ] Get approval from team
- [ ] Enable `auto_dismiss: true` for production
- [ ] Monitor first auto-dismiss run
- [ ] Verify dismissed alerts in Security tab

## 🔧 Required Secrets Summary

| Secret Name | Description | Where to Get |
|------------|-------------|--------------|
| `PAT_TOKEN` | GitHub Personal Access Token with `repo` and `security_events` scopes | https://github.com/settings/tokens |
| `CURSOR_API_KEY` | Cursor AI API key for triage analysis | Cursor settings/dashboard |

## 📋 Production Repos (Default List)

The workflow is pre-configured with these 10 production repos:
1. `payment-methods-ui`
2. `subscription-ui`
3. `billing-pricebook-microui`
4. `prm-opportunities-ui`
5. `product-ui`
6. `authz`
7. `reporting-service`
8. `ad-checkout-ui`
9. `revenue-shares-ui`
10. `pricing`

**To modify:** Edit lines 108-118 in `security-triage-orchestrator.yml`

## 🚀 Quick Start Commands

### Test Workflow Manually:
1. Go to: https://github.com/AppDirect/SecurityUtils/actions/workflows/security-triage-orchestrator.yml
2. Click "Run workflow"
3. Use defaults (auto_dismiss: false, use_test_repos: true)
4. Click "Run workflow" button

### Check Workflow Status:
- View runs: https://github.com/AppDirect/SecurityUtils/actions
- View secrets: https://github.com/AppDirect/SecurityUtils/settings/secrets/actions

## ⚠️ Important Notes

1. **First Run:** Always test with `auto_dismiss: false` to review results
2. **PAT Expiration:** Set calendar reminder before PAT expires
3. **Monitoring:** Check workflow runs weekly after enabling auto-dismiss
4. **Audit:** Periodically review dismissed alerts to ensure accuracy

