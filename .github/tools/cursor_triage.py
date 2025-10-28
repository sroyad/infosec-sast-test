#!/usr/bin/env python3
"""
AI-powered security alert triage using Cursor
"""
import os, json, re, textwrap, subprocess, tempfile, pathlib, requests
import sys
from typing import Dict, List, Optional, Any

# Environment variables
OWNER = os.environ["OWNER"]
REPO = os.environ["REPO"] 
GH = os.environ["GITHUB_TOKEN"]
ALERT_STATE = os.getenv("ALERT_STATE", "open")
MAX_ALERTS = int(os.getenv("MAX_ALERTS", "300"))
AUTO_DISMISS = os.getenv("AUTO_DISMISS", "false").lower() == "true"
DISMISS_REASON = os.getenv("DISMISS_REASON", "false positive")
SAFE_HINTS = [s.strip().lower() for s in os.getenv("SAFE_PATH_HINTS", "").split(",") if s.strip()]
CURSOR_MODEL = os.getenv("CURSOR_MODEL", "auto")
CURSOR_RULES = os.getenv("CURSOR_RULES", ".github/tools/cursor-rules.md")
SUMMARY_PATH = os.environ.get("GITHUB_STEP_SUMMARY")
repo_root = pathlib.Path(".").resolve()

print(f"Starting triage with model: {CURSOR_MODEL}")
print(f"Safe path hints: {SAFE_HINTS}")

# GitHub API session
sess = requests.Session()
sess.headers.update({"Authorization": f"Bearer {GH}", "Accept": "application/vnd.github+json"})

def list_alerts(state, page, per_page):
    url = f"https://api.github.com/repos/{OWNER}/{REPO}/code-scanning/alerts"
    r = sess.get(url, params={"state": state, "page": page, "per_page": per_page, 
                             "sort": "created", "direction": "desc"}, timeout=60)
    r.raise_for_status()
    return r.json()

def read_file(path):
    p = repo_root / path
    if not p.exists(): 
        return None
    try: 
        return p.read_text(encoding="utf-8", errors="ignore")
    except Exception: 
        return None

def lines_with_numbers(s, start, end, ctx=8):
    lines = (s or "").splitlines()
    if not lines: 
        return ""
    sidx = max(1, (start or 1) - ctx)
    eidx = min(len(lines), (end or start or 1) + ctx)
    return "\n".join(f"{i+1:>5}: {lines[i]}" for i in range(sidx-1, eidx))

def run(cmd):
    return subprocess.check_output(cmd, text=True, stderr=subprocess.STDOUT)

def rg(pattern):
    try: 
        return run(["rg", "-n", "--no-messages", pattern, "."]).splitlines()
    except subprocess.CalledProcessError: 
        return []

def build_ctags():
    tags = {}
    try:
        subprocess.check_call([
            "ctags", "-R", "--fields=+n",
            "--languages=Python,TypeScript,JavaScript,Go,Java,PHP,Ruby,Swift,Scala,C,C++",
            "-f", ".tags"
        ], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        for line in pathlib.Path(".tags").read_text(errors="ignore").splitlines():
            if line.startswith("!"): 
                continue
            parts = line.split("\t")
            if len(parts) < 4: 
                continue
            sym, file = parts[0], parts[1]
            tags.setdefault(sym, set()).add(file)
    except Exception: 
        pass
    return tags

TAGS = build_ctags()

def symbol_candidates(snippet):
    out = set()
    for tok in re.findall(r"[A-Za-z_][A-Za-z0-9_]{2,}", snippet or ""):
        if tok in ("import", "from", "class", "function", "return", "const", "let", "var", 
                  "public", "private", "protected"): 
            continue
        if tok[0].isupper() or "_" in tok or len(tok) > 5: 
            out.add(tok)
    return list(out)[:30]

def gather_context(path, start, end):
    files = set([path])
    file_text = read_file(path)
    snippet = lines_with_numbers(file_text, start, end, ctx=8)

    # Import scraping
    for l in (file_text or "").splitlines():
        m = re.search(r'^\s*(?:import|from)\s+([A-Za-z0-9_./-]+)', l)
        if m:
            cand = m.group(1)
            for ext in ("", ".py", ".ts", ".tsx", ".js", ".jsx"):
                p = (repo_root / pathlib.Path(path).parent / (cand + ext)).resolve()
                if p.exists() and p.is_file():
                    files.add(str(p.relative_to(repo_root)))

    # Symbol definitions
    for sym in symbol_candidates(snippet):
        for f in TAGS.get(sym, []):
            if pathlib.Path(f).exists(): 
                files.add(f)

    # Ripgrep neighbors (reduced scope)
    for sym in symbol_candidates(snippet)[:10]:
        for line in rg(rf'\b{re.escape(sym)}\b')[:20]:
            f = line.split(":")[0]
            if f.startswith("./"): 
                f = f[2:]
            if pathlib.Path(f).is_file(): 
                files.add(f)

    # Filter noise
    noisey = ("node_modules/", "vendor/", "dist/", "build/", "coverage/", "min.js")
    files = {f for f in files if not any(n in f for n in noisey)}
    files = list(sorted(files))[:8]
    return snippet, files

def safe_path(p: str) -> bool:
    p = (p or "").lower()
    return any(h in p for h in SAFE_HINTS)

def cursor_run(prompt_text, files):
    """Run Cursor with inline context"""
    context_blobs = []
    remaining = 18000  # Conservative limit
    
    for f in files:
        if remaining <= 0: 
            break
        if os.path.exists(f):
            try:
                data = open(f, "r", encoding="utf-8").read()
                chunk = data[:min(len(data), 3000, remaining)]
                context_blobs.append(f"\n### File: {f}\n```\n{chunk}\n```\n")
                remaining -= len(chunk)
            except Exception:
                pass

    # Inline rules
    rules_content = ""
    try:
        if os.path.exists(CURSOR_RULES):
            rules_text = open(CURSOR_RULES, "r", encoding="utf-8").read()
            rules_content = f"\n\n### Security Triage Rules\n{rules_text}\n"
    except Exception:
        pass

    full_prompt = prompt_text + rules_content + "\n\n### Code Context\n" + "".join(context_blobs)

    args = [
        "cursor-agent",
        "--print", 
        "--model", CURSOR_MODEL,
        "--output-format", "text",
        full_prompt
    ]
    
    try:
        print(f"Running cursor-agent with model: {CURSOR_MODEL}")
        out = subprocess.check_output(args, text=True, stderr=subprocess.STDOUT)
        print(f"Cursor response length: {len(out)} chars")
        return out
    except subprocess.CalledProcessError as e:
        print(f"Cursor error: {e.output}")
        return e.output

def extract_json_from_response(text: str) -> Optional[Dict]:
    """Try multiple strategies to extract JSON from AI response"""
    if not text:
        return None
        
    # Strategy 1: Look for last complete JSON object
    json_patterns = [
        r'\{(?:[^{}]|{[^{}]*})*\}(?:\s*)$',  # Last JSON object at end
        r'\{(?:[^{}]|{[^{}]*})*\}',          # Any JSON object
        r'```json\s*(\{[^`]*\})\s*```',      # JSON in code blocks
        r'```\s*(\{[^`]*\})\s*```'           # JSON in any code block
    ]
    
    for pattern in json_patterns:
        matches = re.findall(pattern, text, re.DOTALL | re.MULTILINE)
        for match in reversed(matches):  # Try last match first
            try:
                parsed = json.loads(match)
                if isinstance(parsed, dict) and 'classification' in parsed:
                    return parsed
            except (json.JSONDecodeError, TypeError):
                continue
    
    # Strategy 2: Manual extraction
    classification_match = re.search(r'"?classification"?\s*:\s*"?(TP|FP|UNCERTAIN)"?', text, re.IGNORECASE)
    certainty_match = re.search(r'"?certainty"?\s*:\s*(\d+)', text)
    rationale_match = re.search(r'"?rationale"?\s*:\s*"([^"]*)"', text, re.DOTALL)
    
    if classification_match:
        return {
            "classification": classification_match.group(1).upper(),
            "certainty": int(certainty_match.group(1)) if certainty_match else 50,
            "rationale": rationale_match.group(1) if rationale_match else "Manual extraction",
            "evidence": [],
            "reproduce_steps": None,
            "fix_suggestion": ""
        }
        
    return None

def make_prompt(alert, snippet):
    """Generate the triage prompt"""
    rule = alert.get("rule", {}) or {}
    tool = (alert.get("tool") or {}).get("name", "CodeQL")
    rule_id = rule.get("id", "")
    rule_name = rule.get("name", "")
    sev = alert.get("rule_severity") or alert.get("severity") or ""
    inst = alert.get("most_recent_instance") or {}
    loc = (inst.get("location") or {})
    path = loc.get("path", "")
    start = loc.get("start_line")
    msg = inst.get("message")
    msg = (msg or {}).get("text") if isinstance(msg, dict) else (msg or "")

    return f"""You are a security expert triaging a CodeQL alert. Analyze the code and determine if this is a true positive (TP) or false positive (FP).

**Alert Details:**
- Repository: {OWNER}/{REPO}
- Tool: {tool}
- Rule: {rule_id} | {rule_name}  
- Severity: {sev}
- File: {path}:{start}
- Message: {msg}

**Code Context:**
```
{snippet}
```

**Analysis Instructions:**
1. **TRUE POSITIVE (TP)**: User input flows to dangerous sink without proper sanitization
2. **FALSE POSITIVE (FP)**: Input is sanitized, constant, or doesn't reach dangerous functionality  
3. **UNCERTAIN**: Need more context to decide

**CRITICAL: You MUST respond with ONLY a valid JSON object in this exact format:**

{{
  "classification": "TP" | "FP" | "UNCERTAIN",
  "certainty": <integer 0-100>,
  "rationale": "<brief explanation>",
  "evidence": [{{"path": "<file>", "lines": "<line numbers>", "reason": "<why relevant>"}}],
  "reproduce_steps": "<how to exploit or null>",
  "fix_suggestion": "<brief fix recommendation>"
}}

**Examples:**
- SQL injection with user input: {{"classification": "TP", "certainty": 90, "rationale": "User input directly in SQL query"}}
- Hardcoded string in query: {{"classification": "FP", "certainty": 85, "rationale": "No user input, static string"}}
- Test file vulnerability: {{"classification": "FP", "certainty": 95, "rationale": "Test code, not production"}}

Respond with ONLY the JSON object, no other text:"""

def main():
    # 1) Pull alerts
    print(f"Fetching alerts with state: {ALERT_STATE}")
    alerts = []
    page = 1
    while len(alerts) < MAX_ALERTS:
        batch = list_alerts(ALERT_STATE, page, min(100, MAX_ALERTS - len(alerts)))
        if not batch: 
            break
        codeql_alerts = [a for a in batch if (a.get("tool") or {}).get("name", "").lower() == "codeql"]
        alerts.extend(codeql_alerts)
        print(f"Page {page}: found {len(codeql_alerts)} CodeQL alerts ({len(batch)} total)")
        page += 1

    print(f"Processing {len(alerts)} CodeQL alerts")

    # 2) Process each alert
    triaged = []
    for i, a in enumerate(alerts, 1):
        print(f"\n--- Processing alert {i}/{len(alerts)}: #{a.get('number')} ---")
        
        inst = a.get("most_recent_instance") or {}
        loc = (inst.get("location") or {})
        path = loc.get("path") or ""
        start = loc.get("start_line") or 1
        end = loc.get("end_line") or start
        
        print(f"Alert: {path}:{start} - {(a.get('rule') or {}).get('id', 'unknown')}")
        
        file_text = read_file(path)
        if not file_text: 
            print(f"Skipping - file not found: {path}")
            continue
            
        snippet, ctx_files = gather_context(path, start, end)
        print(f"Context files: {ctx_files}")

        ai_response = cursor_run(make_prompt(a, snippet), ctx_files)
        
        # Enhanced parsing
        parsed = extract_json_from_response(ai_response)
        
        if not parsed:
            print(f"Failed to parse JSON from response: {ai_response[:200]}...")
            # Fallback based on content analysis
            if safe_path(path):
                parsed = {
                    "classification": "FP", 
                    "certainty": 80, 
                    "rationale": f"Test/safe path: {path}", 
                    "evidence": [], 
                    "reproduce_steps": None, 
                    "fix_suggestion": "Remove from production scan"
                }
            else:
                parsed = {
                    "classification": "UNCERTAIN", 
                    "certainty": 30, 
                    "rationale": "Could not parse AI response", 
                    "evidence": [], 
                    "reproduce_steps": None, 
                    "fix_suggestion": "Manual review required"
                }
        
        # Map classification to labels
        label_map = {"TP": "real_issue", "FP": "likely_false_positive", "UNCERTAIN": "needs_review"}
        ai_label = label_map.get(parsed.get("classification", "UNCERTAIN"), "needs_review")
        
        # Determine confidence
        certainty = parsed.get("certainty", 0)
        if certainty >= 80: 
            confidence = "high"
        elif certainty >= 50: 
            confidence = "medium"  
        else: 
            confidence = "low"

        rec = {
            "alert_number": a.get("number"),
            "rule_id": (a.get("rule") or {}).get("id"),
            "severity": a.get("rule_severity") or a.get("severity"),
            "path": path,
            "ai_label": ai_label,
            "confidence": confidence,
            "reason": parsed.get("rationale", "")[:1200],
            "suggestions": parsed.get("fix_suggestion", "")[:400],
            "dismissed": False,
            "raw_response": ai_response[:500] if ai_response else "",
            "certainty_score": certainty
        }

        print(f"Result: {ai_label} (confidence: {confidence}, certainty: {certainty}%)")

        # Auto-dismiss logic
        should_dismiss = (
            AUTO_DISMISS and 
            ai_label == "likely_false_positive" and 
            confidence in ("high", "medium") and 
            (safe_path(path) or certainty >= 70)
        )
        
        if should_dismiss:
            try:
                url = f"https://api.github.com/repos/{OWNER}/{REPO}/code-scanning/alerts/{a.get('number')}"
                r = sess.patch(url, json={"state": "dismissed", "dismissed_reason": DISMISS_REASON}, timeout=60)
                rec["dismissed"] = r.status_code in (200, 201)
                print(f"Auto-dismissed: {rec['dismissed']}")
            except Exception as e:
                print(f"Dismiss failed: {e}")

        triaged.append(rec)

    # 3) Generate summary
    tp_count = len([r for r in triaged if r["ai_label"] == "real_issue"])
    fp_count = len([r for r in triaged if r["ai_label"] == "likely_false_positive"]) 
    uncertain_count = len([r for r in triaged if r["ai_label"] == "needs_review"])
    dismissed_count = len([r for r in triaged if r["dismissed"]])

    print(f"\n=== SUMMARY ===")
    print(f"Total processed: {len(triaged)}")
    print(f"True positives: {tp_count}")
    print(f"False positives: {fp_count}")
    print(f"Needs review: {uncertain_count}")
    print(f"Auto-dismissed: {dismissed_count}")

    md = [
        f"# AI Triage Results",
        f"",
        f"**Summary:** {len(triaged)} alerts processed | TP: {tp_count} | FP: {fp_count} | Review: {uncertain_count} | Dismissed: {dismissed_count}",
        f"",
        f"**Settings:** state={ALERT_STATE} | max_alerts={MAX_ALERTS} | auto_dismiss={'✅' if AUTO_DISMISS else '❌'}",
        "",
        "| Alert # | Rule | Sev | Path | AI Classification | Confidence | Certainty | Dismissed |",
        "|---------|------|-----|------|-------------------|------------|-----------|-----------|",
    ]
    
    for r in triaged:
        status_emoji = {"real_issue": "🔴", "likely_false_positive": "🟢", "needs_review": "🟡"}.get(r['ai_label'], "⚪")
        md.append(f"| {r['alert_number']} | `{r['rule_id']}` | {r['severity'] or 'N/A'} | `{r['path']}` | {status_emoji} **{r['ai_label']}** | {r['confidence']} | {r['certainty_score']}% | {'✅' if r['dismissed'] else '❌'} |")

    if SUMMARY_PATH:
        with open(SUMMARY_PATH, "a", encoding="utf-8") as f: 
            f.write("\n".join(md) + "\n")

    # Save detailed results
    with open("cursor-ai-triage.json", "w", encoding="utf-8") as f:
        json.dump(triaged, f, indent=2)

    print("\n✅ Triage complete! Check Job Summary and cursor-ai-triage.json artifact.")

if __name__ == "__main__":
    main()
