# Library Adapters

Pluggable adapters that transform [SemanticComponent](semantic-ir.md) instances into
library-specific React code. Each adapter implements the `LibraryAdapter` interface
defined in `semantic-ir.md`.

```
SemanticComponent[] → selectAdapter(designContext) → LibraryAdapter → Final JSX + Imports
```

## Adapter Registry

| Adapter | Library | Composability | Icon Source | Status |
|---------|---------|---------------|-------------|--------|
| `UNTITLEDUI_ADAPTER` | UntitledUI | flat (props-based) | `@untitledui/icons` | §UntitledUI Adapter |
| `SHADCN_ADAPTER` | shadcn/ui | compound (subcomponents) | `lucide-react` | §shadcn/ui Adapter |
| `TAILWIND_ADAPTER` | None (fallback) | inline (className) | Inline SVG from Figma | §Tailwind Adapter |

---

## Adapter Selection (`selectAdapter`)

Uses `DesignContext` from Layers 1-3 to choose the appropriate adapter.

```
// Pseudocode — NOT implementation code
function selectAdapter(designContext):
  strategy = designContext.synthesis_strategy

  IF strategy === "library":
    lib = designContext.figma.detected

    IF lib === "untitled_ui": RETURN UNTITLEDUI_ADAPTER
    IF lib === "shadcn_ui": RETURN SHADCN_ADAPTER
    // Add new library adapters here

    // DEPTH-003 FIX: explicit fallback for unrecognized libraries
    // When strategy is "library" but no adapter exists for the detected lib,
    // fall through to Tailwind with a warning instead of returning undefined.
    log("WARNING: No adapter for library '{lib}' — falling back to Tailwind")
    RETURN TAILWIND_ADAPTER

  IF strategy === "hybrid":
    // Hybrid mode: Tailwind classes + library naming conventions for component names
    adapter = clone(TAILWIND_ADAPTER)
    adapter.hybridSource = designContext.figma.detected ?? null
    RETURN adapter

  // Default: no strategy or unknown strategy → Tailwind fallback
  RETURN TAILWIND_ADAPTER
```

**Selection priority**:
1. Exact library match → library-specific adapter
2. Library strategy with no matching adapter → Tailwind fallback + warning
3. Hybrid strategy → Tailwind adapter with library naming hints
4. Text-only strategy → null (no code generation)
5. Everything else → Tailwind fallback

---

## UntitledUI Adapter

Props-based adapter for UntitledUI components. Uses `color`/`size` props and
`@untitledui/icons` for icon imports. Flat composability — single component with props.
React Aria patterns with `Aria*` prefix.

### Metadata

```
// Pseudocode — NOT implementation code
UNTITLEDUI_ADAPTER = {
  name: "untitled_ui",
  package: "copy-paste",           // Not an npm package — copy-paste installation
  iconPackage: "@untitledui/icons",
  importStyle: "relative",         // import { Button } from "../components/Button"
  composability: "flat",           // Single component with props
}
```

### Component Type Mappings

Each mapping follows the `AdapterTypeMapping` interface from [semantic-ir.md](semantic-ir.md).
`stateProps` entries with value `null` mean the state is not natively supported — the
adapter omits the prop and emits a comment (DEPTH-006).

#### button

```
UNTITLEDUI_ADAPTER.button = {
  propName: "color",
  variants: {
    primary: "primary",
    secondary: "secondary",
    tertiary: "tertiary",
    destructive: "primary-destructive",
    link: "link-color",
    ghost: "tertiary",
    success: "primary",
    warning: "primary",
    info: "primary",
    error: "primary-destructive",
  },
  sizeProp: "size",
  sizes: { xs: "sm", sm: "sm", md: "md", lg: "lg", xl: "xl", "2xl": "2xl" },
  iconProps: { leading: "iconLeading", trailing: "iconTrailing" },
  stateProps: {
    default: null, hover: null, focused: null,
    disabled: "isDisabled", loading: "isLoading",
    active: null, selected: null, error: null, readonly: null, indeterminate: null,
  },
}
```

#### input

```
UNTITLEDUI_ADAPTER.input = {
  propName: "type",
  variants: {
    primary: "default", secondary: "default", tertiary: "default",
    destructive: "default", link: "default", ghost: "default",
    success: "default", warning: "default", info: "default", error: "default",
  },
  sizeProp: "size",
  sizes: { xs: "sm", sm: "sm", md: "md", lg: "lg", xl: "lg", "2xl": "lg" },
  iconProps: { leading: "iconLeading", trailing: "iconTrailing" },
  stateProps: {
    default: null, hover: null, focused: null,
    disabled: "isDisabled", loading: null,
    active: null, selected: null, error: "isError", readonly: "isReadOnly", indeterminate: null,
  },
}
```

#### select

```
UNTITLEDUI_ADAPTER.select = {
  propName: "variant",
  variants: {
    primary: "default", secondary: "default", tertiary: "default",
    destructive: "default", link: "default", ghost: "default",
    success: "default", warning: "default", info: "default", error: "default",
  },
  sizeProp: "size",
  sizes: { xs: "sm", sm: "sm", md: "md", lg: "lg", xl: "lg", "2xl": "lg" },
  iconProps: { leading: "iconLeading", trailing: "iconTrailing" },
  stateProps: {
    default: null, hover: null, focused: null,
    disabled: "isDisabled", loading: null,
    active: "isOpen", selected: null, error: "isError", readonly: null, indeterminate: null,
  },
}
```

#### badge

```
UNTITLEDUI_ADAPTER.badge = {
  propName: "color",
  variants: {
    primary: "brand", secondary: "gray", tertiary: "gray",
    destructive: "error", link: "brand", ghost: "gray",
    success: "success", warning: "warning", info: "blue", error: "error",
  },
  sizeProp: "size",
  sizes: { xs: "sm", sm: "sm", md: "md", lg: "lg", xl: "lg", "2xl": "lg" },
  iconProps: { leading: "iconLeading", trailing: "iconTrailing" },
  stateProps: {
    default: null, hover: null, focused: null,
    disabled: null, loading: null,
    active: null, selected: null, error: null, readonly: null, indeterminate: null,
  },
}
```

#### card

```
UNTITLEDUI_ADAPTER.card = {
  propName: "variant",
  variants: {
    primary: "default", secondary: "outlined", tertiary: "ghost",
    destructive: "default", link: "default", ghost: "ghost",
    success: "default", warning: "default", info: "default", error: "default",
  },
  sizeProp: "padding",
  sizes: { xs: "sm", sm: "sm", md: "md", lg: "lg", xl: "xl", "2xl": "xl" },
  iconProps: { leading: null, trailing: null },
  stateProps: {
    default: null, hover: null, focused: null,
    disabled: null, loading: null,
    active: null, selected: null, error: null, readonly: null, indeterminate: null,
  },
}
```

#### breadcrumb

```
UNTITLEDUI_ADAPTER.breadcrumb = {
  propName: "type",
  variants: {
    primary: "default", secondary: "default", tertiary: "default",
    destructive: "default", link: "default", ghost: "default",
    success: "default", warning: "default", info: "default", error: "default",
  },
  sizeProp: "size",
  sizes: { xs: "sm", sm: "sm", md: "md", lg: "lg", xl: "lg", "2xl": "lg" },
  iconProps: { leading: null, trailing: "separator" },
  stateProps: {
    default: null, hover: null, focused: null,
    disabled: null, loading: null,
    active: null, selected: "isCurrent", error: null, readonly: null, indeterminate: null,
  },
}
```

#### pagination

```
UNTITLEDUI_ADAPTER.pagination = {
  propName: "variant",
  variants: {
    primary: "default", secondary: "outlined", tertiary: "minimal",
    destructive: "default", link: "default", ghost: "minimal",
    success: "default", warning: "default", info: "default", error: "default",
  },
  sizeProp: "size",
  sizes: { xs: "sm", sm: "sm", md: "md", lg: "lg", xl: "lg", "2xl": "lg" },
  iconProps: { leading: "iconPrev", trailing: "iconNext" },
  stateProps: {
    default: null, hover: null, focused: null,
    disabled: "isDisabled", loading: null,
    active: null, selected: null, error: null, readonly: null, indeterminate: null,
  },
}
```

#### avatar-group

```
UNTITLEDUI_ADAPTER["avatar-group"] = {
  propName: "variant",
  variants: {
    primary: "default", secondary: "default", tertiary: "default",
    destructive: "default", link: "default", ghost: "default",
    success: "default", warning: "default", info: "default", error: "default",
  },
  sizeProp: "size",
  sizes: { xs: "xs", sm: "sm", md: "md", lg: "lg", xl: "xl", "2xl": "2xl" },
  iconProps: { leading: null, trailing: null },
  stateProps: {
    default: null, hover: null, focused: null,
    disabled: null, loading: null,
    active: null, selected: null, error: null, readonly: null, indeterminate: null,
  },
}
```

#### dialog

```
UNTITLEDUI_ADAPTER.dialog = {
  propName: "variant",
  variants: {
    primary: "default", secondary: "default", tertiary: "default",
    destructive: "destructive", link: "default", ghost: "default",
    success: "default", warning: "warning", info: "default", error: "destructive",
  },
  sizeProp: "size",
  sizes: { xs: "sm", sm: "sm", md: "md", lg: "lg", xl: "xl", "2xl": "xl" },
  iconProps: { leading: "icon", trailing: null },
  stateProps: {
    default: null, hover: null, focused: null,
    disabled: null, loading: null,
    active: "isOpen", selected: null, error: null, readonly: null, indeterminate: null,
  },
}
```

#### table

```
UNTITLEDUI_ADAPTER.table = {
  propName: "variant",
  variants: {
    primary: "default", secondary: "striped", tertiary: "minimal",
    destructive: "default", link: "default", ghost: "minimal",
    success: "default", warning: "default", info: "default", error: "default",
  },
  sizeProp: "density",
  sizes: { xs: "compact", sm: "compact", md: "default", lg: "comfortable", xl: "comfortable", "2xl": "comfortable" },
  iconProps: { leading: null, trailing: "sortIcon" },
  stateProps: {
    default: null, hover: null, focused: null,
    disabled: null, loading: "isLoading",
    active: null, selected: "isSelected", error: null, readonly: null, indeterminate: null,
  },
}
```

#### tabs

```
UNTITLEDUI_ADAPTER.tabs = {
  propName: "variant",
  variants: {
    primary: "default", secondary: "outlined", tertiary: "minimal",
    destructive: "default", link: "default", ghost: "minimal",
    success: "default", warning: "default", info: "default", error: "default",
  },
  sizeProp: "size",
  sizes: { xs: "sm", sm: "sm", md: "md", lg: "lg", xl: "lg", "2xl": "lg" },
  iconProps: { leading: "icon", trailing: null },
  stateProps: {
    default: null, hover: null, focused: null,
    disabled: "isDisabled", loading: null,
    active: "isSelected", selected: "isSelected", error: null, readonly: null, indeterminate: null,
  },
}
```

#### toast

```
UNTITLEDUI_ADAPTER.toast = {
  propName: "color",
  variants: {
    primary: "brand", secondary: "gray", tertiary: "gray",
    destructive: "error", link: "brand", ghost: "gray",
    success: "success", warning: "warning", info: "brand", error: "error",
  },
  sizeProp: "size",
  sizes: { xs: "sm", sm: "sm", md: "md", lg: "lg", xl: "lg", "2xl": "lg" },
  iconProps: { leading: "icon", trailing: "closeIcon" },
  stateProps: {
    default: null, hover: null, focused: null,
    disabled: null, loading: null,
    active: "isVisible", selected: null, error: null, readonly: null, indeterminate: null,
  },
}
```

#### checkbox

```
UNTITLEDUI_ADAPTER.checkbox = {
  propName: "variant",
  variants: {
    primary: "default", secondary: "default", tertiary: "default",
    destructive: "default", link: "default", ghost: "default",
    success: "default", warning: "default", info: "default", error: "default",
  },
  sizeProp: "size",
  sizes: { xs: "sm", sm: "sm", md: "md", lg: "lg", xl: "lg", "2xl": "lg" },
  iconProps: { leading: null, trailing: null },
  stateProps: {
    default: null, hover: null, focused: null,
    disabled: "isDisabled", loading: null,
    active: null, selected: "isChecked", error: "isError", readonly: "isReadOnly", indeterminate: "isIndeterminate",
  },
}
```

#### tooltip

```
UNTITLEDUI_ADAPTER.tooltip = {
  propName: "variant",
  variants: {
    primary: "default", secondary: "default", tertiary: "default",
    destructive: "default", link: "default", ghost: "default",
    success: "default", warning: "default", info: "default", error: "default",
  },
  sizeProp: "size",
  sizes: { xs: "sm", sm: "sm", md: "md", lg: "lg", xl: "lg", "2xl": "lg" },
  iconProps: { leading: null, trailing: null },
  stateProps: {
    default: null, hover: null, focused: null,
    disabled: null, loading: null,
    active: "isOpen", selected: null, error: null, readonly: null, indeterminate: null,
  },
}
```

#### dropdown-menu

```
UNTITLEDUI_ADAPTER["dropdown-menu"] = {
  propName: "variant",
  variants: {
    primary: "default", secondary: "default", tertiary: "default",
    destructive: "destructive", link: "default", ghost: "default",
    success: "default", warning: "default", info: "default", error: "destructive",
  },
  sizeProp: "size",
  sizes: { xs: "sm", sm: "sm", md: "md", lg: "lg", xl: "lg", "2xl": "lg" },
  iconProps: { leading: "icon", trailing: "chevronIcon" },
  stateProps: {
    default: null, hover: null, focused: null,
    disabled: "isDisabled", loading: null,
    active: "isOpen", selected: null, error: null, readonly: null, indeterminate: null,
  },
}
```

#### toggle (v2.12.0)

```
UNTITLEDUI_ADAPTER.toggle = {
  propName: "variant",
  variants: {
    primary: "default", secondary: "default", tertiary: "default",
    destructive: "default", link: "default", ghost: "default",
    success: "default", warning: "default", info: "default", error: "default",
  },
  sizeProp: "size",
  sizes: { xs: "sm", sm: "sm", md: "md", lg: "lg", xl: "lg", "2xl": "lg" },
  iconProps: { leading: null, trailing: null },
  stateProps: {
    default: null, hover: null, focused: null,
    disabled: "isDisabled", loading: null,
    active: "isChecked", selected: "isChecked", error: null, readonly: null, indeterminate: null,
  },
}
```

#### radio (v2.12.0)

```
UNTITLEDUI_ADAPTER.radio = {
  propName: "variant",
  variants: {
    primary: "default", secondary: "default", tertiary: "default",
    destructive: "default", link: "default", ghost: "default",
    success: "default", warning: "default", info: "default", error: "default",
  },
  sizeProp: "size",
  sizes: { xs: "sm", sm: "sm", md: "md", lg: "lg", xl: "lg", "2xl": "lg" },
  iconProps: { leading: null, trailing: null },
  stateProps: {
    default: null, hover: null, focused: null,
    disabled: "isDisabled", loading: null,
    active: null, selected: "isChecked", error: "isError", readonly: "isReadOnly", indeterminate: null,
  },
}
```

#### textarea (v2.12.0)

```
UNTITLEDUI_ADAPTER.textarea = {
  propName: "variant",
  variants: {
    primary: "default", secondary: "default", tertiary: "default",
    destructive: "default", link: "default", ghost: "default",
    success: "default", warning: "default", info: "default", error: "default",
  },
  sizeProp: "size",
  sizes: { xs: "sm", sm: "sm", md: "md", lg: "lg", xl: "lg", "2xl": "lg" },
  iconProps: { leading: null, trailing: null },
  stateProps: {
    default: null, hover: null, focused: null,
    disabled: "isDisabled", loading: null,
    active: null, selected: null, error: "isError", readonly: "isReadOnly", indeterminate: null,
  },
}
```

#### slider (v2.12.0)

```
UNTITLEDUI_ADAPTER.slider = {
  propName: "variant",
  variants: {
    primary: "default", secondary: "default", tertiary: "default",
    destructive: "default", link: "default", ghost: "default",
    success: "default", warning: "default", info: "default", error: "default",
  },
  sizeProp: "size",
  sizes: { xs: "sm", sm: "sm", md: "md", lg: "lg", xl: "lg", "2xl": "lg" },
  iconProps: { leading: null, trailing: null },
  stateProps: {
    default: null, hover: null, focused: null,
    disabled: "isDisabled", loading: null,
    active: null, selected: null, error: null, readonly: null, indeterminate: null,
  },
}
```

#### progress (v2.12.0)

```
UNTITLEDUI_ADAPTER.progress = {
  propName: "color",
  variants: {
    primary: "brand", secondary: "gray", tertiary: "gray",
    destructive: "error", link: "brand", ghost: "gray",
    success: "success", warning: "warning", info: "blue", error: "error",
  },
  sizeProp: "size",
  sizes: { xs: "sm", sm: "sm", md: "md", lg: "lg", xl: "lg", "2xl": "lg" },
  iconProps: { leading: null, trailing: null },
  stateProps: {
    default: null, hover: null, focused: null,
    disabled: null, loading: null,
    active: null, selected: null, error: null, readonly: null, indeterminate: "isIndeterminate",
  },
}
```

#### alert (v2.12.0)

```
UNTITLEDUI_ADAPTER.alert = {
  propName: "color",
  variants: {
    primary: "brand", secondary: "gray", tertiary: "gray",
    destructive: "error", link: "brand", ghost: "gray",
    success: "success", warning: "warning", info: "blue", error: "error",
  },
  sizeProp: "size",
  sizes: { xs: "sm", sm: "sm", md: "md", lg: "lg", xl: "lg", "2xl": "lg" },
  iconProps: { leading: "icon", trailing: "closeIcon" },
  stateProps: {
    default: null, hover: null, focused: null,
    disabled: null, loading: null,
    active: null, selected: null, error: null, readonly: null, indeterminate: null,
  },
}
```

#### sidebar (v2.12.0)

```
UNTITLEDUI_ADAPTER.sidebar = {
  propName: "variant",
  variants: {
    primary: "default", secondary: "default", tertiary: "default",
    destructive: "default", link: "default", ghost: "default",
    success: "default", warning: "default", info: "default", error: "default",
  },
  sizeProp: "width",
  sizes: { xs: "xs", sm: "sm", md: "md", lg: "lg", xl: "xl", "2xl": "2xl" },
  iconProps: { leading: null, trailing: null },
  stateProps: {
    default: null, hover: null, focused: null,
    disabled: null, loading: null,
    active: null, selected: null, error: null, readonly: null, indeterminate: null,
  },
}
```

#### file-upload (v2.12.0)

```
UNTITLEDUI_ADAPTER["file-upload"] = {
  propName: "variant",
  variants: {
    primary: "default", secondary: "default", tertiary: "default",
    destructive: "default", link: "default", ghost: "default",
    success: "default", warning: "default", info: "default", error: "default",
  },
  sizeProp: "size",
  sizes: { xs: "sm", sm: "sm", md: "md", lg: "lg", xl: "lg", "2xl": "lg" },
  iconProps: { leading: "icon", trailing: null },
  stateProps: {
    default: null, hover: null, focused: null,
    disabled: "isDisabled", loading: "isUploading",
    active: "isDragActive", selected: null, error: "isError", readonly: null, indeterminate: null,
  },
}
```

### Icon Map (Curated Fast-Path)

56-entry curated mapping of common Figma icon names to UntitledUI import names (v2.12.0).
Unmapped icons use the kebab-to-PascalCase fallback from [semantic-ir.md](semantic-ir.md) §Unmapped Icon Fallback.

```
UNTITLEDUI_ADAPTER.iconMap = {
  // Navigation (10)
  "arrow-left": "ArrowLeft",
  "arrow-right": "ArrowRight",
  "arrow-up": "ArrowUp",
  "arrow-down": "ArrowDown",
  "chevron-left": "ChevronLeft",
  "chevron-right": "ChevronRight",
  "chevron-down": "ChevronDown",
  "chevron-up": "ChevronUp",
  "home-line": "HomeLine",
  "menu-01": "Menu01",

  // Action (17)
  "plus": "Plus",
  "x": "X",
  "x-close": "XClose",
  "check": "Check",
  "check-circle": "CheckCircle",
  "search-lg": "SearchLg",
  "search-sm": "SearchSm",
  "edit-05": "Edit05",
  "pencil-line": "PencilLine",
  "trash-01": "Trash01",
  "trash-03": "Trash03",
  "copy-01": "Copy01",
  "download-01": "Download01",
  "upload-01": "Upload01",
  "log-out-04": "LogOut04",
  "log-in-04": "LogIn04",
  "refresh-cw-01": "RefreshCw01",

  // Content (15)
  "filter-lines": "FilterLines",
  "filter-funnel-01": "FilterFunnel01",
  "stars-03": "Stars03",
  "placeholder": "Placeholder",
  "eye": "Eye",
  "eye-off": "EyeOff",
  "settings-01": "Settings01",
  "settings-02": "Settings02",
  "bell-01": "Bell01",
  "calendar": "Calendar",
  "clock": "Clock",
  "mail-01": "Mail01",
  "link-01": "Link01",
  "image-01": "Image01",
  "file-06": "File06",

  // User & Social (7)
  "user-01": "User01",
  "user-circle": "UserCircle",
  "users-01": "Users01",
  "heart": "Heart",
  "star-01": "Star01",
  "share-07": "Share07",
  "message-circle-02": "MessageCircle02",

  // Status (7)
  "alert-circle": "AlertCircle",
  "alert-triangle": "AlertTriangle",
  "info-circle": "InfoCircle",
  "help-circle": "HelpCircle",
  "x-circle": "XCircle",
  "loader-01": "Loader01",
  "minus": "Minus",
}
```

**Import pattern**: `import { ArrowLeft } from "@untitledui/icons"`

**File icon import** (v2.12.0): Icons prefixed with `file-type-` use a separate package:
`import { FileTypePdf } from "@untitledui/file-icons"`

```
// File-type icon prefix mapping
// Figma name: "file-type-pdf" → import from "@untitledui/file-icons"
// Figma name: "arrow-left"    → import from "@untitledui/icons" (default)
function resolveUntitledUIImportPath(figmaName):
  IF figmaName.startsWith("file-type-"):
    RETURN "@untitledui/file-icons"
  ELSE:
    RETURN "@untitledui/icons"
```

### Code Generation Examples

UntitledUI uses flat props-based JSX. Examples of generated output:

**Primary button with icon**:
```jsx
import { Button } from "../components/Button"
import { ArrowLeft } from "@untitledui/icons"

<Button color="primary" size="md" iconLeading={<ArrowLeft />}>
  Back
</Button>
```

**Select (flat — not subcomponents)**:
```jsx
import { Select } from "../components/Select"

<Select size="md" placeholder="Choose option" />
```

**Badge with feedback intent**:
```jsx
import { Badge } from "../components/Badge"
import { CheckCircle } from "@untitledui/icons"

<Badge color="success" size="sm" iconLeading={<CheckCircle />}>
  Active
</Badge>
```

### State Prop Null Behavior (DEPTH-006)

When a `stateProps` entry maps to `null`, the code generator:

1. **Omits** the prop from generated JSX entirely
2. **Emits** a comment above the component:
   ```jsx
   {/* Note: "active" state not natively supported by untitled_ui */}
   <Button color="primary" size="md">Click</Button>
   ```
3. For states that ARE supported (e.g., `loading` → `isLoading`):
   ```jsx
   <Button color="primary" size="md" isLoading>Loading...</Button>
   ```

---

## shadcn/ui Adapter

Compound-component adapter for shadcn/ui. Uses `variant`/`size` props with
subcomponent patterns (`<Select><SelectTrigger>...</SelectTrigger></Select>`).
Icons from `lucide-react`. Import paths use `@/components/ui/{component}`.

### Metadata

```
// Pseudocode — NOT implementation code
SHADCN_ADAPTER = {
  name: "shadcn_ui",
  package: "copy-paste",
  iconPackage: "lucide-react",
  importStyle: "@/components/ui",  // import { Button } from "@/components/ui/button"
  composability: "compound",       // Multi-component composition
}
```

### Component Type Mappings

Each mapping follows the `AdapterTypeMapping` interface from [semantic-ir.md](semantic-ir.md).
Types with compound composability include a `subcomponentHierarchy` field (DEPTH-008)
that defines the nesting pattern and JSX template for `generateCompoundJSX()`.

#### button

```
SHADCN_ADAPTER.button = {
  propName: "variant",
  variants: {
    primary: "default",
    secondary: "secondary",
    tertiary: "ghost",
    destructive: "destructive",
    link: "link",
    ghost: "ghost",
    // Feedback intents — shadcn buttons use variant + className override
    success: "default",       // + className="bg-green-600 hover:bg-green-700"
    warning: "default",       // + className="bg-yellow-600 hover:bg-yellow-700"
    info: "default",          // + className="bg-blue-600 hover:bg-blue-700"
    error: "destructive",
  },
  sizeProp: "size",
  sizes: { xs: "xs", sm: "sm", md: "default", lg: "lg", xl: "lg", "2xl": "lg" },
  iconProps: { leading: "data-icon='inline-start'", trailing: "data-icon='inline-end'" },
  stateProps: {
    default: null, hover: null, focused: null,
    disabled: "disabled",
    loading: null,             // Note: no built-in loading prop
    active: "data-state='active'",
    selected: "data-state='selected'",
    error: "aria-invalid='true'",
    readonly: "aria-readonly='true'",
    indeterminate: null,
  },
  subcomponentHierarchy: null, // Button is flat (no subcomponents)
}
```

#### input

```
SHADCN_ADAPTER.input = {
  propName: "type",
  variants: {
    primary: "text", secondary: "text", tertiary: "text",
    destructive: "text", link: "text", ghost: "text",
    success: "text", warning: "text", info: "text", error: "text",
  },
  sizeProp: "className",       // shadcn Input uses className for sizing
  sizes: { xs: "h-7 text-xs", sm: "h-8 text-sm", md: "h-9 text-sm", lg: "h-10 text-base", xl: "h-11 text-base", "2xl": "h-12 text-lg" },
  iconProps: { leading: "data-icon='inline-start'", trailing: "data-icon='inline-end'" },
  stateProps: {
    default: null, hover: null, focused: null,
    disabled: "disabled",
    loading: null,
    active: null, selected: null,
    error: "aria-invalid='true'",
    readonly: "readOnly",
    indeterminate: null,
  },
  subcomponentHierarchy: null, // Input is flat
}
```

#### select

```
SHADCN_ADAPTER.select = {
  propName: "value",
  variants: {
    primary: null, secondary: null, tertiary: null, destructive: null,
    link: null, ghost: null, success: null, warning: null, info: null, error: null,
  },
  sizeProp: "className",
  sizes: { xs: "h-7 text-xs", sm: "h-8 text-sm", md: "h-9 text-sm", lg: "h-10 text-base", xl: "h-11 text-base", "2xl": "h-12 text-lg" },
  iconProps: { leading: null, trailing: null },  // Icons in SelectTrigger
  stateProps: {
    default: null, hover: null, focused: null,
    disabled: "disabled",
    loading: null,
    active: "open",
    selected: null,
    error: "aria-invalid='true'",
    readonly: "disabled",     // shadcn Select has no readonly — approximate with disabled
    indeterminate: null,
  },
  subcomponentHierarchy: {
    // DEPTH-008: Compound JSX hierarchy for Select
    wrapper: "Select",
    children: [
      { component: "SelectTrigger", children: [
        { component: "SelectValue", props: { placeholder: "{children}" } }
      ]},
      { component: "SelectContent", children: [
        { component: "SelectItem", repeat: "options", props: { value: "{option.value}" }, content: "{option.label}" }
      ]}
    ],
    template: """
      <Select {stateProps}>
        <SelectTrigger className="{sizeClass}">
          <SelectValue placeholder="{children}" />
        </SelectTrigger>
        <SelectContent>
          {options}
        </SelectContent>
      </Select>
    """,
    imports: ["Select", "SelectContent", "SelectItem", "SelectTrigger", "SelectValue"],
    importPath: "@/components/ui/select",
  },
}
```

#### badge

```
SHADCN_ADAPTER.badge = {
  propName: "variant",
  variants: {
    primary: "default",
    secondary: "secondary",
    tertiary: "outline",
    destructive: "destructive",
    link: "outline", ghost: "outline",
    success: "default",       // + className="bg-green-100 text-green-800 border-green-200"
    warning: "default",       // + className="bg-yellow-100 text-yellow-800 border-yellow-200"
    info: "default",          // + className="bg-blue-100 text-blue-800 border-blue-200"
    error: "destructive",
  },
  sizeProp: "className",
  sizes: { xs: "text-[10px] px-1.5", sm: "text-xs px-2", md: "text-xs px-2.5", lg: "text-sm px-3", xl: "text-sm px-3.5", "2xl": "text-base px-4" },
  iconProps: { leading: "inline-icon-start", trailing: "inline-icon-end" },
  stateProps: {
    default: null, hover: null, focused: null,
    disabled: "aria-disabled='true'",
    loading: null, active: null, selected: null,
    error: null, readonly: null, indeterminate: null,
  },
  subcomponentHierarchy: null, // Badge is flat
}
```

#### card

```
SHADCN_ADAPTER.card = {
  propName: "className",
  variants: {
    primary: "", secondary: "", tertiary: "",
    destructive: "border-red-200",
    link: "", ghost: "border-transparent shadow-none",
    success: "border-green-200", warning: "border-yellow-200",
    info: "border-blue-200", error: "border-red-200",
  },
  sizeProp: "className",
  sizes: { xs: "p-3", sm: "p-4", md: "p-6", lg: "p-8", xl: "p-10", "2xl": "p-12" },
  iconProps: { leading: null, trailing: null },
  stateProps: {
    default: null, hover: null, focused: null,
    disabled: "aria-disabled='true'",
    loading: null, active: null, selected: "data-state='selected'",
    error: null, readonly: null, indeterminate: null,
  },
  subcomponentHierarchy: {
    wrapper: "Card",
    children: [
      { component: "CardHeader", children: [
        { component: "CardTitle", content: "{title}" },
        { component: "CardDescription", content: "{description}" }
      ]},
      { component: "CardContent", content: "{children}" },
      { component: "CardFooter", content: "{footer}", optional: true }
    ],
    template: """
      <Card className="{variantClass} {sizeClass}">
        <CardHeader>
          <CardTitle>{title}</CardTitle>
          <CardDescription>{description}</CardDescription>
        </CardHeader>
        <CardContent>{children}</CardContent>
      </Card>
    """,
    imports: ["Card", "CardContent", "CardDescription", "CardFooter", "CardHeader", "CardTitle"],
    importPath: "@/components/ui/card",
  },
}
```

#### breadcrumb

```
SHADCN_ADAPTER.breadcrumb = {
  propName: "className",
  variants: { primary: "", secondary: "", tertiary: "", destructive: "", link: "", ghost: "", success: "", warning: "", info: "", error: "" },
  sizeProp: "className",
  sizes: { xs: "text-xs", sm: "text-sm", md: "text-sm", lg: "text-base", xl: "text-base", "2xl": "text-lg" },
  iconProps: { leading: null, trailing: "separator" },
  stateProps: {
    default: null, hover: null, focused: null,
    disabled: null, loading: null,
    active: "aria-current='page'",
    selected: null, error: null, readonly: null, indeterminate: null,
  },
  subcomponentHierarchy: {
    wrapper: "Breadcrumb",
    children: [
      { component: "BreadcrumbList", children: [
        { component: "BreadcrumbItem", repeat: "items", children: [
          { component: "BreadcrumbLink", props: { href: "{item.href}" }, content: "{item.label}" }
        ]},
        { component: "BreadcrumbSeparator", between: true }
      ]}
    ],
    imports: ["Breadcrumb", "BreadcrumbItem", "BreadcrumbLink", "BreadcrumbList", "BreadcrumbSeparator"],
    importPath: "@/components/ui/breadcrumb",
  },
}
```

#### pagination

```
SHADCN_ADAPTER.pagination = {
  propName: "className",
  variants: { primary: "", secondary: "", tertiary: "", destructive: "", link: "", ghost: "", success: "", warning: "", info: "", error: "" },
  sizeProp: "className",
  sizes: { xs: "text-xs", sm: "text-sm", md: "text-sm", lg: "text-base", xl: "text-base", "2xl": "text-lg" },
  iconProps: { leading: "ChevronLeft", trailing: "ChevronRight" },
  stateProps: {
    default: null, hover: null, focused: null,
    disabled: "aria-disabled='true'", loading: null,
    active: "aria-current='page'", selected: "aria-current='page'",
    error: null, readonly: null, indeterminate: null,
  },
  subcomponentHierarchy: {
    wrapper: "Pagination",
    children: [
      { component: "PaginationContent", children: [
        { component: "PaginationItem", children: [{ component: "PaginationPrevious" }] },
        { component: "PaginationItem", repeat: "pages", children: [
          { component: "PaginationLink", props: { isActive: "{page.active}" }, content: "{page.number}" }
        ]},
        { component: "PaginationItem", children: [{ component: "PaginationNext" }] }
      ]}
    ],
    imports: ["Pagination", "PaginationContent", "PaginationItem", "PaginationLink", "PaginationNext", "PaginationPrevious"],
    importPath: "@/components/ui/pagination",
  },
}
```

#### avatar-group

```
SHADCN_ADAPTER["avatar-group"] = {
  propName: "className",
  variants: { primary: "", secondary: "", tertiary: "", destructive: "", link: "", ghost: "", success: "", warning: "", info: "", error: "" },
  sizeProp: "className",
  sizes: { xs: "h-6 w-6", sm: "h-8 w-8", md: "h-10 w-10", lg: "h-12 w-12", xl: "h-14 w-14", "2xl": "h-16 w-16" },
  iconProps: { leading: null, trailing: null },
  stateProps: { default: null, hover: null, focused: null, disabled: null, loading: null, active: null, selected: null, error: null, readonly: null, indeterminate: null },
  subcomponentHierarchy: {
    wrapper: "div",  // shadcn has no AvatarGroup — compose from Avatar
    wrapperClassName: "flex -space-x-2",
    children: [
      { component: "Avatar", repeat: "avatars", props: { className: "{sizeClass}" }, children: [
        { component: "AvatarImage", props: { src: "{avatar.src}", alt: "{avatar.alt}" } },
        { component: "AvatarFallback", content: "{avatar.initials}" }
      ]}
    ],
    imports: ["Avatar", "AvatarFallback", "AvatarImage"],
    importPath: "@/components/ui/avatar",
  },
}
```

#### dialog

```
SHADCN_ADAPTER.dialog = {
  propName: "className",
  variants: {
    primary: "", secondary: "", tertiary: "",
    destructive: "", link: "", ghost: "",
    success: "", warning: "", info: "", error: "",
  },
  sizeProp: "className",
  sizes: { xs: "max-w-xs", sm: "max-w-sm", md: "max-w-md", lg: "max-w-lg", xl: "max-w-xl", "2xl": "max-w-2xl" },
  iconProps: { leading: null, trailing: null },
  stateProps: {
    default: null, hover: null, focused: null,
    disabled: null, loading: null, active: "open",
    selected: null, error: null, readonly: null, indeterminate: null,
  },
  subcomponentHierarchy: {
    wrapper: "Dialog",
    children: [
      { component: "DialogTrigger", props: { asChild: true }, content: "{trigger}" },
      { component: "DialogContent", props: { className: "{sizeClass}" }, children: [
        { component: "DialogHeader", children: [
          { component: "DialogTitle", content: "{title}" },
          { component: "DialogDescription", content: "{description}" }
        ]},
        { content: "{children}" },
        { component: "DialogFooter", content: "{footer}", optional: true }
      ]}
    ],
    template: """
      <Dialog>
        <DialogTrigger asChild>{trigger}</DialogTrigger>
        <DialogContent className="{sizeClass}">
          <DialogHeader>
            <DialogTitle>{title}</DialogTitle>
            <DialogDescription>{description}</DialogDescription>
          </DialogHeader>
          {children}
          <DialogFooter>{footer}</DialogFooter>
        </DialogContent>
      </Dialog>
    """,
    imports: ["Dialog", "DialogContent", "DialogDescription", "DialogFooter", "DialogHeader", "DialogTitle", "DialogTrigger"],
    importPath: "@/components/ui/dialog",
  },
}
```

#### table

```
SHADCN_ADAPTER.table = {
  propName: "className",
  variants: { primary: "", secondary: "", tertiary: "", destructive: "", link: "", ghost: "", success: "", warning: "", info: "", error: "" },
  sizeProp: "className",
  sizes: { xs: "text-xs", sm: "text-sm", md: "text-sm", lg: "text-base", xl: "text-base", "2xl": "text-lg" },
  iconProps: { leading: null, trailing: null },
  stateProps: { default: null, hover: null, focused: null, disabled: null, loading: null, active: null, selected: null, error: null, readonly: null, indeterminate: null },
  subcomponentHierarchy: {
    wrapper: "Table",
    children: [
      { component: "TableHeader", children: [
        { component: "TableRow", children: [
          { component: "TableHead", repeat: "columns", content: "{column.label}" }
        ]}
      ]},
      { component: "TableBody", children: [
        { component: "TableRow", repeat: "rows", children: [
          { component: "TableCell", repeat: "columns", content: "{cell.value}" }
        ]}
      ]}
    ],
    imports: ["Table", "TableBody", "TableCell", "TableHead", "TableHeader", "TableRow"],
    importPath: "@/components/ui/table",
  },
}
```

#### tabs

```
SHADCN_ADAPTER.tabs = {
  propName: "defaultValue",
  variants: { primary: "", secondary: "", tertiary: "", destructive: "", link: "", ghost: "", success: "", warning: "", info: "", error: "" },
  sizeProp: "className",
  sizes: { xs: "text-xs", sm: "text-sm", md: "text-sm", lg: "text-base", xl: "text-base", "2xl": "text-lg" },
  iconProps: { leading: null, trailing: null },
  stateProps: {
    default: null, hover: null, focused: null,
    disabled: "disabled", loading: null,
    active: "data-state='active'", selected: "data-state='active'",
    error: null, readonly: null, indeterminate: null,
  },
  subcomponentHierarchy: {
    wrapper: "Tabs",
    children: [
      { component: "TabsList", children: [
        { component: "TabsTrigger", repeat: "tabs", props: { value: "{tab.value}" }, content: "{tab.label}" }
      ]},
      { component: "TabsContent", repeat: "tabs", props: { value: "{tab.value}" }, content: "{tab.content}" }
    ],
    imports: ["Tabs", "TabsContent", "TabsList", "TabsTrigger"],
    importPath: "@/components/ui/tabs",
  },
}
```

#### toast

```
SHADCN_ADAPTER.toast = {
  propName: "variant",
  variants: {
    primary: "default", secondary: "default", tertiary: "default",
    destructive: "destructive", link: "default", ghost: "default",
    success: "default", warning: "default", info: "default", error: "destructive",
  },
  sizeProp: "className",
  sizes: { xs: "text-xs", sm: "text-sm", md: "text-sm", lg: "text-base", xl: "text-base", "2xl": "text-lg" },
  iconProps: { leading: "inline-icon", trailing: null },
  stateProps: { default: null, hover: null, focused: null, disabled: null, loading: null, active: null, selected: null, error: null, readonly: null, indeterminate: null },
  subcomponentHierarchy: {
    wrapper: "Toast",
    children: [
      { component: "ToastTitle", content: "{title}" },
      { component: "ToastDescription", content: "{children}" },
      { component: "ToastClose", optional: true }
    ],
    imports: ["Toast", "ToastClose", "ToastDescription", "ToastTitle"],
    importPath: "@/components/ui/toast",
  },
}
```

#### checkbox

```
SHADCN_ADAPTER.checkbox = {
  propName: "className",
  variants: { primary: "", secondary: "", tertiary: "", destructive: "", link: "", ghost: "", success: "", warning: "", info: "", error: "" },
  sizeProp: "className",
  sizes: { xs: "h-3 w-3", sm: "h-4 w-4", md: "h-4 w-4", lg: "h-5 w-5", xl: "h-6 w-6", "2xl": "h-7 w-7" },
  iconProps: { leading: null, trailing: null },
  stateProps: {
    default: null, hover: null, focused: null,
    disabled: "disabled", loading: null,
    active: "checked", selected: "checked",
    error: "aria-invalid='true'",
    readonly: "disabled",
    indeterminate: "data-state='indeterminate'",
  },
  subcomponentHierarchy: null, // Checkbox is flat
}
```

#### tooltip

```
SHADCN_ADAPTER.tooltip = {
  propName: "className",
  variants: { primary: "", secondary: "", tertiary: "", destructive: "", link: "", ghost: "", success: "", warning: "", info: "", error: "" },
  sizeProp: "className",
  sizes: { xs: "text-xs px-2 py-1", sm: "text-xs px-2.5 py-1", md: "text-sm px-3 py-1.5", lg: "text-sm px-3.5 py-2", xl: "text-base px-4 py-2", "2xl": "text-base px-5 py-2.5" },
  iconProps: { leading: null, trailing: null },
  stateProps: {
    default: null, hover: null, focused: null,
    disabled: null, loading: null, active: "open",
    selected: null, error: null, readonly: null, indeterminate: null,
  },
  subcomponentHierarchy: {
    wrapper: "TooltipProvider",
    children: [
      { component: "Tooltip", children: [
        { component: "TooltipTrigger", props: { asChild: true }, content: "{trigger}" },
        { component: "TooltipContent", content: "{children}" }
      ]}
    ],
    imports: ["Tooltip", "TooltipContent", "TooltipProvider", "TooltipTrigger"],
    importPath: "@/components/ui/tooltip",
  },
}
```

#### dropdown-menu

```
SHADCN_ADAPTER["dropdown-menu"] = {
  propName: "className",
  variants: { primary: "", secondary: "", tertiary: "", destructive: "", link: "", ghost: "", success: "", warning: "", info: "", error: "" },
  sizeProp: "className",
  sizes: { xs: "text-xs", sm: "text-sm", md: "text-sm", lg: "text-base", xl: "text-base", "2xl": "text-lg" },
  iconProps: { leading: null, trailing: null },
  stateProps: {
    default: null, hover: null, focused: null,
    disabled: "disabled", loading: null, active: "open",
    selected: null, error: null, readonly: null, indeterminate: null,
  },
  subcomponentHierarchy: {
    wrapper: "DropdownMenu",
    children: [
      { component: "DropdownMenuTrigger", props: { asChild: true }, content: "{trigger}" },
      { component: "DropdownMenuContent", children: [
        { component: "DropdownMenuLabel", content: "{label}", optional: true },
        { component: "DropdownMenuSeparator", optional: true },
        { component: "DropdownMenuItem", repeat: "items", content: "{item.label}" }
      ]}
    ],
    imports: ["DropdownMenu", "DropdownMenuContent", "DropdownMenuItem", "DropdownMenuLabel", "DropdownMenuSeparator", "DropdownMenuTrigger"],
    importPath: "@/components/ui/dropdown-menu",
  },
}
```

#### toggle (v2.12.0)

```
SHADCN_ADAPTER.toggle = {
  propName: "variant",
  variants: {
    primary: "default", secondary: "outline", tertiary: "outline",
    destructive: "default", link: "default", ghost: "outline",
    success: "default", warning: "default", info: "default", error: "default",
  },
  sizeProp: "size",
  sizes: { xs: "sm", sm: "sm", md: "default", lg: "lg", xl: "lg", "2xl": "lg" },
  iconProps: { leading: null, trailing: null },
  stateProps: {
    default: null, hover: null, focused: null,
    disabled: "disabled", loading: null,
    active: "data-state='on'", selected: "data-state='on'",
    error: null, readonly: null, indeterminate: null,
  },
  subcomponentHierarchy: null, // Toggle is flat
}
```

#### radio (v2.12.0)

```
SHADCN_ADAPTER.radio = {
  propName: "className",
  variants: { primary: "", secondary: "", tertiary: "", destructive: "", link: "", ghost: "", success: "", warning: "", info: "", error: "" },
  sizeProp: "className",
  sizes: { xs: "h-3 w-3", sm: "h-4 w-4", md: "h-4 w-4", lg: "h-5 w-5", xl: "h-6 w-6", "2xl": "h-7 w-7" },
  iconProps: { leading: null, trailing: null },
  stateProps: {
    default: null, hover: null, focused: null,
    disabled: "disabled", loading: null,
    active: "checked", selected: "checked",
    error: "aria-invalid='true'", readonly: "disabled", indeterminate: null,
  },
  subcomponentHierarchy: {
    wrapper: "RadioGroup",
    children: [
      { component: "RadioGroupItem", repeat: "options", props: { value: "{option.value}" } }
    ],
    imports: ["RadioGroup", "RadioGroupItem"],
    importPath: "@/components/ui/radio-group",
  },
}
```

#### textarea (v2.12.0)

```
SHADCN_ADAPTER.textarea = {
  propName: "className",
  variants: { primary: "", secondary: "", tertiary: "", destructive: "", link: "", ghost: "", success: "", warning: "", info: "", error: "" },
  sizeProp: "className",
  sizes: { xs: "h-16 text-xs", sm: "h-20 text-sm", md: "h-24 text-sm", lg: "h-32 text-base", xl: "h-40 text-base", "2xl": "h-48 text-lg" },
  iconProps: { leading: null, trailing: null },
  stateProps: {
    default: null, hover: null, focused: null,
    disabled: "disabled", loading: null,
    active: null, selected: null,
    error: "aria-invalid='true'", readonly: "readOnly", indeterminate: null,
  },
  subcomponentHierarchy: null, // Textarea is flat
}
```

#### slider (v2.12.0)

```
SHADCN_ADAPTER.slider = {
  propName: "className",
  variants: { primary: "", secondary: "", tertiary: "", destructive: "", link: "", ghost: "", success: "", warning: "", info: "", error: "" },
  sizeProp: "className",
  sizes: { xs: "h-1", sm: "h-1.5", md: "h-2", lg: "h-2.5", xl: "h-3", "2xl": "h-4" },
  iconProps: { leading: null, trailing: null },
  stateProps: {
    default: null, hover: null, focused: null,
    disabled: "disabled", loading: null,
    active: null, selected: null,
    error: "aria-invalid='true'", readonly: "disabled", indeterminate: null,
  },
  subcomponentHierarchy: null, // Slider is flat
}
```

#### progress (v2.12.0)

```
SHADCN_ADAPTER.progress = {
  propName: "className",
  variants: {
    primary: "", secondary: "", tertiary: "",
    destructive: "bg-red-100 [&>div]:bg-red-600",
    link: "", ghost: "",
    success: "bg-green-100 [&>div]:bg-green-600",
    warning: "bg-yellow-100 [&>div]:bg-yellow-600",
    info: "bg-blue-100 [&>div]:bg-blue-600",
    error: "bg-red-100 [&>div]:bg-red-600",
  },
  sizeProp: "className",
  sizes: { xs: "h-1", sm: "h-1.5", md: "h-2", lg: "h-3", xl: "h-4", "2xl": "h-5" },
  iconProps: { leading: null, trailing: null },
  stateProps: {
    default: null, hover: null, focused: null,
    disabled: null, loading: null,
    active: null, selected: null,
    error: null, readonly: null, indeterminate: "data-state='indeterminate'",
  },
  subcomponentHierarchy: null, // Progress is flat
}
```

#### alert (v2.12.0)

```
SHADCN_ADAPTER.alert = {
  propName: "variant",
  variants: {
    primary: "default", secondary: "default", tertiary: "default",
    destructive: "destructive", link: "default", ghost: "default",
    success: "default", warning: "default", info: "default", error: "destructive",
  },
  sizeProp: "className",
  sizes: { xs: "p-2 text-xs", sm: "p-3 text-sm", md: "p-4 text-sm", lg: "p-5 text-base", xl: "p-6 text-base", "2xl": "p-8 text-lg" },
  iconProps: { leading: "inline-icon", trailing: null },
  stateProps: { default: null, hover: null, focused: null, disabled: null, loading: null, active: null, selected: null, error: null, readonly: null, indeterminate: null },
  subcomponentHierarchy: {
    wrapper: "Alert",
    children: [
      { component: "AlertTitle", content: "{title}" },
      { component: "AlertDescription", content: "{children}" }
    ],
    imports: ["Alert", "AlertDescription", "AlertTitle"],
    importPath: "@/components/ui/alert",
  },
}
```

#### sidebar (v2.12.0)

```
SHADCN_ADAPTER.sidebar = {
  propName: "side",
  variants: { primary: "left", secondary: "left", tertiary: "left", destructive: "left", link: "left", ghost: "left", success: "left", warning: "left", info: "left", error: "left" },
  sizeProp: "className",
  sizes: { xs: "w-48", sm: "w-56", md: "w-64", lg: "w-72", xl: "w-80", "2xl": "w-96" },
  iconProps: { leading: null, trailing: null },
  stateProps: {
    default: null, hover: null, focused: null,
    disabled: null, loading: null,
    active: "data-state='open'", selected: null,
    error: null, readonly: null, indeterminate: null,
  },
  subcomponentHierarchy: {
    wrapper: "SidebarProvider",
    children: [
      { component: "Sidebar", children: [
        { component: "SidebarHeader", content: "{header}", optional: true },
        { component: "SidebarContent", content: "{children}" },
        { component: "SidebarFooter", content: "{footer}", optional: true }
      ]}
    ],
    imports: ["Sidebar", "SidebarContent", "SidebarFooter", "SidebarHeader", "SidebarProvider"],
    importPath: "@/components/ui/sidebar",
  },
}
```

#### file-upload (v2.12.0)

```
SHADCN_ADAPTER["file-upload"] = {
  propName: "className",
  variants: { primary: "", secondary: "", tertiary: "", destructive: "", link: "", ghost: "", success: "", warning: "", info: "", error: "" },
  sizeProp: "className",
  sizes: { xs: "h-24", sm: "h-32", md: "h-40", lg: "h-48", xl: "h-56", "2xl": "h-64" },
  iconProps: { leading: "inline-icon", trailing: null },
  stateProps: {
    default: null, hover: null, focused: null,
    disabled: "disabled", loading: null,
    active: "data-state='active'", selected: null,
    error: "aria-invalid='true'", readonly: "disabled", indeterminate: null,
  },
  subcomponentHierarchy: null, // File upload is flat (custom component)
}
```

### Icon Map (Curated Fast-Path)

10-entry curated mapping of common Figma icon names to Lucide React import names.
Note: Lucide uses simplified names compared to UntitledUI's descriptive naming.
Unmapped icons use the kebab-to-PascalCase fallback from [semantic-ir.md](semantic-ir.md) §Unmapped Icon Fallback.

```
SHADCN_ADAPTER.iconMap = {
  "arrow-left": "ArrowLeft",
  "arrow-right": "ArrowRight",
  "home-line": "Home",           // UntitledUI "home-line" → Lucide "Home"
  "log-out-04": "LogOut",        // UntitledUI "log-out-04" → Lucide "LogOut"
  "chevron-right": "ChevronRight",
  "chevron-down": "ChevronDown",
  "filter-lines": "Filter",     // UntitledUI "filter-lines" → Lucide "Filter"
  "stars-03": "Sparkles",       // UntitledUI "stars-03" → Lucide "Sparkles" (different icon!)
  "pencil-line": "Pencil",
  "placeholder": "Circle",
}
```

**Import pattern**: `import { ArrowLeft } from "lucide-react"`

### Code Generation Examples

shadcn/ui uses compound patterns for complex components and flat props for simple ones.

**Primary button with icon** (flat — no subcomponents):
```jsx
import { Button } from "@/components/ui/button"
import { ArrowLeft } from "lucide-react"

<Button variant="default" size="default">
  <ArrowLeft className="mr-2 h-4 w-4" />
  Back
</Button>
```

**Select (compound — subcomponent hierarchy)**:
```jsx
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select"

<Select>
  <SelectTrigger className="h-9 text-sm">
    <SelectValue placeholder="Choose option" />
  </SelectTrigger>
  <SelectContent>
    <SelectItem value="option-1">Option 1</SelectItem>
    <SelectItem value="option-2">Option 2</SelectItem>
  </SelectContent>
</Select>
```

**Dialog (compound — deeply nested)**:
```jsx
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle, DialogTrigger } from "@/components/ui/dialog"
import { Button } from "@/components/ui/button"

<Dialog>
  <DialogTrigger asChild>
    <Button variant="default">Open</Button>
  </DialogTrigger>
  <DialogContent className="max-w-md">
    <DialogHeader>
      <DialogTitle>Confirm Action</DialogTitle>
      <DialogDescription>Are you sure?</DialogDescription>
    </DialogHeader>
    {children}
    <DialogFooter>
      <Button variant="ghost">Cancel</Button>
      <Button variant="default">Confirm</Button>
    </DialogFooter>
  </DialogContent>
</Dialog>
```

**Badge with feedback intent** (flat + className override):
```jsx
import { Badge } from "@/components/ui/badge"

<Badge variant="default" className="bg-green-100 text-green-800 border-green-200">
  Active
</Badge>
```

### State Prop Null Behavior (DEPTH-006)

When a `stateProps` entry maps to `null`, the code generator:

1. **Omits** the prop from generated JSX entirely
2. **Emits** a comment above the component:
   ```jsx
   {/* Note: "loading" state not natively supported by shadcn_ui */}
   <Button variant="default" size="default">Click</Button>
   ```
3. For states that ARE supported (e.g., `disabled` → `"disabled"`):
   ```jsx
   <Button variant="default" size="default" disabled>Click</Button>
   ```

### shadcn/ui Import Resolution

shadcn/ui components are imported from `@/components/ui/{component-name}` where the
component name is the kebab-case version. Compound components import all subcomponents
from a single path.

```
// Pseudocode — NOT implementation code
function resolveShadcnImports(componentType, adapter):
  mapping = adapter[componentType]

  IF mapping.subcomponentHierarchy is not null:
    hierarchy = mapping.subcomponentHierarchy
    RETURN {
      namedImports: hierarchy.imports,
      importPath: hierarchy.importPath
    }

  // Flat components — single import
  componentName = capitalize(componentType)  // "button" → "Button"
  RETURN {
    namedImports: [componentName],
    importPath: adapter.importStyle + "/" + componentType  // "@/components/ui/button"
  }
```

### Hybrid Adapter Naming Conventions (DEPTH-007)

When `selectAdapter()` returns a hybrid adapter, the `hybridSource` field provides
library naming conventions as a structured object (not a raw string).

```
// Pseudocode — NOT implementation code
interface HybridNamingConventions {
  source: string                    // Library identifier: "untitled_ui" | "shadcn_ui" | ...
  componentNaming: "PascalCase"     // How components are named
  propNaming: "camelCase"           // How props are named
  variantPropName: string | null    // Primary variant prop name: "color" | "variant" | null
  sizePropName: string | null       // Primary size prop name: "size" | null
}

// Applied in selectAdapter() when strategy === "hybrid":
function buildHybridConventions(libraryId):
  CONVENTIONS = {
    "untitled_ui": {
      source: "untitled_ui",
      componentNaming: "PascalCase",
      propNaming: "camelCase",
      variantPropName: "color",
      sizePropName: "size",
    },
    "shadcn_ui": {
      source: "shadcn_ui",
      componentNaming: "PascalCase",
      propNaming: "camelCase",
      variantPropName: "variant",
      sizePropName: "size",
    },
  }

  RETURN CONVENTIONS[libraryId] ?? {
    source: libraryId,
    componentNaming: "PascalCase",
    propNaming: "camelCase",
    variantPropName: null,
    sizePropName: null,
  }
```

---

## Tailwind Adapter (Fallback)

Zero-dependency fallback adapter. Generates raw Tailwind CSS classes directly from
Figma-extracted styles. No external component library or icon package required.

```
// Pseudocode — NOT implementation code
TAILWIND_ADAPTER = {
  name: "tailwind",
  package: null,               // No component library
  iconPackage: null,           // Inline SVG from Figma (no icon library)
  importStyle: null,           // No component imports
  composability: "inline",    // All styling via className strings

  // Optional — set by selectAdapter() when strategy is "hybrid"
  hybridSource: null,          // Library name for naming conventions (string | null)
}
```

### Tailwind Component Generation

Unlike library adapters that map IR intents to props, the Tailwind adapter generates
components directly from Figma styles using `generateFromStyles: true` for all types.

```
// Pseudocode — NOT implementation code
function generateTailwindComponent(component, cssVersion):
  tag = TAILWIND_TAG_MAP[component.type]
  classes = []

  // Step 1: Base classes from component type
  classes.push(...TAILWIND_BASE_CLASSES[component.type])

  // Step 2: Intent → color classes
  intentColors = TAILWIND_INTENT_COLORS[component.intent]
  IF intentColors:
    classes.push(...intentColors)

  // Step 3: Size → spacing/text classes
  sizeClasses = TAILWIND_SIZE_CLASSES[component.size]
  IF sizeClasses:
    classes.push(...sizeClasses)

  // Step 4: State → modifier classes
  stateClasses = TAILWIND_STATE_CLASSES[component.state]
  IF stateClasses:
    classes.push(...stateClasses)

  // Step 5: Icon handling — inline SVG (no library import)
  leadingIcon = ""
  trailingIcon = ""
  IF component.icons.leading:
    leadingIcon = generateInlineSVG(component.icons.leading)
  IF component.icons.trailing:
    trailingIcon = generateInlineSVG(component.icons.trailing)

  // Step 6: Tailwind version-aware class syntax
  IF cssVersion === 4:
    // Tailwind v4: @theme variables, oklch colors, container queries
    // tokenMap comes from parsed untitled-ui-token-map.yaml (or equivalent for other libraries)
    classes = applyV4Syntax(classes, tokenMap)
  // v3 classes are default — no transformation needed

  RETURN {
    tag,
    className: classes.join(" "),
    leadingIcon,
    trailingIcon,
    children: component.children ?? "{children}"
  }
```

### Tailwind Tag Mapping

Maps `ComponentType` to native HTML elements (no library components).

```
// Pseudocode — NOT implementation code
TAILWIND_TAG_MAP = {
  "button": "button",
  "input": "input",
  "select": "select",
  "badge": "span",
  "card": "div",
  "breadcrumb": "nav",
  "pagination": "nav",
  "avatar-group": "div",
  "dialog": "dialog",
  "table": "table",
  "tabs": "div",
  "toast": "div",
  "checkbox": "input",        // type="checkbox" added via props
  "tooltip": "div",
  "dropdown-menu": "div",
  // Extended types (v2.12.0)
  "toggle": "button",         // role="switch" added via props
  "radio": "input",           // type="radio" added via props
  "textarea": "textarea",
  "slider": "input",          // type="range" added via props
  "progress": "progress",
  "alert": "div",             // role="alert" added via props
  "sidebar": "aside",
  "file-upload": "div",
}
```

### Tailwind Intent Color Mapping

Maps `ComponentIntent` to Tailwind color utility classes.

```
// Pseudocode — NOT implementation code
TAILWIND_INTENT_COLORS = {
  // Action intents
  "primary": ["bg-blue-600", "text-white", "hover:bg-blue-700"],
  "secondary": ["bg-gray-100", "text-gray-900", "hover:bg-gray-200"],
  "tertiary": ["bg-transparent", "text-gray-700", "hover:bg-gray-50"],
  "destructive": ["bg-red-600", "text-white", "hover:bg-red-700"],
  "link": ["bg-transparent", "text-blue-600", "hover:underline"],
  "ghost": ["bg-transparent", "text-gray-700", "hover:bg-gray-100"],

  // Feedback intents
  "success": ["bg-green-50", "text-green-700", "border-green-200"],
  "warning": ["bg-yellow-50", "text-yellow-700", "border-yellow-200"],
  "info": ["bg-blue-50", "text-blue-700", "border-blue-200"],
  "error": ["bg-red-50", "text-red-700", "border-red-200"],
}
```

### Tailwind Size Mapping

Maps `ComponentSize` to spacing and typography classes.

```
// Pseudocode — NOT implementation code
TAILWIND_SIZE_CLASSES = {
  "xs": ["px-2", "py-1", "text-xs"],
  "sm": ["px-3", "py-1.5", "text-sm"],
  "md": ["px-4", "py-2", "text-sm"],
  "lg": ["px-5", "py-2.5", "text-base"],
  "xl": ["px-6", "py-3", "text-base"],
  "2xl": ["px-7", "py-4", "text-lg"],
}
```

### Tailwind State Mapping

Maps `ComponentState` to Tailwind modifier and utility classes.

```
// Pseudocode — NOT implementation code
TAILWIND_STATE_CLASSES = {
  "default": [],                                          // No additional classes
  "hover": ["hover:shadow-sm"],                           // Applied via CSS pseudo-class
  "focused": ["focus:ring-2", "focus:ring-blue-500", "focus:outline-none"],
  "disabled": ["opacity-50", "cursor-not-allowed", "pointer-events-none"],
  "loading": ["animate-pulse", "cursor-wait"],
  "active": ["ring-2", "ring-blue-500"],
  "selected": ["bg-blue-50", "ring-1", "ring-blue-200"],
  "error": ["ring-2", "ring-red-500", "border-red-300"],
  "readonly": ["bg-gray-50", "cursor-default"],
  "indeterminate": [],                                    // Handled via HTML attribute
}
```

### Tailwind Base Classes

Default structural classes per component type.

```
// Pseudocode — NOT implementation code
TAILWIND_BASE_CLASSES = {
  "button": ["inline-flex", "items-center", "justify-center", "rounded-md", "font-medium",
             "transition-colors", "focus-visible:outline-none"],
  "input": ["flex", "w-full", "rounded-md", "border", "border-gray-300",
            "bg-white", "shadow-sm", "transition-colors"],
  "select": ["flex", "w-full", "rounded-md", "border", "border-gray-300",
             "bg-white", "shadow-sm", "appearance-none"],
  "badge": ["inline-flex", "items-center", "rounded-full", "border", "font-medium"],
  "card": ["rounded-lg", "border", "border-gray-200", "bg-white", "shadow-sm"],
  "breadcrumb": ["flex", "items-center", "gap-2", "text-sm"],
  "pagination": ["flex", "items-center", "gap-1"],
  "avatar-group": ["flex", "-space-x-2"],
  "dialog": ["fixed", "inset-0", "z-50", "flex", "items-center", "justify-center"],
  "table": ["w-full", "border-collapse", "text-sm"],
  "tabs": ["flex", "border-b", "border-gray-200"],
  "toast": ["fixed", "bottom-4", "right-4", "z-50", "rounded-lg", "border", "shadow-lg", "p-4"],
  "checkbox": ["h-4", "w-4", "rounded", "border", "border-gray-300"],
  "tooltip": ["absolute", "z-50", "rounded-md", "bg-gray-900", "px-3", "py-1.5",
              "text-xs", "text-white", "shadow-md"],
  "dropdown-menu": ["absolute", "z-50", "min-w-[8rem]", "rounded-md", "border",
                    "bg-white", "p-1", "shadow-md"],
  // Extended types (v2.12.0)
  "toggle": ["inline-flex", "items-center", "justify-center", "rounded-md",
             "font-medium", "transition-colors"],
  "radio": ["h-4", "w-4", "rounded-full", "border", "border-gray-300"],
  "textarea": ["flex", "w-full", "rounded-md", "border", "border-gray-300",
               "bg-white", "shadow-sm", "resize-vertical", "min-h-[80px]"],
  "slider": ["w-full", "h-2", "rounded-full", "bg-gray-200", "appearance-none",
             "cursor-pointer"],
  "progress": ["w-full", "h-2", "rounded-full", "bg-gray-200", "overflow-hidden"],
  "alert": ["relative", "w-full", "rounded-lg", "border", "p-4",
            "flex", "items-start", "gap-3"],
  "sidebar": ["flex", "flex-col", "h-full", "border-r", "border-gray-200", "bg-white"],
  "file-upload": ["flex", "flex-col", "items-center", "justify-center", "rounded-lg",
                  "border-2", "border-dashed", "border-gray-300", "bg-gray-50",
                  "p-6", "text-center", "cursor-pointer", "hover:border-gray-400"],
}
```

### Inline SVG Icon Generation

When `iconPackage` is null, icons are rendered as inline SVGs extracted from Figma.

```
// Pseudocode — NOT implementation code
function generateInlineSVG(figmaIconName):
  // The figma_to_react MCP tool already extracts SVG paths from Figma
  // This function wraps them in a sized SVG element with Tailwind classes
  RETURN """
    <svg className="h-5 w-5" viewBox="0 0 24 24" fill="none" stroke="currentColor"
         strokeWidth={2} strokeLinecap="round" strokeLinejoin="round"
         aria-hidden="true">
      {/* SVG path extracted from Figma for '{figmaIconName}' */}
      {figmaSvgPaths[figmaIconName]}
    </svg>
  """

  // If SVG path not available from Figma extraction:
  // RETURN placeholder with TODO comment:
  // <span className="h-5 w-5 inline-block" aria-hidden="true">
  //   {/* TODO: replace with SVG for '{figmaIconName}' */}
  // </span>
```

### Tailwind v4 Syntax Adaptation

When Layer 1 detects `cssVersion === 4`, adapt class output using the token map for semantic replacements.

```
// Pseudocode — NOT implementation code
// Expanded signature: applyV4Syntax(classes, tokenMap, opts?)
//   classes:  string[] — array of Tailwind utility classes
//   tokenMap: object   — parsed token map YAML (semantic_mapping section)
//                        from untitled-ui-token-map.yaml or equivalent
//   opts:     object?  — { strategy?: "conservative" | "aggressive" }
//                        conservative (default): keep original if no mapping
//                        aggressive: warn on unmapped raw colors
//
// Returns: string[] — transformed classes

function applyV4Syntax(classes, tokenMap, opts = { strategy: "conservative" }):
  // Step 1: Build reverse lookup from token map
  // Maps raw Tailwind color utilities → semantic equivalents
  // e.g., "text-purple-600" → "text-fg-brand-primary"
  //        "bg-white"       → "bg-bg-primary"
  reverseLookup = buildReverseLookup(tokenMap)

  result = []
  FOR cls IN classes:
    // Step 2: Handle modifier prefixes (hover:, sm:, dark:, focus:, etc.)
    // Split on last colon to separate modifier chain from base utility
    // e.g., "hover:sm:text-gray-900" → prefix="hover:sm:", base="text-gray-900"
    IF cls contains ":":
      lastColon = cls.lastIndexOf(":")
      prefix = cls.slice(0, lastColon + 1)
      base = cls.slice(lastColon + 1)
    ELSE:
      prefix = ""
      base = cls

    // Step 3: Check if base utility has a semantic replacement
    IF reverseLookup.has(base):
      // Replace raw color with semantic token class
      result.push(prefix + reverseLookup.get(base))
    ELSE:
      // Step 4: Non-color utilities pass through unchanged
      // (spacing, layout, typography, etc. are version-agnostic)
      result.push(cls)

      // Step 4b: In aggressive mode, warn on unmapped raw color patterns
      IF opts.strategy === "aggressive" AND isRawColorUtility(base):
        log("WARNING: unmapped raw color '{base}' — consider adding to token map")

  RETURN result


// Build reverse lookup: raw Tailwind utility → semantic class
// Input: tokenMap with semantic_mapping (intent → semantic class)
// Output: Map<rawUtility, semanticClass>
function buildReverseLookup(tokenMap):
  lookup = new Map()
  IF NOT tokenMap?.semantic_mapping:
    RETURN lookup

  // Known raw Tailwind equivalents for common UntitledUI CSS variable values
  // This maps the raw color that a CSS variable resolves to back to the semantic class
  RAW_COLOR_MAP = {
    // Text/foreground
    "text-gray-900":    "text-fg-primary",        // --fg-primary: #101828
    "text-gray-700":    "text-fg-secondary",       // --fg-secondary: #344054
    "text-gray-600":    "text-fg-tertiary",        // --fg-tertiary: #475467
    "text-gray-500":    "text-fg-quaternary",      // --fg-quaternary: #667085
    "text-purple-600":  "text-fg-brand-primary",   // --fg-brand-primary: #7F56D9
    "text-purple-700":  "text-fg-brand-secondary", // --fg-brand-secondary: #6941c6
    "text-red-600":     "text-fg-error-primary",   // --fg-error-primary: #D92D20
    "text-green-600":   "text-fg-success-primary", // --fg-success-primary: #039855
    "text-yellow-700":  "text-fg-warning-primary", // --fg-warning-primary: #DC6803
    "text-white":       "text-fg-white",
    // Background
    "bg-white":         "bg-bg-primary",           // --bg-primary: #ffffff
    "bg-gray-50":       "bg-bg-secondary",         // --bg-secondary: #f9fafb
    "bg-gray-100":      "bg-bg-tertiary",          // --bg-tertiary: #f2f4f7
    "bg-gray-200":      "bg-bg-quaternary",        // --bg-quaternary: #e4e7ec
    "bg-purple-600":    "bg-bg-brand-solid",       // --bg-brand-solid: #7F56D9
    "bg-purple-50":     "bg-bg-brand-primary",     // --bg-brand-primary: #f4ebff
    "bg-red-50":        "bg-bg-error-primary",     // --bg-error-primary: #FEF3F2
    "bg-green-50":      "bg-bg-success-primary",   // --bg-success-primary: #ECFDF3
    "bg-yellow-50":     "bg-bg-warning-primary",   // --bg-warning-primary: #FFFAEB
    // Border
    "border-gray-300":  "border-border-primary",   // --border-primary: #d0d5dd
    "border-gray-200":  "border-border-secondary", // --border-secondary: #e4e7ec
    "border-purple-300":"border-border-brand",     // --border-brand: #d6bbfb
    "border-red-300":   "border-border-error",     // --border-error: #FDA29B
    // Ring
    "ring-purple-300":  "ring-border-brand",
    "ring-red-300":     "ring-border-error",
  }

  FOR [raw, semantic] IN RAW_COLOR_MAP:
    lookup.set(raw, semantic)

  RETURN lookup


// Detect raw Tailwind color utilities (for aggressive mode warnings)
function isRawColorUtility(cls):
  // Matches: text-{color}-{shade}, bg-{color}-{shade}, border-{color}-{shade}
  // Does NOT match semantic tokens (text-fg-*, bg-bg-*, border-border-*)
  RETURN cls matches /^(text|bg|border|ring)-(red|blue|green|yellow|purple|gray|slate|zinc|neutral|stone|orange|amber|lime|emerald|teal|cyan|sky|indigo|violet|fuchsia|pink|rose)-\d+$/
    AND NOT cls matches /^(text-fg-|bg-bg-|border-border-|ring-border-)/
```

---

## Code Generation with Adapter

Shared generation logic that works with any adapter.

```
// Pseudocode — NOT implementation code
function generateComponentCode(semanticIR, adapter):
  // Guard: text-only mode returns no code
  IF adapter is null:
    RETURN { imports: [], jsx: "", mode: "text-only" }

  imports = []
  jsxFragments = []

  FOR component IN semanticIR.components:
    // Dispatch to adapter-specific or Tailwind generation
    IF adapter.composability === "inline":
      // Tailwind adapter: generate raw HTML + className
      result = generateTailwindComponent(component, adapter.cssVersion)
      jsxFragments.push(renderInlineJSX(result))

    ELIF adapter.composability === "flat":
      // Library adapter (props-based): e.g., UntitledUI
      mapping = adapter[component.type]
      IF mapping is null:
        // DEPTH-001 FIX: unhandled type falls through to Tailwind
        log("WARNING: {adapter.name} has no mapping for '{component.type}' — using Tailwind fallback")
        result = generateTailwindComponent(component, null)
        jsxFragments.push(renderInlineJSX(result))
        jsxFragments.push("// TODO: {component.type} not yet supported by {adapter.name} — using Tailwind fallback")
        CONTINUE

      variantProp = mapping.propName
      variantValue = mapping.variants[component.intent] ?? component.intent
      sizeProp = mapping.sizeProp
      sizeValue = mapping.sizes[component.size] ?? component.size

      // Icon imports via adapter iconMap (with fallback)
      IF component.icons.leading:
        iconResult = resolveIconName(component.icons.leading, adapter)
        imports.push("import { " + iconResult.name + " } from '" + adapter.iconPackage + "'")
        IF NOT iconResult.verified:
          imports.push(iconResult.comment)

      jsxFragments.push(renderFlatJSX(component, mapping, variantProp, variantValue, sizeProp, sizeValue))

    ELIF adapter.composability === "compound":
      // Library adapter (subcomponent): e.g., shadcn/ui
      mapping = adapter[component.type]
      IF mapping is null:
        log("WARNING: {adapter.name} has no mapping for '{component.type}' — using Tailwind fallback")
        result = generateTailwindComponent(component, null)
        jsxFragments.push(renderInlineJSX(result))
        jsxFragments.push("// TODO: {component.type} not yet supported by {adapter.name} — using Tailwind fallback")
        CONTINUE

      jsxFragments.push(generateCompoundJSX(component, adapter, mapping))
      imports.push(...resolveCompoundImports(component, adapter))

  RETURN {
    imports: deduplicate(imports),
    jsx: jsxFragments.join("\n"),
    mode: adapter.composability
  }
```

### Compound JSX Generation (DEPTH-008)

Contract for shadcn/ui subcomponent pattern generation.

```
// Pseudocode — NOT implementation code
function generateCompoundJSX(component, adapter, mapping):
  // Input: SemanticComponent, LibraryAdapter, AdapterTypeMapping
  // Output: string (JSX with subcomponent hierarchy)

  // Subcomponent hierarchy defined per component type in the adapter
  // Example for "select":
  //   <Select>
  //     <SelectTrigger>
  //       <SelectValue placeholder="..." />
  //     </SelectTrigger>
  //     <SelectContent>
  //       <SelectItem value="...">...</SelectItem>
  //     </SelectContent>
  //   </Select>

  hierarchy = mapping.subcomponentHierarchy
  IF hierarchy is null:
    // Type has no subcomponent pattern — render as flat
    RETURN renderFlatJSX(component, mapping, ...)

  // Build JSX from hierarchy template, substituting IR values
  jsx = hierarchy.template
  jsx = jsx.replace("{variant}", mapping.variants[component.intent])
  jsx = jsx.replace("{size}", mapping.sizes[component.size])
  jsx = jsx.replace("{children}", component.children ?? "{children}")

  RETURN jsx
```

---

## Cross-References

- [semantic-ir.md](semantic-ir.md) — SemanticComponent interface and adapter contract
- [icon-mapping.md](icon-mapping.md) — Cross-library icon name mappings and fallback chain
- [figma-framework-detection.md](figma-framework-detection.md) — How the detected framework feeds into adapter selection
