# Production Setup Guide for Security Triage Orchestrator

## Repository Structure

```
AppDirect/SecurityUtils/
├── .github/
│   └── workflows/
│       └── security-triage-orchestrator.yml
└── scripts/
    └── simple_cursor_triage.sh
```

## Step 1: Create GitHub Personal Access Token (PAT)

### Why you need a PAT:
- `GITHUB_TOKEN` only has access to the repository where the workflow runs
- To access other repositories in the org, you need a PAT with broader permissions

### Steps to create PAT:

1. **Go to GitHub Settings:**
   - Click your profile picture → **Settings**
   - Navigate to: **Developer settings** → **Personal access tokens** → **Tokens (classic)**
   - Or go directly: https://github.com/settings/tokens

2. **Generate New Token:**
   - Click **"Generate new token"** → **"Generate new token (classic)"**
   - Give it a descriptive name: `Security Triage Orchestrator - Production`
   - Set expiration (recommended: 90 days or custom based on your policy)

3. **Select Required Scopes:**
   - ✅ **`repo`** (Full control of private repositories)
     - This includes: `repo:status`, `repo_deployment`, `public_repo`, `repo:invite`, `security_events`
   - ✅ **`security_events`** (Read and write security events)
     - This allows reading CodeQL alerts and dismissing them

4. **Generate and Copy:**
   - Click **"Generate token"**
   - **⚠️ IMPORTANT:** Copy the token immediately - you won't be able to see it again!
   - Store it securely (e.g., password manager)

## Step 2: Get Cursor API Key

### If you already have Cursor API Key:
- Use your existing key

### If you need to create one:
1. Go to Cursor settings or API dashboard
2. Generate an API key
3. Copy it securely

## Step 3: Add Secrets to AppDirect/SecurityUtils Repository

1. **Navigate to Repository:**
   - Go to: https://github.com/AppDirect/SecurityUtils
   - Click **Settings** (top navigation)

2. **Go to Secrets:**
   - In the left sidebar: **Secrets and variables** → **Actions**
   - Click **"New repository secret"**

3. **Add PAT_TOKEN Secret:**
   - **Name:** `PAT_TOKEN`
   - **Value:** Paste your Personal Access Token from Step 1
   - Click **"Add secret"**

4. **Add CURSOR_API_KEY Secret:**
   - Click **"New repository secret"** again
   - **Name:** `CURSOR_API_KEY`
   - **Value:** Paste your Cursor API Key from Step 2
   - Click **"Add secret"**

## Step 4: Update Workflow for Production Repos

The workflow needs to be updated with your production repository list. The current workflow has test repos - you'll need to update the `TEST_REPOS` array in `security-triage-orchestrator.yml`.

### Production Repos List:
Update lines 122-132 in `security-triage-orchestrator.yml`:

```yaml
# PROD REPOS (for production POC)
TEST_REPOS=(
  "${ORG_PREFIX}payment-methods-ui"
  "${ORG_PREFIX}subscription-ui"
  "${ORG_PREFIX}billing-pricebook-microui"
  "${ORG_PREFIX}prm-opportunities-ui"
  "${ORG_PREFIX}product-ui"
  "${ORG_PREFIX}authz"
  "${ORG_PREFIX}reporting-service"
  "${ORG_PREFIX}ad-checkout-ui"
  "${ORG_PREFIX}revenue-shares-ui"
  "${ORG_PREFIX}pricing"
)
```

## Step 5: Verify Permissions

The workflow requires these permissions (already configured):
- ✅ `contents: read` - To read repository files
- ✅ `security-events: write` - To read and dismiss CodeQL alerts
- ✅ `actions: read` - To read workflow information

**Note:** The PAT token must have `repo` and `security_events` scopes to work across repositories.

## Step 6: Test the Setup

1. **Manual Trigger:**
   - Go to: https://github.com/AppDirect/SecurityUtils/actions
   - Click on **"Security Triage Orchestrator"** workflow
   - Click **"Run workflow"**
   - Configure:
     - ✅ **auto_dismiss:** `false` (for first test)
     - ✅ **use_test_repos:** `true` (to use your configured repos)
     - ✅ **max_alerts_per_repo:** `300` (default)
   - Click **"Run workflow"**

2. **Check Results:**
   - Monitor the workflow run
   - Check the `discover-repos-with-alerts` job to see if repos are discovered
   - Check individual `triage-repos` jobs for each repository
   - Download artifacts to see triage results

3. **Verify Secrets:**
   - If you see authentication errors (HTTP 401/403), check:
     - PAT_TOKEN secret is set correctly
     - PAT has required scopes (`repo`, `security_events`)
     - CURSOR_API_KEY is set correctly

## Step 7: Enable Auto-Dismissal (After Testing)

Once you've verified the triage is working correctly:

1. **Review Results:**
   - Check the triage results in artifacts
   - Verify false positives are being identified correctly
   - Review a few dismissed alerts manually

2. **Enable Auto-Dismiss:**
   - Run workflow with **auto_dismiss:** `true`
   - Start with a small subset of repos
   - Monitor the results

## Step 8: Schedule Configuration

The workflow is already configured to run automatically:
- **Schedule:** Every Sunday at 12:00 PM UTC
- **Cron:** `0 12 * * 0`

You can modify this in the workflow file if needed.

## Troubleshooting

### Issue: HTTP 401 errors
**Solution:** 
- Verify PAT_TOKEN secret is set
- Check PAT has `repo` and `security_events` scopes
- Ensure PAT hasn't expired

### Issue: HTTP 403 errors
**Solution:**
- PAT may not have access to specific repositories
- Check repository visibility (private repos need PAT with access)
- Verify `security_events` scope is enabled

### Issue: Cursor authentication errors
**Solution:**
- Verify CURSOR_API_KEY secret is set
- Check API key is valid and not expired
- Ensure API key has necessary permissions

### Issue: No repos discovered
**Solution:**
- Check if repos have CodeQL scanning enabled
- Verify repos have open CodeQL alerts
- Check PAT has access to those repositories
- Review workflow logs for specific error messages

## Security Best Practices

1. **PAT Token:**
   - Use minimum required scopes
   - Set appropriate expiration
   - Rotate regularly
   - Store securely

2. **Secrets:**
   - Never commit secrets to code
   - Use GitHub Secrets for all sensitive data
   - Limit access to repository secrets

3. **Monitoring:**
   - Review workflow runs regularly
   - Monitor dismissed alerts
   - Audit triage decisions periodically

## Next Steps

1. ✅ Set up PAT_TOKEN secret
2. ✅ Set up CURSOR_API_KEY secret
3. ✅ Update production repos list in workflow
4. ✅ Test with auto_dismiss: false
5. ✅ Review results
6. ✅ Enable auto_dismiss: true for production

## Support

If you encounter issues:
1. Check workflow logs for specific error messages
2. Verify all secrets are set correctly
3. Test with a single repository first
4. Review the troubleshooting section above

