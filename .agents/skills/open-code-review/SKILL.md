---
name: open-code-review
description: >
  Performs AI-powered deep code review on Git changes or target codebases based on
  Alibaba Cloud's open-code-review standard. Inspects for bugs, NPEs, race conditions,
  security vulnerabilities, performance, and maintainability. Generates structured line-level
  feedback and an actionable remediation plan.
license: Apache-2.0
compatibility: >
  Works directly with git diff and file reading tools, or with the `ocr` CLI if installed.
metadata:
  author: alibaba
  homepage: https://github.com/alibaba/open-code-review
  version: "1.0.0"
---

# Alibaba Cloud Open Code Review

Deep AI code review system adhering to [alibaba/open-code-review](https://github.com/alibaba/open-code-review) standards.

## Core Philosophy
1. **Zero Unintended Side Effects**: High signal-to-noise ratio. Prioritize real bugs, logic errors, NPE/nil hazards, concurrency hazards, and security flaws over cosmetic styling nits.
2. **Read-Only Inspection**: In Review mode, NEVER modify source files directly.
3. **Structured Severity & Categorization**:
   - `Critical`: Crashes, data loss, severe security exploits, active data corruption.
   - `High`: Logic bugs, null pointer exceptions, unhandled error flows, resource leaks, broken API contracts.
   - `Medium`: Performance bottlenecks, concurrency race potentials, missing validation, maintenance blockers.
   - `Low`: Readability, stylistic inconsistency, minor documentation gaps.
4. **Actionable Remediation Plan**: Conclude every review session with a concrete step-by-step remediation plan enclosed in a ````plan ```` block, so the user can review and approve it with one click.

---

## Review Workflow

### Step 1: Target Scope Identification
Determine the scope to review:
- **Workspace Changes** (default): Uncommitted staged, unstaged, and untracked changes (`git status`, `git diff HEAD`).
- **Target Branch / PR**: Compare against base (`git diff origin/main...HEAD`).
- **Target Commit**: Inspect a specific revision (`git show <hash>`).
- **Target Directory / Project**: If the user specified a specific folder, inspect all source files within that directory.

### Step 2: Inspection Criteria (Alibaba OCR Standards)
For every modified or selected file:
1. **Defect & Logic Check**:
   - Boundary conditions (empty collections, zero-division, off-by-one).
   - Optional / nil / null unwrapping without safe guards.
   - Resource leaks (unclosed streams, file handles, unmanaged subscriptions).
2. **Concurrency & Thread Safety**:
   - Shared mutable state accessed without synchronization or actors.
   - Blocking calls inside async contexts or on the main thread.
   - Race conditions in state transitions.
3. **Security & Validation**:
   - Injection vulnerabilities, unescaped queries, unsanitized user inputs.
   - Insecure credential or secret storage.
4. **Architectural & Type Consistency**:
   - Adherence to project architecture (e.g., pure functions, strict typing, DRY/KISS/YAGNI).
   - Error handling: ensure specific, actionable errors instead of generic fallbacks.

### Step 3: Structured Findings Output
Group findings by severity:

```markdown
### 🚨 Critical Severity
- **[file:line]** Description of critical flaw, potential crash/exploit, and recommended fix.

### ⚠️ High Severity
- **[file:line]** Description of bug, nil dereference, or broken contract.

### 💡 Medium Severity
- **[file:line]** Performance optimization or error-handling improvement.
```

### Step 4: Actionable Plan Generation
Always generate an actionable remediation plan at the end of the review wrapped in:
````markdown
```plan
## Remediation Plan: [Summary]

1. Fix Critical & High severity items:
   - [ ] Path/File: Action description
2. Address Medium severity improvements:
   - [ ] Path/File: Action description
3. Verification:
   - [ ] Commands/Tests to validate fixes
```
````
This allows the user to click **Approve Plan** in AgenticSidebar to immediately switch to Build mode and apply the fixes.
