#!/usr/bin/env bash

set -euo pipefail  # Exit on error, undefined vars, pipe failures

###############################################################################
# Two-phase AI triage for Dependabot alerts:
# 1. Understand repository dependency usage
# 2. Analyze Dependabot alerts with full context
###############################################################################

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Environment setup - these must be set by caller
: "${OWNER:?Error: OWNER environment variable is required}"
: "${REPO:?Error: REPO environment variable is required}"
GH_TOKEN="${GITHUB_TOKEN}"
CURSOR_MODEL="${CURSOR_MODEL:-auto}"
# Transient Cursor API errors (resource_exhausted, unavailable, connection loss): retry with backoff
CURSOR_MAX_RETRIES="${CURSOR_MAX_RETRIES:-5}"
CURSOR_RETRY_DELAY_SEC="${CURSOR_RETRY_DELAY_SEC:-20}"
# If Phase 1 still fails after retries, continue with a minimal profile (lower triage quality)
ALLOW_PHASE1_FALLBACK="${ALLOW_PHASE1_FALLBACK:-false}"
ALERT_STATE="${ALERT_STATE:-open}"
MAX_ALERTS="${MAX_ALERTS:-300}"
AUTO_DISMISS="${AUTO_DISMISS:-false}"
SUMMARY_PATH="${GITHUB_STEP_SUMMARY:-}"

# Temporary files
TEMP_DIR=$(mktemp -d)
ALERTS_FILE="${TEMP_DIR}/alerts.json"
DEPENDENCY_PROFILE_FILE="repository_dependency_profile.txt"
RESULTS_FILE="dependabot-triage-results.json"

trap 'rm -rf "${TEMP_DIR}"' EXIT

###############################################################################
# Helper Functions
###############################################################################

log_info() {
    echo -e "${CYAN}ℹ️  $*${NC}"
}

log_success() {
    echo -e "${GREEN}✅ $*${NC}"
}

log_warning() {
    echo -e "${YELLOW}⚠️  $*${NC}"
}

log_error() {
    echo -e "${RED}❌ $*${NC}"
}

log_phase() {
    echo ""
    echo -e "${BLUE}═══════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}$*${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════${NC}"
}

###############################################################################
# Cursor Agent Runner
###############################################################################

_cursor_run_once() {
    local prompt="$1"
    local output_file="${TEMP_DIR}/cursor_output_$$_${RANDOM}.txt"

    echo "🤖 Running cursor-agent..."

    if cursor-agent --trust \
        --print \
        --model "${CURSOR_MODEL}" \
        --output-format text \
        "${prompt}" > "${output_file}" 2>&1; then

        local char_count=$(wc -c < "${output_file}")
        log_success "Response received (${char_count} chars)"
        cat "${output_file}"
        rm -f "${output_file}"
        return 0
    else
        log_error "Cursor error occurred"
        cat "${output_file}" >&2
        rm -f "${output_file}"
        return 1
    fi
}

# Calls Cursor API with retries (handles resource_exhausted, unavailable, provider flakes).
cursor_run() {
    local prompt="$1"
    local max_attempts="${CURSOR_MAX_RETRIES}"
    local delay="${CURSOR_RETRY_DELAY_SEC}"
    local attempt=1
    local output

    if ! [[ "${max_attempts}" =~ ^[1-9][0-9]*$ ]]; then
        max_attempts=5
    fi

    while [ "${attempt}" -le "${max_attempts}" ]; do
        if output=$(_cursor_run_once "${prompt}"); then
            echo "${output}"
            return 0
        fi
        if [ "${attempt}" -lt "${max_attempts}" ]; then
            log_warning "Cursor attempt ${attempt}/${max_attempts} failed; retrying in ${delay}s..."
            sleep "${delay}"
            delay=$((delay * 2))
        fi
        attempt=$((attempt + 1))
    done

    log_error "Cursor failed after ${max_attempts} attempt(s)"
    return 1
}

# Minimal profile when Phase 1 AI fails (optional; triage continues with less context).
write_phase1_fallback_profile() {
    {
        echo "**Repository dependency profile (fallback — Phase 1 AI analysis failed after retries)**"
        echo ""
        echo "Repository: ${OWNER}/${REPO}"
        echo "Manifest / lockfile hints (best-effort):"
        find . -maxdepth 5 \( \
            -name 'package.json' -o -name 'package-lock.json' -o -name 'yarn.lock' -o -name 'pnpm-lock.yaml' \
            -o -name 'pom.xml' -o -name 'build.gradle' -o -name 'build.gradle.kts' \
            -o -name 'go.mod' -o -name 'Cargo.toml' -o -name 'requirements.txt' -o -name 'Pipfile' \
            \) 2>/dev/null | head -40 || true
        echo ""
        echo "Use UNCERTAIN liberally; Phase 2 did not receive full codebase context."
    } > "${DEPENDENCY_PROFILE_FILE}"
}

###############################################################################
# GitHub API Functions
###############################################################################

get_dependabot_alerts() {
    log_info "Fetching Dependabot alerts from GitHub API..."
    
    local alerts="[]"
    local url="https://api.github.com/repos/${OWNER}/${REPO}/dependabot/alerts?state=${ALERT_STATE}&per_page=100"
    local page_count=0
    
    while [ -n "${url}" ]; do
        # Check current count safely
        local current_count=$(echo "${alerts}" | jq 'length // 0' 2>/dev/null || echo "0")
        if ! [[ "${current_count}" =~ ^[0-9]+$ ]]; then
            current_count=0
        fi
        
        # Break if we've reached the limit
        if [ "${current_count}" -ge "${MAX_ALERTS}" ]; then
            break
        fi
        
        page_count=$((page_count + 1))
        
        # Calculate per_page to not exceed MAX_ALERTS
        local remaining=$((MAX_ALERTS - current_count))
        local per_page=100
        if [ "${remaining}" -lt 100 ] && [ "${remaining}" -gt 0 ]; then
            per_page=${remaining}
        fi
        
        # Update per_page in URL if needed (only for first request, subsequent use Link header)
        if [ ${page_count} -eq 1 ] && [ ${per_page} -lt 100 ]; then
            url="https://api.github.com/repos/${OWNER}/${REPO}/dependabot/alerts?state=${ALERT_STATE}&per_page=${per_page}"
        fi
        
        local response
        local http_code
        local link_header
        
        # Use -D to dump headers to file, then get body separately
        local headers_file="${TEMP_DIR}/headers_$$_${page_count}.txt"
        local body_file="${TEMP_DIR}/body_$$_${page_count}.txt"
        
        # Get headers and body separately using -D and -o
        local curl_exit=0
        http_code=$(curl -s -o "${body_file}" -w "%{http_code}" -D "${headers_file}" \
            -H "Authorization: Bearer ${GH_TOKEN}" \
            -H "Accept: application/vnd.github+json" \
            -H "X-GitHub-Api-Version: 2022-11-28" \
            "${url}" \
            --max-time 60) || curl_exit=$?
        
        # Check if curl failed
        if [ ${curl_exit} -ne 0 ]; then
            log_error "curl failed with exit code ${curl_exit} for URL: ${url}"
            rm -f "${headers_file}" "${body_file}"
            break
        fi
        
        # Extract Link header (case-insensitive)
        link_header=""
        if [ -f "${headers_file}" ]; then
            link_header=$(grep -i "^link:" "${headers_file}" 2>/dev/null | sed 's/^[Ll]ink: //' | tr -d '\r' || echo "")
        fi
        
        # Get body from file
        local body=""
        if [ -f "${body_file}" ]; then
            body=$(cat "${body_file}" 2>/dev/null || echo "")
            local body_size=$(wc -c < "${body_file}" 2>/dev/null || echo "0")
            if [ "${body_size}" -eq 0 ]; then
                log_warning "Body file exists but is empty (${body_size} bytes)"
            fi
        else
            log_warning "Body file not found: ${body_file}"
        fi
        
        # Cleanup temp files
        rm -f "${headers_file}" "${body_file}"
        
        # Validate body is not empty
        if [ -z "${body}" ]; then
            log_warning "Empty response body for URL: ${url}"
            log_warning "HTTP code: ${http_code}"
            # If 200 but empty body, this is unexpected - might be an empty array
            if [ "${http_code}" = "200" ]; then
                # Empty array [] is valid - might mean no alerts
                log_info "Received 200 OK with empty body - this might be valid (no alerts)"
            fi
        fi
        
        case "${http_code}" in
            200)
                # Handle empty body as empty array
                if [ -z "${body}" ]; then
                    log_info "Empty response body - treating as empty array []"
                    body="[]"
                fi
                
                # Validate that body is valid JSON before processing
                if ! echo "${body}" | jq empty 2>/dev/null; then
                    log_error "Invalid JSON in response body"
                    log_error "Body preview: $(echo "${body}" | head -c 200)"
                    break
                fi
                
                local batch=$(echo "${body}" | jq '. // []')
                local count=$(echo "${batch}" | jq 'length // 0')
                
                # Ensure count is a valid number
                if ! [[ "${count}" =~ ^[0-9]+$ ]]; then
                    log_error "Invalid count value: ${count}"
                    log_error "Batch preview: $(echo "${batch}" | head -c 200)"
                    break
                fi
                
                if [ "${count}" -eq 0 ]; then
                    log_info "No more alerts in this batch"
                    break
                fi
                
                log_info "📄 Batch ${page_count}: ${count} Dependabot alerts"
                
                # Ensure both alerts and batch are arrays before merging
                local alerts_type=$(echo "${alerts}" | jq -r 'type' 2>/dev/null || echo "null")
                local batch_type=$(echo "${batch}" | jq -r 'type' 2>/dev/null || echo "null")
                
                if [ "${alerts_type}" != "array" ]; then
                    log_error "alerts is not an array (type: ${alerts_type}), resetting to []"
                    alerts="[]"
                fi
                
                if [ "${batch_type}" != "array" ]; then
                    log_error "batch is not an array (type: ${batch_type}), skipping batch"
                    log_error "Batch content: $(echo "${batch}" | head -c 200)"
                    break
                fi
                
                # Merge with existing alerts using array concatenation
                # Use temp files to avoid "Argument list too long" error for large batches
                local alerts_file="${TEMP_DIR}/alerts_merge_${page_count}.json"
                local batch_file="${TEMP_DIR}/batch_merge_${page_count}.json"
                
                echo "${alerts}" > "${alerts_file}"
                echo "${batch}" > "${batch_file}"
                
                local merged_result
                if ! merged_result=$(jq -s '. | add' "${alerts_file}" "${batch_file}" 2>&1); then
                    log_error "Failed to merge alerts batch"
                    log_error "jq error: ${merged_result}"
                    log_error "alerts preview: $(echo "${alerts}" | head -c 200)"
                    log_error "batch preview: $(echo "${batch}" | head -c 200)"
                    rm -f "${alerts_file}" "${batch_file}"
                    break
                fi
                
                rm -f "${alerts_file}" "${batch_file}"
                alerts="${merged_result}"
                
                # Check if we've reached the limit
                local current_total=$(echo "${alerts}" | jq 'length // 0')
                if ! [[ "${current_total}" =~ ^[0-9]+$ ]]; then
                    log_error "Invalid total count: ${current_total}"
                    break
                fi
                
                if [ "${current_total}" -ge "${MAX_ALERTS}" ]; then
                    break
                fi
                
                # Extract next URL from Link header if present
                url=""
                if [ -n "${link_header}" ]; then
                    # Parse Link header: <url>; rel="next", <url>; rel="prev"
                    # Link header format: <https://api.github.com/...>; rel="next", <https://api.github.com/...>; rel="prev"
                    # Use sed to extract URL from rel="next" - more compatible than grep -o
                    next_url=$(echo "${link_header}" | sed -n 's/.*<\([^>]*\)>; rel="next".*/\1/p' | head -1)
                    if [ -n "${next_url}" ]; then
                        url="${next_url}"
                    fi
                fi
                ;;
            403)
                log_error "Access denied to Dependabot alerts"
                log_info "Token may lack 'security-events:read' permission"
                break
                ;;
            *)
                log_error "API error ${http_code}"
                if [ -n "${body}" ]; then
                    log_error "Response body: ${body}"
                fi
                break
                ;;
        esac
    done
    
    echo "${alerts}" > "${ALERTS_FILE}"
    local total=$(echo "${alerts}" | jq 'length // 0' 2>/dev/null || echo "0")
    if ! [[ "${total}" =~ ^[0-9]+$ ]]; then
        total=0
    fi
    log_success "Total Dependabot alerts fetched: ${total}"
    
    return 0
}

###############################################################################
# Phase 1: Repository Dependency Understanding
###############################################################################

phase1_understand_dependencies() {
    log_phase "🔍 PHASE 1: Repository Dependency Analysis"
    
    local prompt="You are a security expert analyzing a repository's dependency usage for vulnerability assessment.

Please analyze this ENTIRE repository and provide a comprehensive dependency usage profile:

**What I need to understand:**

1. **Package Manager & Dependencies**
   - What package managers are used? (npm, pip, maven, gradle, go mod, etc.)
   - What are the main dependencies and their purposes?
   - Are there lock files present? (package-lock.json, yarn.lock, Pipfile.lock, etc.)

2. **Dependency Usage Patterns**
   - Which dependencies are actually imported/used in the codebase?
   - Are there dependencies declared but never used?
   - Are there dev dependencies vs production dependencies?
   - What dependencies are critical to the application's core functionality?

3. **Dependency Context**
   - Are vulnerable dependencies used in production code paths?
   - Are they only used in test files or development tools?
   - Are they transitive dependencies (dependencies of dependencies)?
   - What parts of the application would be affected if a dependency is vulnerable?

4. **Deployment & Runtime Context**
   - How are dependencies deployed? (containerized, serverless, etc.)
   - Are there network restrictions that might mitigate vulnerabilities?
   - Is the application exposed to the internet or internal-only?
   - What are the main attack surfaces related to dependencies?

5. **Security Controls**
   - Are there dependency scanning tools already in place?
   - Are there security policies for dependency updates?
   - Are there any custom security wrappers around dependencies?

**Please provide a detailed analysis that I can reference when evaluating Dependabot vulnerability alerts.**

Focus on information that would help determine if dependency vulnerabilities are actually exploitable in this specific application context, and whether dependencies are truly used in vulnerable ways."
    
    local dependency_profile
    if dependency_profile=$(cursor_run "${prompt}"); then
        echo "${dependency_profile}" > "${DEPENDENCY_PROFILE_FILE}"
        log_success "Repository dependency profile generated"
        return 0
    fi

    log_error "Failed to generate dependency profile (AI)"
    if [ "${ALLOW_PHASE1_FALLBACK}" = "true" ]; then
        log_warning "ALLOW_PHASE1_FALLBACK=true — writing minimal profile and continuing (Phase 2 quality reduced)"
        write_phase1_fallback_profile
        return 0
    fi
    return 1
}

###############################################################################
# Phase 2: Alert Analysis
###############################################################################

parse_json_response() {
    local response="$1"
    local temp_file="${TEMP_DIR}/json_parse_${RANDOM}.txt"
    echo "${response}" > "${temp_file}"
    
    # Method 1: Try to extract JSON from code fences (```json ... ``` or ``` ... ```)
    local json_in_fence=$(sed -n '/```json/,/```/p' "${temp_file}" 2>/dev/null | sed '1d;$d' | jq . 2>/dev/null)
    if [ -n "${json_in_fence}" ] && [ "${json_in_fence}" != "null" ]; then
        echo "${json_in_fence}"
        rm -f "${temp_file}"
        return 0
    fi
    
    # Method 2: Try code fences without language specifier
    json_in_fence=$(sed -n '/```$/,/```$/p' "${temp_file}" 2>/dev/null | sed '1d;$d' | jq . 2>/dev/null)
    if [ -n "${json_in_fence}" ] && [ "${json_in_fence}" != "null" ]; then
        echo "${json_in_fence}"
        rm -f "${temp_file}"
        return 0
    fi
    
    # Method 3: Use Python to extract JSON (more reliable for multi-line JSON)
    if command -v python3 >/dev/null 2>&1; then
        local python_json=$(cat "${temp_file}" | python3 << 'PYTHON_EOF'
import sys
import json
import re

text = sys.stdin.read()

# Try to find JSON in code fences
fence_match = re.search(r'```(?:json)?\s*\n(.*?)\n```', text, re.DOTALL)
if fence_match:
    try:
        json_obj = json.loads(fence_match.group(1))
        print(json.dumps(json_obj))
        sys.exit(0)
    except:
        pass

# Try to find JSON object by matching braces
brace_start = text.find('{')
if brace_start != -1:
    brace_count = 0
    json_end = -1
    for i, char in enumerate(text[brace_start:], start=brace_start):
        if char == '{':
            brace_count += 1
        elif char == '}':
            brace_count -= 1
            if brace_count == 0:
                json_end = i + 1
                break
    
    if json_end > brace_start:
        try:
            json_str = text[brace_start:json_end]
            json_obj = json.loads(json_str)
            print(json.dumps(json_obj))
            sys.exit(0)
        except Exception as e:
            # Try to fix common JSON issues
            try:
                # Remove trailing commas
                json_str = re.sub(r',\s*}', '}', json_str)
                json_str = re.sub(r',\s*]', ']', json_str)
                json_obj = json.loads(json_str)
                print(json.dumps(json_obj))
                sys.exit(0)
            except:
                pass

sys.exit(1)
PYTHON_EOF
)
        if [ -n "${python_json}" ] && [ "${python_json}" != "null" ]; then
            # Validate the extracted JSON
            if echo "${python_json}" | jq empty 2>/dev/null; then
                echo "${python_json}"
                rm -f "${temp_file}"
                return 0
            fi
        fi
    fi
    
    # Method 4: Try simple single-line JSON extraction
    local simple_json=$(echo "${response}" | grep -oP '\{[^{}]*(?:\{[^{}]*\}[^{}]*)*\}' | head -n1)
    if [ -n "${simple_json}" ]; then
        if echo "${simple_json}" | jq empty 2>/dev/null; then
            echo "${simple_json}"
            rm -f "${temp_file}"
            return 0
        fi
    fi
    
    rm -f "${temp_file}"
    return 1
}

analyze_single_alert() {
    local alert_json="$1"
    local dependency_profile="$2"
    local alert_index="$3"
    local total_alerts="$4"
    
    echo "" >&2
    echo "--- Alert ${alert_index}/${total_alerts} ---" >&2
    
    # Extract alert details using jq
    local alert_number=$(echo "${alert_json}" | jq -r '.number // "N/A"')
    local dependency_package=$(echo "${alert_json}" | jq -r '.dependency.package.name // "unknown"')
    local dependency_ecosystem=$(echo "${alert_json}" | jq -r '.dependency.package.ecosystem // "unknown"')
    local vulnerability_id=$(echo "${alert_json}" | jq -r '.security_advisory.ghsa_id // .security_advisory.cve_id // "unknown"')
    local severity=$(echo "${alert_json}" | jq -r '.security_advisory.severity // "unknown"')
    local summary=$(echo "${alert_json}" | jq -r '.security_advisory.summary // "No summary"')
    local manifest_path=$(echo "${alert_json}" | jq -r '.dependency.manifest_path // "unknown"')
    local vulnerable_version_range=$(echo "${alert_json}" | jq -r '.security_vulnerability.vulnerable_version_range // "unknown"')
    local first_patched_version=$(echo "${alert_json}" | jq -r '.security_vulnerability.first_patched_version // "none"')
    local dependency_type=$(echo "${alert_json}" | jq -r '.dependency.scope // "unknown"')
    
    echo "📦 ${dependency_package} (${dependency_ecosystem}) - ${vulnerability_id}" >&2
    echo "📍 ${manifest_path}" >&2
    
    # Create context-aware prompt
    local prompt="You are a security expert with COMPLETE understanding of this repository's dependency usage.

**REPOSITORY DEPENDENCY PROFILE:**
${dependency_profile}

**DEPENDABOT ALERT TO ANALYZE:**
- Alert ID: ${alert_number}
- Dependency: ${dependency_package} (${dependency_ecosystem})
- Vulnerability: ${vulnerability_id}
- Severity: ${severity}
- Summary: ${summary}
- Manifest: ${manifest_path}
- Vulnerable Version Range: ${vulnerable_version_range}
- First Patched Version: ${first_patched_version}
- Dependency Type: ${dependency_type}

**ANALYSIS TASK:**
Given your complete understanding of this repository's dependency usage, determine if this Dependabot alert represents a real security vulnerability that needs attention.

**Consider:**
1. Is this dependency actually imported and used in the codebase? (Check if it's declared but never used)
2. Is the vulnerable code path actually reachable? (Is the vulnerable function/class used?)
3. Is this a dev dependency that doesn't affect production?
4. Is this a transitive dependency that's not directly used?
5. Are there mitigations in place? (Network isolation, firewalls, etc.)
6. Is the vulnerability severity appropriate for this application's context?
7. Would updating to the patched version break compatibility?

**RESPOND WITH ONLY THIS JSON:**
{
  \"classification\": \"TP|FP|UNCERTAIN\",
  \"certainty\": <0-100>,
  \"rationale\": \"<detailed explanation considering full repository context>\",
  \"repository_context_factors\": [\"<key factors from dependency analysis that influenced decision>\"],
  \"exploitability\": \"<none|low|medium|high>\",
  \"is_actually_used\": <true|false>,
  \"fix_suggestion\": \"<recommendation or 'not applicable'>\"
}

**Examples of context-aware reasoning:**
- \"FP: Dependency declared but never imported or used in codebase\"
- \"FP: Vulnerable function in dependency is never called in application code\"
- \"FP: Dev dependency only, doesn't affect production deployment\"
- \"TP: Dependency used in production API endpoint, vulnerable code path is reachable\"
- \"TP: Transitive dependency but vulnerable function is called through parent dependency\"
- \"UNCERTAIN: Dependency is used but unclear if vulnerable code path is reachable\""
    
    # Get AI analysis
    local ai_response
    if ! ai_response=$(cursor_run "${prompt}"); then
        ai_response="Error: Cursor failed to respond"
    fi
    
    # Debug: Log first 500 chars of response for troubleshooting (only if verbose)
    if [ "${DEBUG:-false}" = "true" ]; then
        log_info "AI response preview: $(echo "${ai_response}" | head -c 500)..."
    fi
    
    # Parse response
    local parsed
    if parsed=$(parse_json_response "${ai_response}" 2>/dev/null); then
        local classification=$(echo "${parsed}" | jq -r '.classification // "UNCERTAIN"')
        # Normalize classification to uppercase and validate
        classification=$(echo "${classification}" | tr '[:lower:]' '[:upper:]')
        if [[ ! "${classification}" =~ ^(TP|FP|UNCERTAIN)$ ]]; then
            log_warning "Invalid classification '${classification}', defaulting to UNCERTAIN" >&2
            classification="UNCERTAIN"
        fi
        
        local certainty=$(echo "${parsed}" | jq -r '.certainty // 30')
        # Ensure certainty is a number between 0-100
        if ! [[ "${certainty}" =~ ^[0-9]+$ ]] || [ "${certainty}" -lt 0 ] || [ "${certainty}" -gt 100 ]; then
            certainty=30
        fi
        
        local rationale=$(echo "${parsed}" | jq -r '.rationale // "Could not parse AI response"' | head -c 1500)
        # Ensure context_factors is always valid JSON array
        local context_factors=$(echo "${parsed}" | jq -c '.repository_context_factors // []' 2>/dev/null || echo "[]")
        # Validate it's actually valid JSON
        if ! echo "${context_factors}" | jq empty 2>/dev/null; then
            context_factors="[]"
        fi
        local exploitability=$(echo "${parsed}" | jq -r '.exploitability // "unknown"')
        local is_actually_used=$(echo "${parsed}" | jq -r '.is_actually_used // false')
        local fix_suggestion=$(echo "${parsed}" | jq -r '.fix_suggestion // "Manual review required"' | head -c 500)
    else
        # Fallback for unparseable responses
        log_warning "Failed to parse AI response, defaulting to UNCERTAIN" >&2
        if [ "${DEBUG:-false}" = "true" ]; then
            log_info "Raw AI response (first 500 chars): $(echo "${ai_response}" | head -c 500)" >&2
        fi
        classification="UNCERTAIN"
        certainty=30
        rationale="Could not parse AI response"
        context_factors="[]"
        exploitability="unknown"
        is_actually_used="false"
        fix_suggestion="Manual review required"
    fi
    
    # Convert to our format
    local ai_label
    case "${classification}" in
        TP) ai_label="real_issue" ;;
        FP) ai_label="likely_false_positive" ;;
        UNCERTAIN) ai_label="needs_review" ;;
        *)
            log_warning "Unexpected classification '${classification}', defaulting to needs_review" >&2
            ai_label="needs_review"
            ;;
    esac
    
    # Log the classification decision for debugging
    if [ "${DEBUG:-false}" = "true" ]; then
        log_info "Classification: ${classification} -> ${ai_label}, Certainty: ${certainty}%" >&2
        log_info "Rationale: ${rationale}" >&2
    fi
    
    local confidence
    if [ "${certainty}" -ge 80 ]; then
        confidence="high"
    elif [ "${certainty}" -ge 50 ]; then
        confidence="medium"
    else
        confidence="low"
    fi
    
    echo "🎯 Result: ${ai_label} (confidence: ${confidence}, certainty: ${certainty}%)" >&2
    
    # Build result JSON
    local dismissed=false
    
    # Auto-dismiss if configured (matching Python logic exactly)
    if [ "${AUTO_DISMISS}" = "true" ] && [ "${ai_label}" = "likely_false_positive" ]; then
        if [ "${confidence}" = "high" ] || [ "${confidence}" = "medium" ]; then
            if [ "${certainty}" -ge 70 ]; then
                log_info "Attempting auto-dismiss..." >&2
                
                local dismiss_url="https://api.github.com/repos/${OWNER}/${REPO}/dependabot/alerts/${alert_number}"
                local dismiss_response
                local dismiss_code
                
                dismiss_response=$(curl -s -w "\n%{http_code}" -X PATCH \
                    -H "Authorization: Bearer ${GH_TOKEN}" \
                    -H "Accept: application/vnd.github+json" \
                    -H "X-GitHub-Api-Version: 2022-11-28" \
                    "${dismiss_url}" \
                    -d "{\"state\":\"dismissed\",\"dismissed_reason\":\"false_positive\",\"dismissed_comment\":\"Context-aware AI analysis: ${rationale}\"}" \
                    --max-time 60)
                
                dismiss_code=$(echo "${dismiss_response}" | tail -n1)
                dismiss_body=$(echo "${dismiss_response}" | head -n-1)
                
                if [ "${dismiss_code}" = "200" ] || [ "${dismiss_code}" = "201" ]; then
                    dismissed=true
                    log_success "Auto-dismissed alert #${alert_number}" >&2
                else
                    log_warning "Dismiss failed for alert #${alert_number}: HTTP ${dismiss_code}" >&2
                    log_warning "Response: ${dismiss_body}" >&2
                    if [ "${dismiss_code}" = "403" ]; then
                        log_error "Permission denied. Token may lack 'security-events:write' permission." >&2
                    elif [ "${dismiss_code}" = "401" ]; then
                        log_error "Authentication failed. Check token permissions." >&2
                    fi
                fi
            fi
        fi
    fi
    
    # Ensure certainty is a valid number
    if ! [[ "${certainty}" =~ ^[0-9]+$ ]]; then
        certainty=30
    fi
    
    # Ensure context_factors is valid JSON array
    local context_factors_json
    context_factors_json=$(echo "${context_factors}" | jq . 2>/dev/null || echo "[]")
    
    # Ensure dismissed is valid JSON boolean
    local dismissed_json
    if [ "${dismissed}" = "true" ]; then
        dismissed_json="true"
    else
        dismissed_json="false"
    fi
    
    # Ensure is_actually_used is valid JSON boolean
    local is_used_json
    if [ "${is_actually_used}" = "true" ]; then
        is_used_json="true"
    else
        is_used_json="false"
    fi
    
    # Output result as JSON
    local temp_result="${TEMP_DIR}/result_${alert_number}.json"
    if ! jq -n \
        --arg alert_number "${alert_number}" \
        --arg dependency "${dependency_package}" \
        --arg ecosystem "${dependency_ecosystem}" \
        --arg vulnerability "${vulnerability_id}" \
        --arg severity "${severity}" \
        --arg manifest_path "${manifest_path}" \
        --arg vulnerable_range "${vulnerable_version_range}" \
        --arg patched_version "${first_patched_version}" \
        --arg dependency_type "${dependency_type}" \
        --arg ai_label "${ai_label}" \
        --arg confidence "${confidence}" \
        --argjson certainty_score "${certainty}" \
        --arg reason "${rationale}" \
        --argjson context_factors "${context_factors_json}" \
        --arg exploitability "${exploitability}" \
        --argjson is_actually_used "${is_used_json}" \
        --arg suggestions "${fix_suggestion}" \
        --argjson dismissed "${dismissed_json}" \
        '{
            alert_number: $alert_number,
            dependency: $dependency,
            ecosystem: $ecosystem,
            vulnerability: $vulnerability,
            severity: $severity,
            manifest_path: $manifest_path,
            vulnerable_version_range: $vulnerable_range,
            patched_version: $patched_version,
            dependency_type: $dependency_type,
            ai_label: $ai_label,
            confidence: $confidence,
            certainty_score: $certainty_score,
            reason: $reason,
            context_factors: $context_factors,
            exploitability: $exploitability,
            is_actually_used: $is_actually_used,
            suggestions: $suggestions,
            dismissed: $dismissed
        }' > "${temp_result}" 2>&1; then
        log_error "Failed to create JSON for alert ${alert_number}"
        cat "${temp_result}" >&2
        # Return a minimal valid JSON object
        jq -n \
            --arg alert_number "${alert_number}" \
            --arg dependency "${dependency_package}" \
            --arg vulnerability "${vulnerability_id}" \
            '{
                alert_number: $alert_number,
                dependency: $dependency,
                vulnerability: $vulnerability,
                ai_label: "needs_review",
                confidence: "low",
                certainty_score: 0,
                reason: "Error generating result",
                context_factors: [],
                exploitability: "unknown",
                is_actually_used: false,
                suggestions: "Manual review required",
                dismissed: false
            }'
        return 1
    fi
    
    cat "${temp_result}"
    rm -f "${temp_result}"
}

phase2_analyze_alerts() {
    local dependency_profile="$1"
    local alerts_count=$(jq 'length // 0' "${ALERTS_FILE}" 2>/dev/null || echo "0")
    
    # Ensure alerts_count is a valid number
    if ! [[ "${alerts_count}" =~ ^[0-9]+$ ]]; then
        alerts_count=0
    fi
    
    log_phase "🎯 PHASE 2: Dependabot Alert Analysis with Full Context (${alerts_count} alerts)"
    
    # Early return if no alerts
    if [ "${alerts_count}" -eq 0 ] || [ ! -s "${ALERTS_FILE}" ]; then
        log_info "No alerts to analyze"
        echo "[]" > "${RESULTS_FILE}"
        return 0
    fi
    
    local triaged_alerts="[]"
    local index=1
    
    # Ensure alerts_count is a valid positive integer
    if ! [[ "${alerts_count}" =~ ^[0-9]+$ ]] || [ "${alerts_count}" -le 0 ]; then
        log_error "Invalid alerts count: ${alerts_count}"
        echo "[]" > "${RESULTS_FILE}"
        return 1
    fi
    
    while [ "${index}" -le "${alerts_count}" ]; do
        local alert=$(jq ".[$((index - 1))]" "${ALERTS_FILE}")
        
        local result
        local error_output="${TEMP_DIR}/alert_${index}_error.txt"
        
        # Temporarily disable exit on error for this command
        set +e
        # Capture both stdout and stderr separately
        result=$(analyze_single_alert "${alert}" "${dependency_profile}" "${index}" "${alerts_count}" 2>"${error_output}")
        local analyze_exit=$?
        set -e
        
        if [ ${analyze_exit} -eq 0 ]; then
        # The result should now be clean JSON (log messages go to stderr)
        # But just in case, extract only valid JSON
        local clean_result=$(echo "${result}" | jq -c . 2>/dev/null || echo "")
            
            # Validate result is valid JSON before merging
            if [ -n "${clean_result}" ] && echo "${clean_result}" | jq empty 2>/dev/null; then
                set +e
                triaged_alerts=$(echo "${triaged_alerts}" | jq --argjson new "${clean_result}" '. + [$new]' 2>/dev/null)
                local merge_exit=$?
                set -e
                if [ ${merge_exit} -ne 0 ]; then
                    log_warning "Failed to merge result for alert ${index}, skipping..."
                    log_info "Merge error - result was: $(echo "${clean_result}" | head -c 200)..."
                fi
            else
                log_warning "Invalid JSON result for alert ${index}, skipping..."
                log_info "Raw result preview: $(echo "${result}" | tail -20 | head -c 300)..."
                if [ -s "${error_output}" ]; then
                    log_info "Error output: $(cat "${error_output}" | head -c 200)..."
                fi
            fi
        else
            log_warning "Failed to analyze alert ${index} (exit code: ${analyze_exit}), skipping..."
            if [ -s "${error_output}" ]; then
                log_info "Error output: $(cat "${error_output}" | head -c 200)..."
            fi
        fi
        
        rm -f "${error_output}"
        
        index=$((index + 1))
    done
    
    echo "${triaged_alerts}" > "${RESULTS_FILE}"
}

###############################################################################
# Summary Generation
###############################################################################

generate_summary() {
    local results="$1"
    
    local total=$(echo "${results}" | jq 'length')
    local tp_count=$(echo "${results}" | jq '[.[] | select(.ai_label == "real_issue")] | length')
    local fp_count=$(echo "${results}" | jq '[.[] | select(.ai_label == "likely_false_positive")] | length')
    local uncertain_count=$(echo "${results}" | jq '[.[] | select(.ai_label == "needs_review")] | length')
    local dismissed_count=$(echo "${results}" | jq '[.[] | select(.dismissed == true)] | length')
    
    echo ""
    log_phase "🎉 TRIAGE COMPLETE!"
    echo "📊 Total: ${total} | TP: ${tp_count} | FP: ${fp_count} | Review: ${uncertain_count}"
    log_success "Auto-dismissed: ${dismissed_count}"
    
    # Generate markdown summary for GitHub Actions
    if [ -n "${SUMMARY_PATH}" ]; then
        {
            echo "# 🤖 Context-Aware AI Dependabot Alert Triage Results"
            echo ""
            echo "===Created with <3 by Shuvamoy==="
            echo "**Repository:** ${OWNER}/${REPO}"
            echo "**Analysis Approach:** Two-phase (Dependency Usage Analysis → Alert Analysis)"
            echo ""
            echo "## 📊 Summary"
            echo "- **Total Alerts Processed:** ${total}"
            echo "- **True Positives:** ${tp_count} (require attention)"
            echo "- **False Positives:** ${fp_count} (context-aware dismissal)"
            echo "- **Needs Review:** ${uncertain_count} (uncertain cases)"
            echo "- **Auto-dismissed:** ${dismissed_count}"
            echo ""
            echo "## 📋 Detailed Results"
            echo ""
            echo "| Alert # | Dependency | Vulnerability | Severity | Manifest | Classification | Confidence | Certainty | Used? | Dismissed | Reasoning |"
            echo "|---------|------------|---------------|----------|----------|----------------|------------|-----------|-------|-----------|----------|"
            
            # Add each alert row with reasoning
            echo "${results}" | jq -r '.[] | 
                (if .ai_label == "real_issue" then "🔴" 
                 elif .ai_label == "likely_false_positive" then "🟢" 
                 else "🟡" end) as $emoji |
                (if .is_actually_used then "✅" else "❌" end) as $used_icon |
                (if .dismissed then "✅" else "❌" end) as $dismissed_icon |
                (.reason // .rationale // "N/A" | gsub("\n"; " ") | gsub("\\|"; "&#124;") | .[0:100] + if length > 100 then "..." else "" end) as $reasoning |
                "| \(.alert_number) | `\(.dependency)` | `\(.vulnerability)` | \(.severity) | `\(.manifest_path)` | \($emoji) **\(.ai_label)** | \(.confidence) | \(.certainty_score)% | \($used_icon) | \($dismissed_icon) | \($reasoning) |"
            '
        } >> "${SUMMARY_PATH}"
    fi
}

###############################################################################
# Main Execution
###############################################################################

main() {
    log_phase "🚀 Starting Context-Aware AI Dependabot Alert Triage"
    echo "📂 Repository: ${OWNER}/${REPO}"
    echo "🤖 Model: ${CURSOR_MODEL}"
    echo ""
    
    # Phase 1: Understand the repository's dependency usage
    if ! phase1_understand_dependencies; then
        log_error "Phase 1 failed - aborting"
        exit 1
    fi
    
    local dependency_profile
    dependency_profile=$(cat "${DEPENDENCY_PROFILE_FILE}")
    
    # Get Dependabot alerts
    if ! get_dependabot_alerts; then
        log_error "Failed to fetch alerts"
        exit 1
    fi
    
    local alert_count=$(jq 'length // 0' "${ALERTS_FILE}" 2>/dev/null || echo "0")
    if ! [[ "${alert_count}" =~ ^[0-9]+$ ]]; then
        alert_count=0
    fi
    
    if [ "${alert_count}" -eq 0 ]; then
        log_info "ℹ️  No Dependabot alerts found"
        return 0
    fi
    
    # Phase 2: Analyze alerts with full context
    phase2_analyze_alerts "${dependency_profile}"
    
    # Generate summary
    local results
    results=$(cat "${RESULTS_FILE}")
    generate_summary "${results}"
    
    log_success "Context-aware Dependabot triage complete!"
}

# Error handler
error_handler() {
    local line_number=$1
    local error_code=$2
    log_error "Error occurred at line ${line_number} with exit code ${error_code}"
    log_error "This may be due to:"
    log_error "  - Invalid JSON from AI response"
    log_error "  - GitHub API access issues"
    log_error "  - Cursor agent failures"
    exit "${error_code}"
}

trap 'error_handler ${LINENO} $?' ERR

# Execute main function
main "$@"
