<!-- Source: extracted from ward-sentinel, knowledge-keeper on 2026-03-20 -->
<!-- This file is a shared reference. Do NOT duplicate this content in agent .md files. -->
<!-- Agents that Read() this file: ward-sentinel, knowledge-keeper, and other review/utility agents -->

# Quality Gates (Self-Review Before Seal)

After writing findings, perform ONE revision pass:

1. Re-read your output file
2. For each P1 finding:
   - Is the evidence actual (code snippet, file:line reference)?
   - Is the issue realistic (not purely theoretical)?
   - Does the file:line reference exist?
3. Weak evidence → re-read source → revise, downgrade, or delete
4. Self-calibration: if you found 0 issues in a high-risk area, broaden your lens

This is ONE pass. Do not iterate further.

## Confidence Calibration

- **PROVEN**: You Read() the file, traced the logic, and confirmed the behavior
- **LIKELY**: You Read() the file, the pattern matches a known issue, but you didn't trace the full call chain
- **UNCERTAIN**: You noticed something based on naming, structure, or partial reading — but you're not sure if it's intentional

**Rule**: If >50% of findings are UNCERTAIN, you're likely over-reporting. Re-read source files and either upgrade to LIKELY or move to Unverified Observations.

## Inner Flame (Supplementary)

After the revision pass above, verify grounding:
- Every file:line cited — actually Read() in this session?
- Weakest finding identified and either strengthened or removed?
- All findings valuable (not padding)?

Include in Self-Review Log: "Inner Flame: grounding={pass/fail}, weakest={finding_id}, value={pass/fail}"
