
#!/usr/bin/env bash

set -euo pipefail  # Exit on error, undefined vars, pipe failures

###############################################################################
# Simple two-phase AI triage:
# 1. Understand entire repository
# 2. Analyze alerts with full context
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
ALERT_STATE="${ALERT_STATE:-open}"
MAX_ALERTS="${MAX_ALERTS:-300}"
AUTO_DISMISS="${AUTO_DISMISS:-false}"
SUMMARY_PATH="${GITHUB_STEP_SUMMARY:-}"

# Temporary files
TEMP_DIR=$(mktemp -d)
ALERTS_FILE="${TEMP_DIR}/alerts.json"
SECURITY_PROFILE_FILE="repository_security_profile.txt"
RESULTS_FILE="context-aware-triage.json"

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

cursor_run() {
    local prompt="$1"
    local output_file="${TEMP_DIR}/cursor_output_$$_${RANDOM}.txt"
    
    echo "🤖 Running cursor-agent..."
    
    if cursor-agent \
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

###############################################################################
# GitHub API Functions
###############################################################################

get_codeql_alerts() {
    log_info "Fetching CodeQL alerts from GitHub API..."
    
    local alerts="[]"
    local page=1
    
    while [ "$(echo "${alerts}" | jq 'length')" -lt "${MAX_ALERTS}" ]; do
        local per_page=$((MAX_ALERTS - $(echo "${alerts}" | jq 'length')))
        [ ${per_page} -gt 100 ] && per_page=100
        
        local url="https://api.github.com/repos/${OWNER}/${REPO}/code-scanning/alerts"
        local response
        local http_code
        
        response=$(curl -s -w "\n%{http_code}" \
            -H "Authorization: Bearer ${GH_TOKEN}" \
            -H "Accept: application/vnd.github+json" \
            "${url}?state=${ALERT_STATE}&page=${page}&per_page=${per_page}&sort=created&direction=desc" \
            --max-time 60)
        
        http_code=$(echo "${response}" | tail -n1)
        local body=$(echo "${response}" | head -n-1)
        
        case "${http_code}" in
            200)
                # Filter to only CodeQL alerts (ignore other scanners)
                local batch=$(echo "${body}" | jq '.')
                local codeql_alerts=$(echo "${batch}" | jq '[.[] | select((.tool.name // "" | ascii_downcase) == "codeql")]')
                
                local count=$(echo "${codeql_alerts}" | jq 'length')
                
                if [ "${count}" -eq 0 ]; then
                    break
                fi
                
                log_info "📄 Page ${page}: ${count} CodeQL alerts"
                
                # Merge with existing alerts
                alerts=$(echo "${alerts}" | jq --argjson new "${codeql_alerts}" '. + $new')
                page=$((page + 1))
                ;;
            403)
                log_error "Access denied to code scanning alerts"
                log_info "Token may lack 'security-events:read' permission"
                break
                ;;
            *)
                log_error "API error ${http_code}"
                break
                ;;
        esac
    done
    
    echo "${alerts}" > "${ALERTS_FILE}"
    local total=$(echo "${alerts}" | jq 'length')
    log_success "Total CodeQL alerts fetched: ${total}"
    
    return 0
}

###############################################################################
# Phase 1: Repository Understanding
###############################################################################

phase1_understand_repository() {
    log_phase "🔍 PHASE 1: Repository Understanding"
    
    local prompt="You are a security expert analyzing a repository for vulnerability assessment. 

Please analyze this ENTIRE repository and provide a comprehensive security profile:

**What I need to understand:**

1. **Application Type & Architecture**
   - What kind of application is this? (web app, API, CLI, library, etc.)
   - What frameworks and languages are used?
   - What's the overall architecture pattern?

2. **Authentication & Authorization**
   - How does authentication work? (JWT, sessions, OAuth, etc.)
   - Is CSRF protection relevant for this application?
   - What authorization patterns are used?

3. **Data Handling & Security Controls**
   - How is user input handled and validated?
   - What database access patterns are used? (ORM, raw SQL, etc.)
   - Is there automatic output encoding/escaping?
   - What security middleware or controls are in place?

4. **Framework Security Features**
   - What built-in security features does the framework provide?
   - Are there any custom security implementations?
   - What third-party security libraries are used?

5. **Deployment & Runtime Context**
   - How is this application deployed? (containerized, serverless, etc.)
   - What are the main attack surfaces?
   - Any environment-specific security considerations?

**Please provide a detailed analysis that I can reference when evaluating security alerts.**

Focus on information that would help determine if common vulnerability classes (SQL injection, XSS, CSRF, etc.) are actually exploitable in this specific application context."
    
    local security_profile
    if security_profile=$(cursor_run "${prompt}"); then
        echo "${security_profile}" > "${SECURITY_PROFILE_FILE}"
        log_success "Repository security profile generated"
        return 0
    else
        log_error "Failed to generate security profile"
        return 1
    fi
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
    local security_profile="$2"
    local alert_index="$3"
    local total_alerts="$4"
    
    echo "" >&2
    echo "--- Alert ${alert_index}/${total_alerts} ---" >&2
    
    # Extract alert details using jq
    local alert_number=$(echo "${alert_json}" | jq -r '.number // "N/A"')
    local rule_id=$(echo "${alert_json}" | jq -r '.rule.id // "unknown"')
    local rule_name=$(echo "${alert_json}" | jq -r '.rule.name // "unknown"')
    local severity=$(echo "${alert_json}" | jq -r '.rule_severity // .severity // "unknown"')
    local path=$(echo "${alert_json}" | jq -r '.most_recent_instance.location.path // "unknown"')
    local start_line=$(echo "${alert_json}" | jq -r '.most_recent_instance.location.start_line // "0"')
    local message=$(echo "${alert_json}" | jq -r '
        if .most_recent_instance.message.text then
            .most_recent_instance.message.text
        elif (.most_recent_instance.message | type) == "string" then
            .most_recent_instance.message
        else
            "No message"
        end
    ')
    
    echo "📍 ${path}:${start_line} - ${rule_id}" >&2
    
    # Create context-aware prompt
    local prompt="You are a security expert with COMPLETE understanding of this repository.

**REPOSITORY SECURITY PROFILE:**
${security_profile}

**CODEQL ALERT TO ANALYZE:**
- Alert ID: ${alert_number}
- Rule: ${rule_id} - ${rule_name}
- Severity: ${severity}
- Location: ${path}:${start_line}
- Message: ${message}

**ANALYSIS TASK:**
Given your complete understanding of this repository's architecture, security controls, and context, determine if this CodeQL alert represents a real security vulnerability.

**Consider:**
1. Does the repository's authentication model make this vulnerability class irrelevant? (e.g., CSRF in JWT-only APIs)
2. Do framework-level protections mitigate this issue? (e.g., ORM preventing SQL injection)
3. Is this code path actually reachable and exploitable given the application architecture?
4. Are there security controls in place that CodeQL might not detect?

**RESPOND WITH ONLY THIS JSON:**
{
  \"classification\": \"TP|FP|UNCERTAIN\",
  \"certainty\": <0-100>,
  \"rationale\": \"<detailed explanation considering full repository context>\",
  \"repository_context_factors\": [\"<key factors from repo analysis that influenced decision>\"],
  \"exploitability\": \"<none|low|medium|high>\",
  \"fix_suggestion\": \"<recommendation or 'not applicable'>\"
}

**Examples of context-aware reasoning:**
- \"FP: CSRF alert in JWT-authenticated API - no session cookies used, CSRF not applicable\"
- \"FP: SQL injection in Django ORM query - parameterized queries used automatically\"  
- \"TP: XSS in template that bypasses framework auto-escaping using |safe filter\"
- \"FP: Path traversal in containerized environment with read-only filesystem\""
    
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
        local certainty=$(echo "${parsed}" | jq -r '.certainty // 30')
        local rationale=$(echo "${parsed}" | jq -r '.rationale // "Could not parse AI response"' | head -c 1500)
        # Ensure context_factors is always valid JSON array
        local context_factors=$(echo "${parsed}" | jq -c '.repository_context_factors // []' 2>/dev/null || echo "[]")
        # Validate it's actually valid JSON
        if ! echo "${context_factors}" | jq empty 2>/dev/null; then
            context_factors="[]"
        fi
        local exploitability=$(echo "${parsed}" | jq -r '.exploitability // "unknown"')
        local fix_suggestion=$(echo "${parsed}" | jq -r '.fix_suggestion // "Manual review required"' | head -c 500)
    else
        # Fallback for unparseable responses
        classification="UNCERTAIN"
        certainty=30
        rationale="Could not parse AI response"
        context_factors="[]"
        exploitability="unknown"
        fix_suggestion="Manual review required"
    fi
    
    # Convert to our format
    local ai_label
    case "${classification}" in
        TP) ai_label="real_issue" ;;
        FP) ai_label="likely_false_positive" ;;
        *) ai_label="needs_review" ;;
    esac
    
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
                
                local dismiss_url="https://api.github.com/repos/${OWNER}/${REPO}/code-scanning/alerts/${alert_number}"
                local dismiss_response
                local dismiss_code
                
                dismiss_response=$(curl -s -w "\n%{http_code}" -X PATCH \
                    -H "Authorization: Bearer ${GH_TOKEN}" \
                    -H "Accept: application/vnd.github+json" \
                    -H "X-GitHub-Api-Version: 2022-11-28" \
                    "${dismiss_url}" \
                    -d "{\"state\":\"dismissed\",\"dismissed_reason\":\"false positive\",\"dismissed_comment\":\"context-aware AI analysis\"}" \
                    --max-time 60)
                
                dismiss_code=$(echo "${dismiss_response}" | tail -n1)
                dismiss_body=$(echo "${dismiss_response}" | head -n-1)
                
                if [ "${dismiss_code}" = "200" ] || [ "${dismiss_code}" = "201" ]; then
                    dismissed=true
                    log_success "Auto-dismissed alert #${alert_number}: true" >&2
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
    
    # Output result as JSON
    # Use a temporary file to capture any jq errors
    local temp_result="${TEMP_DIR}/result_${alert_number}.json"
    if ! jq -n \
        --arg alert_number "${alert_number}" \
        --arg rule_id "${rule_id}" \
        --arg severity "${severity}" \
        --arg path "${path}" \
        --arg ai_label "${ai_label}" \
        --arg confidence "${confidence}" \
        --argjson certainty_score "${certainty}" \
        --arg reason "${rationale}" \
        --argjson context_factors "${context_factors_json}" \
        --arg exploitability "${exploitability}" \
        --arg suggestions "${fix_suggestion}" \
        --argjson dismissed "${dismissed_json}" \
        '{
            alert_number: $alert_number,
            rule_id: $rule_id,
            severity: $severity,
            path: $path,
            ai_label: $ai_label,
            confidence: $confidence,
            certainty_score: $certainty_score,
            reason: $reason,
            context_factors: $context_factors,
            exploitability: $exploitability,
            suggestions: $suggestions,
            dismissed: $dismissed
        }' > "${temp_result}" 2>&1; then
        log_error "Failed to create JSON for alert ${alert_number}"
        cat "${temp_result}" >&2
        # Return a minimal valid JSON object
        jq -n \
            --arg alert_number "${alert_number}" \
            --arg rule_id "${rule_id}" \
            --arg severity "${severity}" \
            --arg path "${path}" \
            '{
                alert_number: $alert_number,
                rule_id: $rule_id,
                severity: $severity,
                path: $path,
                ai_label: "needs_review",
                confidence: "low",
                certainty_score: 0,
                reason: "Error generating result",
                context_factors: [],
                exploitability: "unknown",
                suggestions: "Manual review required",
                dismissed: false
            }'
        return 1
    fi
    
    cat "${temp_result}"
    rm -f "${temp_result}"
}

phase2_analyze_alerts() {
    local security_profile="$1"
    local alerts_count=$(jq 'length' "${ALERTS_FILE}")
    
    log_phase "🎯 PHASE 2: Alert Analysis with Full Context (${alerts_count} alerts)"
    
    local triaged_alerts="[]"
    local index=1
    
    while [ "${index}" -le "${alerts_count}" ]; do
        local alert=$(jq ".[$((index - 1))]" "${ALERTS_FILE}")
        
        local result
        local error_output="${TEMP_DIR}/alert_${index}_error.txt"
        
        # Temporarily disable exit on error for this command
        set +e
        # Capture both stdout and stderr separately
        result=$(analyze_single_alert "${alert}" "${security_profile}" "${index}" "${alerts_count}" 2>"${error_output}")
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
            echo "# 🤖 Full Context-Aware AI Security Triage Results"
            echo ""
            echo "===Created with <3 by Shuvamoy==="
            echo "**Repository:** ${OWNER}/${REPO}"
            echo "**Analysis Approach:** Two-phase (Repository Understanding → Alert Analysis)"
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
            echo "| Alert # | Rule | Severity | Path | Classification | Confidence | Certainty | Context Factors | Dismissed |"
            echo "|---------|------|----------|------|----------------|------------|-----------|----------------|-----------|"
            
            # Add each alert row
            echo "${results}" | jq -r '.[] | 
                (if .ai_label == "real_issue" then "🔴" 
                 elif .ai_label == "likely_false_positive" then "🟢" 
                 else "🟡" end) as $emoji |
                (.context_factors[0:2] | join(", ")) as $context_preview |
                (if (.context_factors | length) > 2 then $context_preview + "..." else $context_preview end) as $context |
                (if .dismissed then "✅" else "❌" end) as $dismissed_icon |
                "| \(.alert_number) | `\(.rule_id)` | \(.severity) | `\(.path)` | \($emoji) **\(.ai_label)** | \(.confidence) | \(.certainty_score)% | \($context) | \($dismissed_icon) |"
            '
        } >> "${SUMMARY_PATH}"
    fi
}

###############################################################################
# Main Execution
###############################################################################

main() {
    log_phase "🚀 Starting Context-Aware AI Security Triage"
    echo "📂 Repository: ${OWNER}/${REPO}"
    echo "🤖 Model: ${CURSOR_MODEL}"
    echo ""
    
    # Phase 1: Understand the repository completely
    if ! phase1_understand_repository; then
        log_error "Phase 1 failed - aborting"
        exit 1
    fi
    
    local security_profile
    security_profile=$(cat "${SECURITY_PROFILE_FILE}")
    
    # Get CodeQL alerts
    if ! get_codeql_alerts; then
        log_error "Failed to fetch alerts"
        exit 1
    fi
    
    local alert_count=$(jq 'length' "${ALERTS_FILE}")
    if [ "${alert_count}" -eq 0 ]; then
        log_info "ℹ️  No CodeQL alerts found"
        return 0
    fi
    
    # Phase 2: Analyze alerts with full context
    phase2_analyze_alerts "${security_profile}"
    
    # Generate summary
    local results
    results=$(cat "${RESULTS_FILE}")
    generate_summary "${results}"
    
    log_success "Context-aware triage complete!"
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
