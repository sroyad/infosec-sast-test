# Security Alert Triage Rules

## Classification Guidelines

### TRUE POSITIVE (TP) - Real Security Issue
**Criteria:** User-controlled input reaches a dangerous operation without proper sanitization.

**Common TP Patterns:**
- **SQL Injection**: User input directly concatenated into SQL queries
- **Command Injection**: User input passed to system commands (`os.system`, `exec`, `eval`)
- **Path Traversal**: User-controlled file paths without validation (`../../../etc/passwd`)
- **XSS**: User input displayed in HTML without encoding
- **Deserialization**: Untrusted data passed to `pickle.loads()`, `unserialize()`, etc.
- **SSRF**: User-controlled URLs in HTTP requests

**Examples:**
```python
# TP: SQL Injection
query = f"SELECT * FROM users WHERE id = {user_id}"  # user_id from request

# TP: Command Injection  
os.system(f"ping {host}")  # host from user input

# TP: Path Traversal
open(f"/uploads/{filename}")  # filename from user input
```

### FALSE POSITIVE (FP) - Not a Real Issue
**Criteria:** No actual security risk due to proper controls or non-exploitable context.

**Common FP Patterns:**
- **Test Files**: Code in test directories (`test/`, `spec/`, `__tests__/`)
- **Static/Hardcoded Values**: No user input involved
- **Proper Sanitization**: Input validation/sanitization present
- **Dead Code**: Unused functions or unreachable code
- **Configuration Files**: Build scripts, configs, non-production code
- **Mock/Example Code**: Demonstration or template code

**Examples:**
```python
# FP: Hardcoded value
query = "SELECT * FROM users WHERE id = 123"

# FP: Test file
# File: test_auth.py
def test_sql_injection():
    malicious_input = "1' OR 1=1--"  # This is just a test

# FP: Proper sanitization
safe_id = int(user_id)  # Validates input
query = f"SELECT * FROM users WHERE id = {safe_id}"
```

### UNCERTAIN - Needs Manual Review
**Use when:**
- Complex data flow requires deeper analysis
- Missing context about sanitization functions
- Unclear if code path is reachable
- Novel vulnerability pattern

## Analysis Framework

### 1. Trace Data Flow
- **Source**: Where does the data originate? (user input, database, file, etc.)
- **Sink**: Where does the data end up? (SQL query, file system, command execution)
- **Sanitization**: Any validation/encoding between source and sink?

### 2. Context Evaluation
- **File Location**: Is this production code or test/build/config?
- **Function Usage**: Is the vulnerable function actually called?
- **Input Validation**: Are there guards, type checks, or sanitization?

### 3. Exploitability Assessment
- **Direct Exploitation**: Can an attacker directly control the input?
- **Attack Surface**: Is the vulnerable code accessible via web endpoints, APIs?
- **Impact**: What's the potential damage if exploited?

## Special Cases

### Test Files - Usually FP
```
Paths containing: test/, __tests__/, spec/, e2e/, cypress/, jest/
Exception: Integration tests that could indicate real vulnerabilities
```

### Configuration/Build Files - Usually FP
```
Files: package.json, webpack.config.js, gulpfile.js, Dockerfile
Exception: Secrets in config files may be TP
```

### Third-Party Code - Usually FP
```
Paths: node_modules/, vendor/, bower_components/, dist/, build/
Exception: Known vulnerable dependencies
```

### Example Code/Demos - Usually FP
```
Files: example.*, demo.*, sample.*, tutorial.*
Exception: Examples that ship with production code
```

## Response Format Requirements

**CRITICAL**: Always respond with valid JSON only:

```json
{
  "classification": "TP|FP|UNCERTAIN",
  "certainty": 85,
  "rationale": "User input flows directly to SQL query without sanitization",
  "evidence": [
    {"path": "api/users.py", "lines": "45-47", "reason": "SQL concatenation with user input"}
  ],
  "reproduce_steps": "Send POST to /api/users with malicious SQL in 'id' parameter",
  "fix_suggestion": "Use parameterized queries or ORM methods"
}
```

## Certainty Scoring

- **90-100%**: Obvious case with clear evidence
- **70-89%**: Strong evidence, minor uncertainty
- **50-69%**: Reasonable confidence, some ambiguity  
- **30-49%**: Limited evidence, significant uncertainty
- **0-29%**: Very unclear, insufficient information

## Common Mistakes to Avoid

1. **Don't classify based on file extension alone** - Analyze the actual code
2. **Don't ignore context** - Test files with real vulnerabilities are still FP
3. **Don't assume sanitization exists** - Look for actual validation code
4. **Don't over-classify as TP** - Require clear evidence of exploitable path
5. **Don't under-classify obvious issues** - Clear SQL injection is TP regardless of complexity
