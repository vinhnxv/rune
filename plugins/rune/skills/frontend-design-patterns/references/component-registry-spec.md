# Component Registry Specification — Machine-Readable Component Catalog

A machine-readable JSON schema that maps every available component in a project with its variants, props, tokens, accessibility primitives, composition rules, and Figma mappings. Inspired by A2UI's Catalog pattern. Agents are CONSTRAINED to this registry during implementation — they may not create components or use tokens outside the catalog without explicit justification.

## JSON Schema

```json
{
  "$schema": "rune-component-registry/v1",
  "library": "shadcn | untitled-ui | custom",
  "generated_at": "ISO-8601 timestamp",
  "components": {
    "<ComponentName>": {
      "path": "src/components/ui/<file>.tsx",
      "variants": {
        "<variantAxis>": ["value1", "value2"]
      },
      "props": {
        "<propName>": {
          "type": "string | boolean | number | ReactNode | enum",
          "default": "<defaultValue>",
          "required": false
        }
      },
      "tokens": {
        "bg": ["bg-primary", "bg-destructive"],
        "text": ["text-primary-foreground"],
        "border": ["border-input"],
        "ring": ["ring-ring"],
        "shadow": [],
        "custom": []
      },
      "accessibility": {
        "primitive": "radix:<Component> | react-aria:<Hook> | native",
        "keyboard": ["Enter", "Space", "Escape"],
        "aria": ["aria-disabled", "aria-pressed", "aria-expanded"]
      },
      "composition": {
        "accepts_children": true,
        "icon_slots": ["iconLeading", "iconTrailing"],
        "compound_parts": ["DialogTrigger", "DialogContent", "DialogTitle"]
      },
      "figma_mapping": {
        "component_name": "Figma component name",
        "variant_map": {
          "FigmaProperty=FigmaValue": "codeVariant=codeValue"
        }
      }
    }
  },
  "tokens": {
    "colors": {
      "semantic": ["primary", "secondary", "destructive", "muted", "accent"],
      "format": "oklch | hsl | hex",
      "source": "src/app/globals.css"
    },
    "spacing": {
      "scale": "tailwind | custom",
      "custom": []
    }
  },
  "composition_rules": {
    "class_merge": "cn() | clsx() | twMerge()",
    "variant_system": "cva() | sortCx() | manual",
    "polymorphism": "asChild + Slot | forwardRef | none",
    "data_attributes": "data-slot | data-state | none"
  }
}
```

### Schema Field Reference

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `$schema` | string | Yes | Always `"rune-component-registry/v1"` |
| `library` | string | Yes | Detected design system library |
| `generated_at` | string | Yes | ISO-8601 timestamp of generation |
| `components` | object | Yes | Map of component name to component entry |
| `tokens` | object | Yes | Project-wide token inventory |
| `composition_rules` | object | Yes | Project-wide composition patterns |

### Component Entry Fields

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `path` | string | Yes | Relative path to component source file |
| `variants` | object | Yes | Map of variant axis to allowed values (empty `{}` if none) |
| `props` | object | Yes | Map of prop name to type/default/required |
| `tokens` | object | Yes | Categorized design tokens used by this component |
| `accessibility` | object | Yes | Accessibility primitive, keyboard interactions, ARIA attrs |
| `composition` | object | Yes | Children, slots, compound parts |
| `figma_mapping` | object | No | Figma component name and variant translation (absent if no Figma data) |

## Example: shadcn Button

```json
{
  "Button": {
    "path": "src/components/ui/button.tsx",
    "variants": {
      "variant": ["default", "destructive", "outline", "secondary", "ghost", "link"],
      "size": ["default", "sm", "lg", "icon"]
    },
    "props": {
      "asChild": { "type": "boolean", "default": false, "required": false },
      "className": { "type": "string", "required": false }
    },
    "tokens": {
      "bg": ["bg-primary", "bg-destructive", "bg-secondary"],
      "text": ["text-primary-foreground", "text-destructive-foreground"],
      "border": ["border-input"],
      "ring": ["ring-ring"],
      "shadow": [],
      "custom": []
    },
    "accessibility": {
      "primitive": "radix:Slot",
      "keyboard": ["Enter", "Space"],
      "aria": ["aria-disabled", "aria-pressed"]
    },
    "composition": {
      "accepts_children": true,
      "icon_slots": ["iconLeading", "iconTrailing"],
      "compound_parts": []
    },
    "figma_mapping": {
      "component_name": "Button",
      "variant_map": {
        "Type=Primary": "variant=default",
        "Type=Destructive": "variant=destructive",
        "Size=Small": "size=sm"
      }
    }
  }
}
```

## Example: shadcn Dialog (Compound Component)

```json
{
  "Dialog": {
    "path": "src/components/ui/dialog.tsx",
    "variants": {},
    "props": {
      "open": { "type": "boolean", "required": false },
      "onOpenChange": { "type": "(open: boolean) => void", "required": false },
      "modal": { "type": "boolean", "default": true, "required": false }
    },
    "tokens": {
      "bg": ["bg-background"],
      "text": ["text-foreground", "text-muted-foreground"],
      "border": ["border"],
      "ring": [],
      "shadow": ["shadow-lg"],
      "custom": []
    },
    "accessibility": {
      "primitive": "radix:Dialog",
      "keyboard": ["Escape"],
      "aria": ["aria-labelledby", "aria-describedby", "role=dialog"]
    },
    "composition": {
      "accepts_children": true,
      "icon_slots": [],
      "compound_parts": ["DialogTrigger", "DialogContent", "DialogHeader", "DialogTitle", "DialogDescription", "DialogFooter", "DialogClose"]
    },
    "figma_mapping": {
      "component_name": "Dialog",
      "variant_map": {
        "State=Open": "open=true",
        "State=Closed": "open=false"
      }
    }
  }
}
```

## Registry Generation Algorithm

The registry is generated automatically by the design-sync agent during the extraction phase.

```
Input:  design-system-profile.yaml, project source files
Output: component-registry.json written to tmp/design-sync/{timestamp}/

Algorithm:
1. Read design-system-profile.yaml (from design system discovery)
   - Extract library type, component directory, token source file

2. Scan component directory (profile.components.path)
   - Default: src/components/ui/ for shadcn
   - Default: src/components/ for UntitledUI
   - Glob for *.tsx files, excluding index files and test files

3. For each component file:
   a. Extract component name from default/named export
   b. Parse variant definitions:
      - shadcn:     find cva() calls → extract variants object keys/values
      - UntitledUI: find sortCx() calls → extract sizes/colors objects
      - generic:    find TypeScript prop type/interface definitions → extract union types
   c. Extract design tokens from className/style strings:
      - Scan for Tailwind classes matching bg-*, text-*, border-*, ring-*, shadow-*
      - Categorize into token buckets (bg, text, border, ring, shadow, custom)
   d. Identify accessibility primitives:
      - Check imports: @radix-ui/* → radix:<Component>
      - Check imports: react-aria/* → react-aria:<Hook>
      - No primitives → "native"
      - Extract keyboard handlers (onKeyDown patterns)
      - Extract ARIA attributes from JSX
   e. Detect composition patterns:
      - children prop or {children} in JSX → accepts_children: true
      - Named icon/slot props → icon_slots
      - Multiple exported sub-components (e.g., DialogTitle) → compound_parts

4. Build Figma mapping (if design-inventory.json exists from devise Phase 0)
   - Match component names (fuzzy: PascalCase → space-separated)
   - Map Figma variant properties to code variant axes

5. Collect project-wide tokens:
   - Parse CSS custom properties from globals.css / theme file
   - Detect color format (oklch / hsl / hex)
   - Identify spacing scale (tailwind standard / custom)

6. Detect composition rules:
   - Search for cn/clsx/twMerge imports → class_merge
   - Search for cva/sortCx imports → variant_system
   - Search for Slot/asChild/forwardRef patterns → polymorphism
   - Search for data-slot/data-state usage → data_attributes

7. Write component-registry.json to tmp/design-sync/{timestamp}/
```

### Error Handling

| Failure Mode | Fallback |
|-------------|----------|
| Component file unparseable | Skip component, log warning |
| No variant system detected | Set `variants: {}`, continue |
| No accessibility primitives | Set `primitive: "native"` |
| design-inventory.json missing | Omit `figma_mapping` for all components |
| CSS/theme file missing | Set `tokens.colors.semantic: []` |
| Profile missing component path | Use heuristic scan (`src/components/`, `components/`) |

## Agent Constraint Protocol

When a worker agent receives the component registry, it MUST follow the **REUSE > INSTALL > EXTEND > CREATE** decision hierarchy. This protocol is enforced by the design-system-compliance-reviewer.

### Decision Flow

```
Need a component for the design spec?
│
├─ 1. REUSE — Component exists in registry with matching variants?
│   └─ YES → Import and use it directly. Map Figma variants via figma_mapping.
│            Do NOT create a new component or wrapper.
│
├─ 2. INSTALL — Component exists in the library but not yet installed?
│   └─ YES → Install it (e.g., npx shadcn@latest add <component>).
│            Re-run registry generation to include it.
│
├─ 3. EXTEND — Component exists but needs a new variant or prop?
│   └─ YES → Add the variant to the existing component's cva/sortCx definition.
│            Update the registry entry to include the new variant value.
│            Do NOT create a wrapper component.
│
└─ 4. CREATE — No matching component in registry or library catalog?
    └─ YES → Create a new component following project conventions.
             Register it in the component registry.
             Must use only tokens from registry.tokens.
             Must follow composition_rules patterns.
```

### Constraint Rules

1. **Registry-first**: Always check the registry BEFORE writing any component code
2. **Token boundary**: Never use design tokens not present in `registry.tokens` — request a token addition if needed
3. **Variant consistency**: New variant values must follow existing naming conventions in the registry
4. **Composition alignment**: New components must use the same `composition_rules` as the project (e.g., if the project uses `cn()` for class merging, the new component must too)
5. **Figma traceability**: Every component used in a design implementation should have a `figma_mapping` entry linking it to the Figma source
6. **Enforcement**: The `design-system-compliance-reviewer` validates all implementation PRs against the registry. Violations are flagged as blocking findings.

### Decision Justification Format

Workers must document their decision in implementation comments:

```
Registry Decision: REUSE
Component: Button (variant=destructive, size=sm)
Registry Match: components.Button — exact variant match
```

```
Registry Decision: EXTEND
Component: Badge (adding variant=warning)
Registry Match: components.Badge — exists but missing "warning" variant
Change: Added "warning" to cva variants in badge.tsx
```

```
Registry Decision: CREATE
Component: StepIndicator
Registry Match: No match found
Justification: No existing component handles step/progress indicator UI
Tokens Used: bg-primary, text-primary-foreground, bg-muted (all in registry.tokens)
```

## Registry Lifecycle

```
1. GENERATE  — design-sync agent Phase 1 (extraction) creates initial registry
2. VALIDATE  — design-system-compliance-reviewer checks registry completeness
3. CONSUME   — worker agents read registry during Phase 2 (implementation)
4. UPDATE    — workers update registry when EXTEND or CREATE decisions add components
5. VERIFY    — review phase validates all implementations against final registry state
```

## Cross-References

- [component-reuse-strategy.md](component-reuse-strategy.md) — REUSE > EXTEND > CREATE decision tree (generalized)
- [design-system-rules.md](design-system-rules.md) — Token constraints and design system enforcement
- [variant-mapping.md](variant-mapping.md) — Figma variant to code prop mapping
- [registry-integration.md](registry-integration.md) — How agents integrate with the registry at runtime
- [semantic-token-resolver.md](semantic-token-resolver.md) — Framework-specific token resolution
