# infosec-sast-test

## Vulnerable Code Samples

This repository contains intentionally vulnerable code samples across various programming languages for educational and testing purposes.

| Language | Easy Vulnerabilities | Normal Vulnerabilities | Hard Vulnerabilities |
|----------|----------------------|-------------------------|----------------------|
| Csharp | SQL Injection, Command Injection, XSS | Insecure Deserialization, Insecure Redirect, Information Disclosure | Race Condition, Improper Input Validation, Hardcoded Credentials |
| Nodejs | Command Injection, Unsafe File Write | Weak Session Management, CSRF, Open CORS | Race Condition, SSRF |
| C | - | Buffer Overflow, Format String Vulnerability | - |
| Cpp | - | - | TOCTOU |
| Bash | Command Injection | Insecure File Permissions | Race Condition |
| Perl | Command Injection | Directory Traversal | Unsafe Eval |
| Scala | SQL Injection | Command Execution | Improper Access Control |
| Typescript | XSS | Open Redirect | Insecure JWT |
| Kotlin | SQL Injection | Hardcoded Secrets | Insecure Deserialization |
| Rust | Unsafe Code Usage | Improper Error Handling | Race Condition |
| Swift | Sensitive Data Exposure | Improper Certificate Validation | Improper Authorization |
| Ruby | Command Injection | Mass Assignment | Insecure YAML Deserialization |