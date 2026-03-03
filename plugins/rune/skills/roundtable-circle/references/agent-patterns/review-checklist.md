# Shared Review Checklist

Standard Self-Review and Pre-Flight checklist for all review agents. Each agent specifies its own finding prefix.

### Pre-Analysis (before scanning files)

- [ ] Read [enforcement-asymmetry.md](enforcement-asymmetry.md) if not already loaded
- [ ] For each file in scope, classify Change Type (git status) and Scope Risk
- [ ] Record strictness level per file in analysis notes
- [ ] Apply strictness matrix when assigning finding severity

### Self-Review
After completing analysis, verify:
- [ ] Every finding references a **specific file:line** with evidence
- [ ] **False positives considered** — checked context before flagging
- [ ] **Confidence level** is appropriate (don't flag uncertain items as P1)
- [ ] All files in scope were **actually read**, not just assumed
- [ ] Findings are **actionable** — each has a concrete fix suggestion
- [ ] **Confidence score** assigned (0-100) with 1-sentence justification — reflects evidence strength, not finding severity
- [ ] **Cross-check**: confidence >= 80 requires evidence-verified ratio >= 50%. If not, recalibrate.

### Pre-Flight
Before writing output file, confirm:
- [ ] Output follows the **prescribed Output Format** below
- [ ] Finding prefixes match role (**{PREFIX}-NNN** standalone or **{ASH_PREFIX}-NNN** when embedded)
- [ ] Priority levels (**P1/P2/P3**) assigned to every finding
- [ ] **Evidence** section included for each finding
- [ ] **Fix** suggestion included for each finding

### Inner Flame (Supplementary)
After completing the standard Self-Review and Pre-Flight above, also verify:
- [ ] **Grounding**: Every file:line I cited — I actually Read() that file in this session
- [ ] **No phantom findings**: I'm not flagging issues in code I inferred rather than saw
- [ ] **Adversarial**: What's my weakest finding? Should I remove it or strengthen it?
- [ ] **Value**: Would a developer change their code based on each finding?

Append these results to the existing Self-Review Log section.
Include in Seal: `Inner-flame: {pass|fail|partial}. Revised: {count}.`
