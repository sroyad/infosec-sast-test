# Cursor Rule: CodeQL triage policy

- Always reason with attached files first; never guess.
- Prefer "UNCERTAIN" when proof is insufficient.
- Return EXACTLY one JSON object with:
  classification: "TP" | "FP" | "UNCERTAIN"
  certainty: 0–100
  rationale: <= 800 chars, reference exact lines/file names
  evidence: [{path, lines?, reason}]
  reproduce_steps: steps or null
  fix_suggestion: concise fix
- Treat sanitizer patterns (e.g., validation, encoding, parameterized queries) as FP if they fully cover dataflow.
- Cite code by file and line range; no generalities.
