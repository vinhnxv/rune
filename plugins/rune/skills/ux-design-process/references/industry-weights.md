# Industry-Weighted UX Heuristic Scoring

Domain-aware weight tables for the 10 Nielsen Norman heuristic categories (H1-H10). Each domain emphasizes the heuristics most critical to its user experience patterns.

## Weight Selection Algorithm

```
function getHeuristicWeights(domain):
  // 1. Resolve domain
  if talisman.ux.industry is set:
    domain = talisman.ux.industry   // Manual override takes precedence
    if domain != inferProjectDomain().domain:
      log.warn("ux.industry override '${domain}' differs from auto-detected '${inferProjectDomain().domain}'")
  else if inferProjectDomain().confidence >= 0.70:
    domain = inferProjectDomain().domain
  else:
    domain = "general"

  // 2. Look up weights
  weights = INDUSTRY_WEIGHTS[domain] ?? INDUSTRY_WEIGHTS["general"]

  // 3. Redistribute weights for categories with 0 applicable items
  weights = redistributeWeights(weights, applicableCategories)

  return weights


function redistributeWeights(weights, applicableCategories):
  // When a heuristic category has 0 applicable checklist items,
  // redistribute its weight proportionally to remaining categories.
  //
  // Example: If H2 (5%) has 0 items and total remaining = 95%,
  //   each remaining category gains: (its_weight / 95) * 5
  //
  // This preserves relative proportions while maintaining 100% total.

  zeroCategories = [h for h in H1..H10 if applicableCategories[h] == 0]
  if zeroCategories is empty:
    return weights

  zeroWeight = sum(weights[h] for h in zeroCategories)
  activeWeight = 100 - zeroWeight

  if activeWeight == 0:
    return weights  // All categories empty — return unchanged

  redistributed = {}
  for h in H1..H10:
    if h in zeroCategories:
      redistributed[h] = 0
    else:
      redistributed[h] = weights[h] + (weights[h] / activeWeight) * zeroWeight

  // Normalize to ensure sum == 100 (floating point safety)
  total = sum(redistributed.values())
  if abs(total - 100) > 0.01:
    redistributed = {h: round(v / total * 100, 1) for h, v in redistributed}

  return redistributed
```

## Weight Tables by Domain

All tables sum to 100. The "general" domain matches the existing default weights for backward compatibility.

### general (default)

| Heuristic | Weight | Rationale |
|-----------|--------|-----------|
| H1 (Visibility) | 15% | Users abandon apps that feel unresponsive — loading/progress feedback is the #1 driver of perceived performance and trust |
| H2 (Real world) | 5% | Important for internationalized apps but rarely a blocker |
| H3 (User control) | 15% | Undo, cancel, and escape paths prevent user frustration and data loss |
| H4 (Consistency) | 10% | Inconsistency creates cognitive overhead but rarely blocks task completion |
| H5 (Error prevention) | 15% | Preventing errors is cheaper than recovering from them (NN Group research) |
| H6 (Recognition) | 10% | Visible labels and contextual help reduce learning curve |
| H7 (Flexibility) | 5% | Expert accelerators matter long-term but aren't critical for initial UX |
| H8 (Aesthetics) | 5% | Clean design supports usability but rarely determines task success |
| H9 (Error recovery) | 15% | When errors DO occur, recovery quality determines whether users leave |
| H10 (Help) | 5% | Well-designed UIs minimize help needs |

### e-commerce

| Heuristic | Weight | Rationale |
|-----------|--------|-----------|
| H1 (Visibility) | 10% | Product browsing needs progress cues but less critical than checkout safety |
| H2 (Real world) | 5% | Currency/locale important but usually handled by i18n frameworks |
| H3 (User control) | 10% | Cart editing and order modification are expected but secondary to error prevention |
| H4 (Consistency) | 15% | Baymard Institute: inconsistent product pages increase cart abandonment by 17% |
| H5 (Error prevention) | 20% | Checkout form errors are the #1 cause of cart abandonment (Baymard 2023) |
| H6 (Recognition) | 5% | Product cards are self-explanatory; recognition is less of a bottleneck |
| H7 (Flexibility) | 5% | Wish lists and saved carts help power users but aren't critical path |
| H8 (Aesthetics) | 10% | Product presentation quality directly correlates with conversion rate |
| H9 (Error recovery) | 15% | Payment failures need clear recovery paths to prevent lost sales |
| H10 (Help) | 5% | FAQ and support chat are safety nets, not primary UX drivers |

### saas

| Heuristic | Weight | Rationale |
|-----------|--------|-----------|
| H1 (Visibility) | 20% | Dashboard-heavy apps depend on real-time status, loading states, and progress indicators — users judge app quality by perceived responsiveness |
| H2 (Real world) | 5% | Domain-specific terminology matters but is usually established early |
| H3 (User control) | 10% | Undo in editors is important but SaaS typically has auto-save |
| H4 (Consistency) | 10% | Design systems in SaaS apps usually enforce this structurally |
| H5 (Error prevention) | 10% | Important for settings/config but less form-heavy than e-commerce |
| H6 (Recognition) | 15% | Complex feature sets need visible labels and contextual help — NN Group: enterprise apps with poor recognition have 3x support tickets |
| H7 (Flexibility) | 10% | Power users drive retention in SaaS — keyboard shortcuts, bulk actions, and customization matter |
| H8 (Aesthetics) | 5% | Functional over decorative — SaaS users prioritize efficiency |
| H9 (Error recovery) | 10% | Important but SaaS apps can leverage auto-save and undo stacks |
| H10 (Help) | 5% | Onboarding tours and contextual help are handled separately |

### fintech

| Heuristic | Weight | Rationale |
|-----------|--------|-----------|
| H1 (Visibility) | 15% | Transaction status must be unambiguous — "pending" vs "completed" confusion causes support calls |
| H2 (Real world) | 5% | Financial terminology is domain-specific but standardized |
| H3 (User control) | 10% | Cancel/reverse flows are critical but constrained by business rules |
| H4 (Consistency) | 15% | Inconsistent number formats or currency displays erode trust in financial accuracy |
| H5 (Error prevention) | 15% | Wrong-amount transfers are high-cost errors — confirmation dialogs and amount validation are essential |
| H6 (Recognition) | 5% | Financial dashboards are typically well-labeled by regulation |
| H7 (Flexibility) | 5% | Security constraints limit shortcuts — not a primary concern |
| H8 (Aesthetics) | 5% | Trust comes from clarity, not decoration — financial apps should look professional, not flashy |
| H9 (Error recovery) | 20% | Failed transactions need clear recovery paths — users need to know their money is safe. NN Group: financial app users who can't recover from errors churn 4x faster |
| H10 (Help) | 5% | Regulatory disclosures are required but not a UX differentiator |

### healthcare

| Heuristic | Weight | Rationale |
|-----------|--------|-----------|
| H1 (Visibility) | 10% | Status visibility matters but is secondary to safety and consistency |
| H2 (Real world) | 5% | Medical terminology is standardized within specialties |
| H3 (User control) | 15% | Clinical workflows need escape paths — wrong-patient errors must be immediately reversible |
| H4 (Consistency) | 20% | Patient safety depends on consistent layouts — ECRI Institute: inconsistent EHR layouts contribute to 6% of medication errors |
| H5 (Error prevention) | 15% | Dose validation, allergy checks, and patient ID verification prevent harm |
| H6 (Recognition) | 5% | Clinical users are trained on their systems; recognition is less variable |
| H7 (Flexibility) | 5% | Clinical workflows are protocol-driven; flexibility can introduce errors |
| H8 (Aesthetics) | 5% | Function over form — clinical environments prioritize scan-ability |
| H9 (Error recovery) | 15% | Medication errors need clear correction paths with audit trails |
| H10 (Help) | 5% | Clinical decision support is a separate system, not inline help |

### creative

| Heuristic | Weight | Rationale |
|-----------|--------|-----------|
| H1 (Visibility) | 10% | Canvas apps need progress cues for rendering/export but less than dashboards |
| H2 (Real world) | 5% | Creative tools use universal visual metaphors (layers, brushes) |
| H3 (User control) | 10% | Undo/redo is table stakes in creative tools — usually well-implemented |
| H4 (Consistency) | 5% | Creative tools can break conventions intentionally for expression |
| H5 (Error prevention) | 10% | Auto-save and version history reduce error impact |
| H6 (Recognition) | 15% | Tool palettes with icons need clear labels — NN Group: icon-only toolbars have 2x longer task completion times |
| H7 (Flexibility) | 15% | Power users demand customizable workspaces, shortcuts, and macros — expert efficiency is the differentiator |
| H8 (Aesthetics) | 20% | Creative tools are judged by their own design quality — users expect visual excellence as proof of capability |
| H9 (Error recovery) | 5% | Version history and undo stacks handle most recovery needs |
| H10 (Help) | 5% | Tutorial content is consumed separately from the main workflow |

### education

| Heuristic | Weight | Rationale |
|-----------|--------|-----------|
| H1 (Visibility) | 15% | Progress tracking is core to learning — learners need to see completion status and next steps |
| H2 (Real world) | 10% | Age-appropriate language and cultural sensitivity matter more than in other domains |
| H3 (User control) | 15% | Learners need to navigate freely, revisit content, and self-pace — forced linear progression causes dropout |
| H4 (Consistency) | 10% | Consistent navigation reduces cognitive load so learners can focus on content |
| H5 (Error prevention) | 20% | Quiz/assessment errors should be learning opportunities, not frustrations — prevent accidental submissions and provide clear confirmation |
| H6 (Recognition) | 5% | Educational content is typically well-labeled by instructional designers |
| H7 (Flexibility) | 5% | Accessibility is more important than power-user features in education |
| H8 (Aesthetics) | 5% | Engagement matters but content quality outweighs visual flair |
| H9 (Error recovery) | 10% | Wrong answers should guide learning, not punish — error recovery IS the learning experience |
| H10 (Help) | 5% | Help is embedded in the learning content itself |

### content

| Heuristic | Weight | Rationale |
|-----------|--------|-----------|
| H1 (Visibility) | 10% | Content loading states and pagination indicators needed but not primary |
| H2 (Real world) | 5% | Content platforms serve diverse audiences; language adapts to content |
| H3 (User control) | 10% | Bookmark, save-for-later, and reading position memory are expected |
| H4 (Consistency) | 10% | Consistent article/content layouts reduce reading friction |
| H5 (Error prevention) | 10% | Comment/post submission errors should be preventable (draft auto-save) |
| H6 (Recognition) | 10% | Content categories and navigation need clear labels for browsing |
| H7 (Flexibility) | 5% | Reading preferences (font size, theme) help but aren't critical |
| H8 (Aesthetics) | 25% | Typography, whitespace, and visual rhythm ARE the product — content platforms live or die by reading experience (Medium case study: typography improvements increased read time by 14%) |
| H9 (Error recovery) | 10% | Lost comments or unsaved edits frustrate contributors |
| H10 (Help) | 5% | Content is self-explanatory; help is for platform mechanics |

## Integration

- **Domain detection**: Uses `inferProjectDomain()` from [domain-inference.md](../../design-system-discovery/references/domain-inference.md)
- **Confidence threshold**: Domain weights apply when confidence >= 0.70; otherwise falls back to "general"
- **Manual override**: `ux.industry` in talisman.yml takes precedence over auto-detection
- **Scope**: Industry weights affect ONLY UXH (heuristic) scoring. UXF, UXI, and UXC scoring is domain-independent
- **Backward compatibility**: The "general" domain exactly matches the pre-existing default weights
