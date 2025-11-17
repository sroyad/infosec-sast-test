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

test_github_access() {
    local test_url="https://api.github.com/repos/${OWNER}/${REPO}"
    local response
    local http_code
    
    response=$(curl -s -w "\n%{http_code}" \
        -H "Authorization: Bearer ${GH_TOKEN}" \
        -H "Accept: application/vnd.github+json" \
        "${test_url}")
    
    http_code=$(echo "${response}" | tail -n1)
    
    case "${http_code}" in
        200)
            log_success "Successfully connected to ${OWNER}/${REPO}"
            return 0
            ;;
        404)
            log_error "Repository ${OWNER}/${REPO} not found or no access permissions"
            log_info "This may be a private repository with insufficient token permissions"
            return 1
            ;;
        *)
            log_error "GitHub API error: HTTP ${http_code}"
            echo "${response}" | head -n-1 | head -c 200
            return 1
            ;;
    esac
}

get_codeql_alerts() {
    log_info "Fetching CodeQL alerts from GitHub API..."
    
    # Test access first
    if ! test_github_access; then
        echo "[]" > "${ALERTS_FILE}"
        return 1
    fi
    
    local page=1
    local all_alerts="[]"
    local fetched_count=0
    
    while [ "${fetched_count}" -lt "${MAX_ALERTS}" ]; do
        local per_page=$((MAX_ALERTS - fetched_count))
        [ ${per_page} -gt 100 ] && per_page=100
        
        local url="https://api.github.com/repos/${OWNER}/${REPO}/code-scanning/alerts"
        local response
        local http_code
        
        response=$(curl -s -w "\n%{http_code}" \
            -H "Authorization: Bearer ${GH_TOKEN}" \
            -H "Accept: application/vnd.github+json" \
            "${url}?state=${ALERT_STATE}&page=${page}&per_page=${per_page}&sort=created&direction=desc")
        
        http_code=$(echo "${response}" | tail -n1)
        local body=$(echo "${response}" | head -n-1)
        
        case "${http_code}" in
            200)
                # Filter alerts from security scanners
                local scanner_alerts=$(echo "${body}" | jq '[.[] | select(
                    (.tool.name // "" | ascii_downcase) as $tool |
                    $tool == "codeql" or 
                    $tool == "shellcheck" or 
                    $tool == "codenarc" or 
                    $tool == "template-security" or 
                    $tool == "makefile-security"
                )]')
                
                local count=$(echo "${scanner_alerts}" | jq 'length')
                
                if [ "${count}" -eq 0 ]; then
                    break
                fi
                
                log_info "Page ${page}: ${count} security alerts from various scanners"
                
                # Merge with existing alerts
                all_alerts=$(echo "${all_alerts}" | jq --argjson new "${scanner_alerts}" '. + $new')
                fetched_count=$(echo "${all_alerts}" | jq 'length')
                
                page=$((page + 1))
                ;;
            403)
                log_error "Access denied to code scanning alerts"
                log_info "Token may lack 'security-events:read' permission for private repo"
                break
                ;;
            *)
                log_error "API error ${http_code}"
                break
                ;;
        esac
    done
    
    echo "${all_alerts}" > "${ALERTS_FILE}"
    local total=$(echo "${all_alerts}" | jq 'length')
    log_success "Total alerts fetched: ${total}"
    
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
    local parsed_file="${TEMP_DIR}/parsed_json_${RANDOM}.json"
    
    # Try to extract JSON from response (find first complete JSON object)
    echo "${response}" | grep -oP '\{(?:[^{}]|(?:\{[^{}]*\}))*\}' | head -n1 > "${parsed_file}" 2>/dev/null || true
    
    if [ -s "${parsed_file}" ] && jq empty "${parsed_file}" 2>/dev/null; then
        cat "${parsed_file}"
        rm -f "${parsed_file}"
        return 0
    else
        rm -f "${parsed_file}"
        return 1
    fi
}

analyze_single_alert() {
    local alert_json="$1"
    local security_profile="$2"
    local alert_index="$3"
    local total_alerts="$4"
    
    echo ""
    echo "--- Alert ${alert_index}/${total_alerts} ---"
    
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
    
    echo "📍 ${path}:${start_line} - ${rule_id}"
    
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
    
    # Parse response
    local parsed
    if parsed=$(parse_json_response "${ai_response}"); then
        local classification=$(echo "${parsed}" | jq -r '.classification // "UNCERTAIN"')
        local certainty=$(echo "${parsed}" | jq -r '.certainty // 30')
        local rationale=$(echo "${parsed}" | jq -r '.rationale // "Could not parse AI response"' | head -c 1500)
        local context_factors=$(echo "${parsed}" | jq -c '.repository_context_factors // []')
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
    
    echo "🎯 Result: ${ai_label} (confidence: ${confidence}, certainty: ${certainty}%)"
    
    # Build result JSON
    local dismissed=false
    
    # Auto-dismiss if configured
    if [ "${AUTO_DISMISS}" = "true" ] && [ "${ai_label}" = "likely_false_positive" ]; then
        if [ "${confidence}" = "high" ] || [ "${confidence}" = "medium" ]; then
            if [ "${certainty}" -ge 70 ]; then
                log_info "Attempting auto-dismiss..."
                
                local dismiss_url="https://api.github.com/repos/${OWNER}/${REPO}/code-scanning/alerts/${alert_number}"
                local dismiss_response
                local dismiss_code
                
                dismiss_response=$(curl -s -w "\n%{http_code}" -X PATCH \
                    -H "Authorization: Bearer ${GH_TOKEN}" \
                    -H "Accept: application/vnd.github+json" \
                    "${dismiss_url}" \
                    -d '{"state":"dismissed","dismissed_reason":"false positive","dismissed_comment":"Context-aware AI analysis"}')
                
                dismiss_code=$(echo "${dismiss_response}" | tail -n1)
                
                if [ "${dismiss_code}" = "200" ] || [ "${dismiss_code}" = "201" ]; then
                    dismissed=true
                    log_success "Auto-dismissed: true"
                else
                    log_warning "Dismiss failed: HTTP ${dismiss_code}"
                fi
            fi
        fi
    fi
    
    # Output result as JSON
    jq -n \
        --arg alert_number "${alert_number}" \
        --arg rule_id "${rule_id}" \
        --arg severity "${severity}" \
        --arg path "${path}" \
        --arg ai_label "${ai_label}" \
        --arg confidence "${confidence}" \
        --argjson certainty_score "${certainty}" \
        --arg reason "${rationale}" \
        --argjson context_factors "${context_factors}" \
        --arg exploitability "${exploitability}" \
        --arg suggestions "${fix_suggestion}" \
        --argjson dismissed "${dismissed}" \
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
        }'
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
        if result=$(analyze_single_alert "${alert}" "${security_profile}" "${index}" "${alerts_count}"); then
            triaged_alerts=$(echo "${triaged_alerts}" | jq --argjson new "${result}" '. + [$new]')
        fi
        
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
            echo "# 🤖 Context-Aware AI Security Triage Results"
            echo ""
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
        log_info "No CodeQL alerts found"
        exit 0
    fi
    
    # Phase 2: Analyze alerts with full context
    phase2_analyze_alerts "${security_profile}"
    
    # Generate summary
    local results
    results=$(cat "${RESULTS_FILE}")
    generate_summary "${results}"
    
    log_success "Context-aware triage complete!"
}

# Execute main function
main "$@"

