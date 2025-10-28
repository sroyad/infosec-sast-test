#!/usr/bin/env python3
"""
Simple two-phase AI triage: 
1. Understand entire repository
2. Analyze alerts with full context
"""
import os, json, subprocess, requests, pathlib

# Environment setup
OWNER = os.environ["OWNER"]
REPO = os.environ["REPO"] 
GH = os.environ["GITHUB_TOKEN"]
CURSOR_MODEL = os.getenv("CURSOR_MODEL", "auto")
ALERT_STATE = os.getenv("ALERT_STATE", "open")
MAX_ALERTS = int(os.getenv("MAX_ALERTS", "300"))
AUTO_DISMISS = os.getenv("AUTO_DISMISS", "false").lower() == "true"
SUMMARY_PATH = os.environ.get("GITHUB_STEP_SUMMARY")

# GitHub API
sess = requests.Session()
sess.headers.update({"Authorization": f"Bearer {GH}", "Accept": "application/vnd.github+json"})

def cursor_run(prompt):
    """Simple cursor-agent runner with entire repo context"""
    args = [
        "cursor-agent",
        "--print", 
        "--model", CURSOR_MODEL,
        "--output-format", "text",
        prompt
    ]
    
    try:
        print(f"🤖 Running cursor-agent...")
        result = subprocess.check_output(args, text=True, stderr=subprocess.STDOUT, cwd=".")
        print(f"✅ Response received ({len(result)} chars)")
        return result
    except subprocess.CalledProcessError as e:
        print(f"❌ Cursor error: {e.output}")
        return e.output

def get_codeql_alerts():
    """Fetch CodeQL alerts from GitHub API"""
    alerts = []
    page = 1
    
    while len(alerts) < MAX_ALERTS:
        url = f"https://api.github.com/repos/{OWNER}/{REPO}/code-scanning/alerts"
        r = sess.get(url, params={
            "state": ALERT_STATE, 
            "page": page, 
            "per_page": min(100, MAX_ALERTS - len(alerts)),
            "sort": "created", 
            "direction": "desc"
        }, timeout=60)
        
        batch = r.json()
        if not batch: 
            break
            
        codeql_alerts = [a for a in batch if (a.get("tool") or {}).get("name", "").lower() == "codeql"]
        alerts.extend(codeql_alerts)
        print(f"📄 Page {page}: {len(codeql_alerts)} CodeQL alerts")
        page += 1
    
    return alerts

def phase1_understand_repository():
    """Phase 1: Get Cursor to understand the entire repository"""
    
    print("🔍 PHASE 1: Repository Understanding")
    
    prompt = """You are a security expert analyzing a repository for vulnerability assessment. 

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

Focus on information that would help determine if common vulnerability classes (SQL injection, XSS, CSRF, etc.) are actually exploitable in this specific application context.
"""
    
    security_profile = cursor_run(prompt)
    
    # Save the profile for reference
    with open("repository_security_profile.txt", "w") as f:
        f.write(security_profile)
    
    print("✅ Repository security profile generated")
    return security_profile

def phase2_analyze_alerts(security_profile, alerts):
    """Phase 2: Analyze each alert with full repository context"""
    
    print(f"🎯 PHASE 2: Alert Analysis with Full Context ({len(alerts)} alerts)")
    
    triaged_alerts = []
    
    for i, alert in enumerate(alerts, 1):
        print(f"\n--- Alert {i}/{len(alerts)}: #{alert.get('number')} ---")
        
        # Extract alert details
        rule = alert.get("rule", {}) or {}
        rule_id = rule.get("id", "")
        rule_name = rule.get("name", "")
        severity = alert.get("rule_severity") or alert.get("severity") or ""
        
        inst = alert.get("most_recent_instance") or {}
        loc = inst.get("location") or {}
        path = loc.get("path", "")
        start_line = loc.get("start_line")
        
        message = inst.get("message")
        if isinstance(message, dict):
            message = message.get("text", "")
        
        print(f"📍 {path}:{start_line} - {rule_id}")
        
        # Create context-aware prompt
        prompt = f"""You are a security expert with COMPLETE understanding of this repository.

**REPOSITORY SECURITY PROFILE:**
{security_profile}

**CODEQL ALERT TO ANALYZE:**
- Alert ID: {alert.get('number')}
- Rule: {rule_id} - {rule_name}
- Severity: {severity}
- Location: {path}:{start_line}
- Message: {message}

**ANALYSIS TASK:**
Given your complete understanding of this repository's architecture, security controls, and context, determine if this CodeQL alert represents a real security vulnerability.

**Consider:**
1. Does the repository's authentication model make this vulnerability class irrelevant? (e.g., CSRF in JWT-only APIs)
2. Do framework-level protections mitigate this issue? (e.g., ORM preventing SQL injection)
3. Is this code path actually reachable and exploitable given the application architecture?
4. Are there security controls in place that CodeQL might not detect?

**RESPOND WITH ONLY THIS JSON:**
{{
  "classification": "TP|FP|UNCERTAIN",
  "certainty": <0-100>,
  "rationale": "<detailed explanation considering full repository context>",
  "repository_context_factors": ["<key factors from repo analysis that influenced decision>"],
  "exploitability": "<none|low|medium|high>",
  "fix_suggestion": "<recommendation or 'not applicable'>"
}}

**Examples of context-aware reasoning:**
- "FP: CSRF alert in JWT-authenticated API - no session cookies used, CSRF not applicable"
- "FP: SQL injection in Django ORM query - parameterized queries used automatically"  
- "TP: XSS in template that bypasses framework auto-escaping using |safe filter"
- "FP: Path traversal in containerized environment with read-only filesystem"
"""
        
        # Get AI analysis
        response = cursor_run(prompt)
        
        # Parse response (simplified for now)
        parsed = parse_json_response(response)
        if not parsed:
            parsed = {
                "classification": "UNCERTAIN",
                "certainty": 30,
                "rationale": "Could not parse AI response",
                "repository_context_factors": [],
                "exploitability": "unknown",
                "fix_suggestion": "Manual review required"
            }
        
        # Convert to our format
        label_map = {"TP": "real_issue", "FP": "likely_false_positive", "UNCERTAIN": "needs_review"}
        ai_label = label_map.get(parsed.get("classification", "UNCERTAIN"), "needs_review")
        
        certainty = parsed.get("certainty", 0)
        confidence = "high" if certainty >= 80 else ("medium" if certainty >= 50 else "low")
        
        result = {
            "alert_number": alert.get("number"),
            "rule_id": rule_id,
            "severity": severity,
            "path": path,
            "ai_label": ai_label,
            "confidence": confidence,
            "certainty_score": certainty,
            "reason": parsed.get("rationale", "")[:1500],
            "context_factors": parsed.get("repository_context_factors", []),
            "exploitability": parsed.get("exploitability", "unknown"),
            "suggestions": parsed.get("fix_suggestion", "")[:500],
            "dismissed": False
        }
        
        print(f"🎯 Result: {ai_label} (confidence: {confidence}, certainty: {certainty}%)")
        
        # Auto-dismiss if configured
        if (AUTO_DISMISS and ai_label == "likely_false_positive" and 
            confidence in ("high", "medium") and certainty >= 70):
            try:
                url = f"https://api.github.com/repos/{OWNER}/{REPO}/code-scanning/alerts/{alert.get('number')}"
                r = sess.patch(url, json={
                    "state": "dismissed", 
                    "dismissed_reason": "false positive - context-aware AI analysis"
                }, timeout=60)
                result["dismissed"] = r.status_code in (200, 201)
                print(f"✅ Auto-dismissed: {result['dismissed']}")
            except Exception as e:
                print(f"❌ Dismiss failed: {e}")
        
        triaged_alerts.append(result)
    
    return triaged_alerts

def parse_json_response(response):
    """Simple JSON extraction from response"""
    import re
    
    # Try to find JSON in response
    json_match = re.search(r'\{[^{}]*(?:\{[^{}]*\}[^{}]*)*\}', response, re.DOTALL)
    if json_match:
        try:
            return json.loads(json_match.group())
        except json.JSONDecodeError:
            pass
    
    return None

def generate_summary(triaged_alerts):
    """Generate summary report"""
    tp_count = len([a for a in triaged_alerts if a["ai_label"] == "real_issue"])
    fp_count = len([a for a in triaged_alerts if a["ai_label"] == "likely_false_positive"])
    uncertain_count = len([a for a in triaged_alerts if a["ai_label"] == "needs_review"])
    dismissed_count = len([a for a in triaged_alerts if a["dismissed"]])
    
    print(f"\n🎉 TRIAGE COMPLETE!")
    print(f"📊 Total: {len(triaged_alerts)} | TP: {tp_count} | FP: {fp_count} | Review: {uncertain_count}")
    print(f"✅ Auto-dismissed: {dismissed_count}")
    
    # Generate markdown summary
    if SUMMARY_PATH:
        md = [
            "# 🤖 Context-Aware AI Security Triage Results",
            "",
            f"**Repository:** {OWNER}/{REPO}",
            f"**Analysis Approach:** Two-phase (Repository Understanding → Alert Analysis)",
            "",
            f"## 📊 Summary",
            f"- **Total Alerts Processed:** {len(triaged_alerts)}",
            f"- **True Positives:** {tp_count} (require attention)",
            f"- **False Positives:** {fp_count} (context-aware dismissal)",
            f"- **Needs Review:** {uncertain_count} (uncertain cases)",
            f"- **Auto-dismissed:** {dismissed_count}",
            "",
            "## 📋 Detailed Results",
            "",
            "| Alert # | Rule | Severity | Path | Classification | Confidence | Certainty | Context Factors | Dismissed |",
            "|---------|------|----------|------|----------------|------------|-----------|----------------|-----------|",
        ]
        
        for alert in triaged_alerts:
            emoji = {"real_issue": "🔴", "likely_false_positive": "🟢", "needs_review": "🟡"}.get(alert['ai_label'], "⚪")
            context_preview = ", ".join(alert.get('context_factors', [])[:2])
            if len(alert.get('context_factors', [])) > 2:
                context_preview += "..."
            
            md.append(f"| {alert['alert_number']} | `{alert['rule_id']}` | {alert['severity'] or 'N/A'} | `{alert['path']}` | {emoji} **{alert['ai_label']}** | {alert['confidence']} | {alert['certainty_score']}% | {context_preview} | {'✅' if alert['dismissed'] else '❌'} |")
        
        with open(SUMMARY_PATH, "a") as f:
            f.write("\n".join(md) + "\n")
    
    # Save detailed results
    with open("context-aware-triage.json", "w") as f:
        json.dump(triaged_alerts, f, indent=2)

def main():
    print(f"🚀 Starting Context-Aware AI Security Triage")
    print(f"📂 Repository: {OWNER}/{REPO}")
    print(f"🤖 Model: {CURSOR_MODEL}")
    
    # Phase 1: Understand the repository completely
    security_profile = phase1_understand_repository()
    
    # Get CodeQL alerts
    alerts = get_codeql_alerts()
    if not alerts:
        print("ℹ️  No CodeQL alerts found")
        return
    
    # Phase 2: Analyze alerts with full context
    triaged_alerts = phase2_analyze_alerts(security_profile, alerts)
    
    # Generate summary
    generate_summary(triaged_alerts)
    
    print("✅ Context-aware triage complete!")

if __name__ == "__main__":
    main()
