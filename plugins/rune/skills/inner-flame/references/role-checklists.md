# Role-Specific Self-Review Checklists

Per-role checklist extensions for the Inner Flame protocol. Use alongside the universal
3-layer protocol in SKILL.md.

## Worker Checklist (rune-smith, trial-forger)

In addition to the universal 3-layer protocol:

- [ ] **Re-read every file I modified** — not from memory, actually Read() it now
- [ ] **All identifiers defined**: no references to undefined variables/functions
- [ ] **No self-referential assignments**: check for `x = x` or circular imports
- [ ] **Function signatures match call sites**: if I changed a signature, Grep for all callers
- [ ] **No dead code introduced**: if I added imports, are they all used?
- [ ] **Tests actually run**: if I claim tests pass, did I see the test output in this session?
- [ ] **Ward checks actually passed**: if I claim wards are clean, did I see the output?
- [ ] **Pattern followed**: which existing codebase pattern did I replicate? (cite specific file)
- [ ] **No new patterns introduced**: am I following existing conventions or inventing new ones?
- [ ] **Fresh evidence cited**: Ward check command + exit code + last 20 lines of output
- [ ] **Test evidence**: Test commands run + pass/fail counts (not just "tests pass")
- [ ] **Type checker evidence**: Output shown if applicable to language
- [ ] **Evidence artifact written**: tmp/work/{timestamp}/evidence/{task-id}/evidence.json exists
      (DOC-001: evidence MUST be written BEFORE TaskUpdate — verify the file was actually created)
- [ ] **Proof artifact**: criteria_met list in Seal matches criteria echoed in step 4.1

### Elegance Check (when `inner_flame.elegance_check: true` AND non-trivial change)
- [ ] Simplest solution: no unnecessary abstraction, no speculative generality
- [ ] Pattern reuse: Grep'd for existing patterns before inventing new ones
- [ ] Readability: self-explanatory code, descriptive names, minimal comments needed
- [ ] YAGNI: no features added "just in case"

## Fixer Checklist (mend-fixer)

In addition to the universal 3-layer protocol:

- [ ] **Read file back after editing** — confirm the change is what I intended
- [ ] **Fix addresses the actual finding**: re-read the TOME finding and verify alignment
- [ ] **No collateral damage**: Grep for all usages of anything I changed
- [ ] **Identifier consistency**: if I renamed something, did I update ALL references?
- [ ] **Function signature stability**: if I changed params, did I update all call sites?
- [ ] **Regex validation**: if I wrote/modified a regex, test it mentally against edge cases
- [ ] **Constants/defaults valid**: if I changed a value, is it valid in all contexts?
- [ ] **Security finding extra scrutiny**: SEC-prefix findings require EVIDENCE that the fix works
- [ ] **False positive evidence**: if flagging as false positive, is evidence concrete (not "I think")?
- [ ] **Before/after shown**: Diff or line comparison for each fix
- [ ] **Verification cited**: Command that confirms the fix works + output
- [ ] **Regression check**: Test run output proving no regression (not just "no regression")

### Elegance Check (when `inner_flame.elegance_check: true` AND non-trivial change)
- [ ] Simplest solution: no unnecessary abstraction, no speculative generality
- [ ] Pattern reuse: Grep'd for existing patterns before inventing new ones
- [ ] Readability: self-explanatory code, descriptive names, minimal comments needed
- [ ] YAGNI: no features added "just in case"

## Reviewer Checklist (all review Ashes)

NOTE: Review Ashes already have `review-checklist.md` (shared) and per-Ash QUALITY GATES.
Inner Flame SUPPLEMENTS but does NOT replace these. It adds:

- [ ] **Grounding: every file:line reference verified** — I actually Read() the file at that line
- [ ] **No phantom findings**: findings based on code I actually saw, not inferred
- [ ] **Confidence calibration**: confidence >= 80 requires evidence-verified >= 50%
- [ ] **False positive consideration**: for each finding, did I check if context makes it valid?
- [ ] **Adversarial: what's my weakest finding?** — identify and either strengthen or remove it
- [ ] **Value check: would a developer act on each finding?** — remove noise findings
- [ ] **Evidence for qualifying language**: Every "appears", "seems", "probably" backed by evidence or removed

## Researcher Checklist (repo-surveyor, echo-reader, git-miner, practice-seeker, lore-scholar)

In addition to the universal 3-layer protocol:

- [ ] **All cited files exist**: Glob/Grep to verify every file path I mentioned
- [ ] **Patterns I described are accurate**: re-read source files to confirm
- [ ] **No outdated information**: check if the code I referenced still exists on this branch
- [ ] **Completeness**: did I search broadly enough? Any directories I should have checked?
- [ ] **Relevance filter**: is everything in my output relevant to the task? Remove tangents.

## Forger Checklist (forge agents, elicitation-sage)

In addition to the universal 3-layer protocol:

- [ ] **No implementation code in output**: forge produces research/enrichment, not code
- [ ] **Claims backed by sources**: every best practice cited should have a verifiable source
- [ ] **Relevance to plan section**: does my enrichment actually help the section it's assigned to?
- [ ] **Not regurgitating obvious advice**: is my output specific and actionable, not generic?
- [ ] **Cross-check with codebase**: do my recommendations align with existing project patterns?

## Aggregator Checklist (runebinder)

In addition to the universal 3-layer protocol:

- [ ] **All input files read**: verify I read every Ash output file listed in inscription.json
- [ ] **No findings dropped**: count findings per source, verify total matches
- [ ] **Dedup is correct**: findings marked as duplicates truly ARE duplicates (same file:line)
- [ ] **Priority ordering maintained**: P1 before P2 before P3 in output
- [ ] **Gap detection**: any Ash that was expected but didn't produce output? Flag it.
- [ ] **Citation verification awareness**: I did NOT attempt to verify file:line citations myself — that is Phase 5.2's responsibility. I copied findings exactly per Rule 1.

## Design Roles

Design-specific checklists for agents involved in design prototype generation,
design fidelity iteration, and design implementation review.

### Proto-Worker Checklist (proto-worker — Design Prototype)

In addition to the universal 3-layer protocol:

- [ ] **Every prototype file has a corresponding story file**: Glob for `*.stories.tsx` matching each component
- [ ] **All variants from VSM appear in story**: not just the default variant — cross-check VSM variant map
- [ ] **Component props interface matches VSM variant map**: TypeScript interface aligns with design spec
- [ ] **No hardcoded colors/spacing**: all use design tokens or Tailwind classes (Grep for hex literals)
- [ ] **Accessibility**: semantic HTML elements, ARIA labels, keyboard handlers present
- [ ] **Mapping.json written with confidence score**: each component has a numeric confidence entry
- [ ] **LOW-confidence components flagged**: worker_advisory present in confidence report for score < 60

### Design-Iterator Checklist (design-iterator — Design Fidelity Fix)

In addition to the universal 3-layer protocol:

- [ ] **Every fix has before/after evidence**: entry includes pre-fix and post-fix state
- [ ] **DES- criteria status updated after fix**: not just score — status field reflects new state
- [ ] **No regression introduced**: check adjacent DES- criteria didn't flip to FAIL after fix
- [ ] **Fix addresses root cause, not symptom**: e.g., token variable change, not just color value swap
- [ ] **Iteration evidence JSON written**: proof_type field present per fix entry

### Design-Implementation-Reviewer Checklist (design-implementation-reviewer — Design Review)

In addition to the universal 3-layer protocol:

- [ ] **All 6 fidelity dimensions scored per component**: layout, spacing, typography, color, responsive, a11y
- [ ] **Evidence includes specific file:line references**: not just file name — actual line numbers cited
- [ ] **Penalty deductions documented with calculation**: e.g., "hardcoded #3B82F6: -5"
- [ ] **Components with <60 score have concrete fix suggestions**: actionable remediation, not generic advice
- [ ] **No generic evidence**: reject "looks good" or "matches design" — require specific observations
