# Cross-Library Icon Mapping

Maps Figma icon names to library-specific import names across UntitledUI, Lucide (shadcn/ui),
and MUI. The 10-entry curated fast-path per adapter covers the most common icons with known
name differences. All other icons use the kebab-to-PascalCase fallback (DEPTH-002).

## Architecture

```
Figma Icon Name (kebab-case)
  ↓
Adapter iconMap lookup (10-entry fast-path)
  ↓ hit                    ↓ miss
Library import name    kebab-to-PascalCase fallback
                         + "// TODO: verify icon import" comment
```

Each adapter in [library-adapters.md](library-adapters.md) contains a curated `iconMap`
(40 entries for UntitledUI, 10 for shadcn/Lucide — see per-adapter sections).
This file provides the comprehensive cross-library reference and the fallback algorithm.

## Cross-Library Mapping Table

High-frequency icons with known name differences across libraries.
Entries marked with `=` indicate the name matches the kebab-to-PascalCase fallback
(included for documentation completeness, not strictly needed in the curated map).

### Navigation Icons

| Figma Name | UntitledUI (`@untitledui/icons`) | Lucide (`lucide-react`) | MUI (`@mui/icons-material`) | Notes |
|------------|----------------------------------|-------------------------|-----------------------------|-------|
| `arrow-left` | `ArrowLeft` = | `ArrowLeft` = | `ArrowBackIcon` | MUI uses direction words |
| `arrow-right` | `ArrowRight` = | `ArrowRight` = | `ArrowForwardIcon` | MUI uses direction words |
| `arrow-up` | `ArrowUp` = | `ArrowUp` = | `ArrowUpwardIcon` | |
| `arrow-down` | `ArrowDown` = | `ArrowDown` = | `ArrowDownwardIcon` | |
| `chevron-left` | `ChevronLeft` = | `ChevronLeft` = | `ChevronLeftIcon` = | |
| `chevron-right` | `ChevronRight` = | `ChevronRight` = | `ChevronRightIcon` = | |
| `chevron-down` | `ChevronDown` = | `ChevronDown` = | `ExpandMoreIcon` | MUI semantic name |
| `chevron-up` | `ChevronUp` = | `ChevronUp` = | `ExpandLessIcon` | MUI semantic name |
| `home-line` | `HomeLine` | `Home` | `HomeIcon` | UntitledUI adds `-line` suffix |
| `menu-01` | `Menu01` | `Menu` | `MenuIcon` | UntitledUI adds numeric suffix |

### Action Icons

| Figma Name | UntitledUI | Lucide | MUI | Notes |
|------------|-----------|--------|-----|-------|
| `plus` | `Plus` = | `Plus` = | `AddIcon` | MUI uses verb |
| `x` | `X` = | `X` = | `CloseIcon` | MUI uses semantic name |
| `x-close` | `XClose` | `X` | `CloseIcon` | UntitledUI explicit close |
| `check` | `Check` = | `Check` = | `CheckIcon` = | |
| `check-circle` | `CheckCircle` = | `CheckCircle2` | `CheckCircleIcon` | Lucide adds `2` |
| `search-lg` | `SearchLg` | `Search` | `SearchIcon` | UntitledUI adds size suffix |
| `search-sm` | `SearchSm` | `Search` | `SearchIcon` | Same Lucide/MUI target |
| `edit-05` | `Edit05` | `Pencil` | `EditIcon` | All different! |
| `pencil-line` | `PencilLine` | `Pencil` | `EditIcon` | |
| `trash-01` | `Trash01` | `Trash2` | `DeleteIcon` | All different! |
| `trash-03` | `Trash03` | `Trash2` | `DeleteIcon` | UntitledUI numeric variants |
| `copy-01` | `Copy01` | `Copy` | `ContentCopyIcon` | |
| `download-01` | `Download01` | `Download` | `FileDownloadIcon` | MUI uses `File` prefix |
| `upload-01` | `Upload01` | `Upload` | `FileUploadIcon` | MUI uses `File` prefix |
| `log-out-04` | `LogOut04` | `LogOut` | `LogoutIcon` | UntitledUI numeric suffix |
| `log-in-04` | `LogIn04` | `LogIn` | `LoginIcon` | |
| `refresh-cw-01` | `RefreshCw01` | `RefreshCw` | `RefreshIcon` | |

### Content Icons

| Figma Name | UntitledUI | Lucide | MUI | Notes |
|------------|-----------|--------|-----|-------|
| `filter-lines` | `FilterLines` | `Filter` | `FilterListIcon` | All different |
| `filter-funnel-01` | `FilterFunnel01` | `Filter` | `FilterAltIcon` | |
| `stars-03` | `Stars03` | `Sparkles` | `AutoAwesomeIcon` | All different! |
| `placeholder` | `Placeholder` | `Circle` | `CircleIcon` | |
| `eye` | `Eye` = | `Eye` = | `VisibilityIcon` | MUI semantic |
| `eye-off` | `EyeOff` = | `EyeOff` = | `VisibilityOffIcon` | |
| `settings-01` | `Settings01` | `Settings` | `SettingsIcon` | |
| `settings-02` | `Settings02` | `Settings` | `SettingsIcon` | Same target |
| `bell-01` | `Bell01` | `Bell` | `NotificationsIcon` | MUI semantic |
| `calendar` | `Calendar` = | `Calendar` = | `CalendarTodayIcon` | |
| `clock` | `Clock` = | `Clock` = | `AccessTimeIcon` | MUI semantic |
| `mail-01` | `Mail01` | `Mail` | `MailIcon` = | |
| `link-01` | `Link01` | `Link` | `LinkIcon` | |
| `image-01` | `Image01` | `Image` | `ImageIcon` | |
| `file-06` | `File06` | `File` | `InsertDriveFileIcon` | |

### User & Social Icons

| Figma Name | UntitledUI | Lucide | MUI | Notes |
|------------|-----------|--------|-----|-------|
| `user-01` | `User01` | `User` | `PersonIcon` | MUI semantic |
| `user-circle` | `UserCircle` = | `UserCircle2` | `AccountCircleIcon` | Lucide adds `2` |
| `users-01` | `Users01` | `Users` | `GroupIcon` | MUI semantic |
| `heart` | `Heart` = | `Heart` = | `FavoriteIcon` | MUI semantic |
| `star-01` | `Star01` | `Star` | `StarIcon` | |
| `share-07` | `Share07` | `Share2` | `ShareIcon` | |
| `message-circle-02` | `MessageCircle02` | `MessageCircle` | `ChatBubbleIcon` | |

### Status Icons

| Figma Name | UntitledUI | Lucide | MUI | Notes |
|------------|-----------|--------|-----|-------|
| `alert-circle` | `AlertCircle` = | `AlertCircle` = | `ErrorIcon` | MUI semantic |
| `alert-triangle` | `AlertTriangle` = | `AlertTriangle` = | `WarningIcon` | MUI semantic |
| `info-circle` | `InfoCircle` | `Info` | `InfoIcon` | |
| `help-circle` | `HelpCircle` = | `HelpCircle` = | `HelpIcon` | |
| `check-circle` | `CheckCircle` = | `CheckCircle2` | `CheckCircleIcon` | |
| `x-circle` | `XCircle` = | `XCircle` = | `CancelIcon` | MUI semantic |
| `loader-01` | `Loader01` | `Loader2` | `CircularProgressIcon` | Animated/spinner |
| `minus` | `Minus` = | `Minus` = | `RemoveIcon` | MUI semantic |

## Curated Fast-Path (Per Adapter)

Each adapter's `iconMap` contains curated entries — the icons most likely to appear
in Figma designs. UntitledUI has 40 entries (v2.12.0) covering all categories;
Lucide/shadcn has 10 entries focused on divergent names.

### UntitledUI Fast-Path (40 entries, v2.12.0)

```
// Full 40-entry map in UNTITLEDUI_ADAPTER.iconMap
// Organized by category: Navigation (10), Action (17), Content (15),
// User & Social (7), Status (7). See library-adapters.md for the complete list.
// UntitledUI naming closely matches kebab-to-PascalCase, so the fast-path
// primarily provides verified lookups (avoiding "// TODO" comments).
```

### Lucide (shadcn/ui) Fast-Path

```
// These 10 entries are in SHADCN_ADAPTER.iconMap
// Lucide uses SIMPLIFIED names — the fast-path catches divergences.
"arrow-left"     → "ArrowLeft"      // = (matches fallback)
"arrow-right"    → "ArrowRight"     // = (matches fallback)
"home-line"      → "Home"           // ≠ fallback would produce "HomeLine"
"log-out-04"     → "LogOut"         // ≠ fallback would produce "LogOut04"
"chevron-right"  → "ChevronRight"   // = (matches fallback)
"chevron-down"   → "ChevronDown"    // = (matches fallback)
"filter-lines"   → "Filter"         // ≠ fallback would produce "FilterLines"
"stars-03"       → "Sparkles"       // ≠ COMPLETELY DIFFERENT icon name
"pencil-line"    → "Pencil"         // ≠ fallback would produce "PencilLine"
"placeholder"    → "Circle"         // ≠ fallback would produce "Placeholder"
```

**Why these 10?** They cover the highest-frequency icons in UntitledUI Figma designs
(navigation, actions, content) where Lucide's naming diverges. The `=` entries provide
verified fast-path even when fallback would work, avoiding the `// TODO` comment.

### MUI Fast-Path

MUI is not a primary adapter target (no `MUI_ADAPTER` defined in v1), but the mapping
table above serves as a reference for future adapter development. MUI has the most
divergent naming (semantic names like `VisibilityIcon`, `PersonIcon`, `FavoriteIcon`).

## Fallback Algorithm (DEPTH-002, BACK-006)

When an icon name is NOT in the adapter's curated `iconMap`, the fallback chain applies.
This is defined in [semantic-ir.md](semantic-ir.md) §Unmapped Icon Fallback and
replicated here with the v2.12.0 style-suffix detection extension.

```
// Pseudocode — NOT implementation code
function resolveIconName(figmaName, adapter):
  // Step 1: Curated fast-path lookup
  IF adapter.iconMap.has(figmaName):
    RETURN { name: adapter.iconMap[figmaName], verified: true }

  // Step 1.5: Style-suffix detection (v2.12.0)
  // UntitledUI icons use style suffixes: -line, -duocolor, -duotone, -solid
  // These indicate icon STYLE, not identity. For non-UntitledUI adapters,
  // the suffix must be stripped to find the correct import.
  // Example: "home-line" → Lucide import is "Home" (not "HomeLine")
  styleSuffix = null
  STYLE_SUFFIXES = ["-line", "-duocolor", "-duotone", "-solid"]
  FOR suffix IN STYLE_SUFFIXES:
    IF figmaName.endsWith(suffix):
      styleSuffix = suffix
      baseName = figmaName.slice(0, -suffix.length)
      BREAK

  // For non-UntitledUI adapters, try the base name (without suffix) in the map
  IF styleSuffix AND adapter.name !== "untitled_ui":
    IF adapter.iconMap.has(baseName):
      RETURN { name: adapter.iconMap[baseName], verified: true, styleSuffix }

  // Step 2: kebab-to-PascalCase conversion
  // Use baseName for non-UntitledUI adapters when suffix detected
  nameToConvert = (styleSuffix AND adapter.name !== "untitled_ui") ? baseName : figmaName
  pascalName = nameToConvert
    .split("-")
    .map(segment =>
      IF isNumeric(segment): segment    // "04" stays "04"
      ELSE: capitalize(segment)         // "arrow" → "Arrow"
    )
    .join("")

  // Step 2.5: File-type icon package routing (v2.12.0, UntitledUI only)
  // Icons prefixed with "file-type-" use @untitledui/file-icons package
  importPath = adapter.iconPackage
  IF adapter.name === "untitled_ui" AND figmaName.startsWith("file-type-"):
    importPath = "@untitledui/file-icons"

  // Step 3: Return with unverified flag + TODO comment
  RETURN {
    name: pascalName,
    verified: false,
    importPath: importPath,
    styleSuffix: styleSuffix,
    comment: "// TODO: verify icon import — auto-converted from '{figmaName}'"
  }
```

### Style Suffix Reference (v2.12.0)

UntitledUI provides multiple style variants for the same icon. Figma designs use
the suffixed name (e.g., `home-line`), but other libraries use a single name.

| Suffix | UntitledUI Style | Lucide Equivalent | Notes |
|--------|-----------------|-------------------|-------|
| `-line` | Line/outline style (default) | Base name (no suffix) | Most common — `home-line` → Lucide `Home` |
| `-solid` | Filled/solid style | Base name (no suffix) | `home-solid` → Lucide `Home` |
| `-duocolor` | Two-color style | Base name (no suffix) | Premium — `home-duocolor` → Lucide `Home` |
| `-duotone` | Duotone style | Base name (no suffix) | Premium — `home-duotone` → Lucide `Home` |

**Rule**: For UntitledUI adapter, preserve the suffix (it maps to a real import).
For all other adapters, strip the suffix before conversion.

### Fallback Accuracy

The kebab-to-PascalCase fallback accuracy by library:

| Library | Estimated Accuracy | Reason |
|---------|-------------------|--------|
| UntitledUI | ~95% | Naming convention closely matches kebab-to-PascalCase |
| Lucide | ~70% | Simplified names (`Filter` not `FilterLines`) cause mismatches |
| MUI | ~20% | Semantic naming (`PersonIcon` not `User01Icon`) causes most mismatches |

**Recommendation**: For Lucide, consider expanding the curated map to 20-30 entries
in a future iteration to improve hit rate. The v2.12.0 style-suffix detection improves
Lucide accuracy to ~80% by stripping UntitledUI-specific suffixes before conversion.
For MUI, the curated map would need 50+ entries to be useful — a full mapping table
would be more appropriate.

### Edge Cases

| Scenario | Behavior |
|----------|----------|
| Icon name is empty string | Skip icon, no import generated |
| Icon name contains `/` (path separator) | Strip path prefix: `"Icons/arrow-left"` → `"arrow-left"` → lookup |
| Icon name contains `=` (variant separator) | Skip — this is a variant prop, not an icon name |
| Numeric-only name (e.g., `"01"`) | Fallback produces `"01"` — emit TODO comment |
| Icon name is already PascalCase | Fallback preserves it: `"ArrowLeft"` → `"ArrowLeft"` |

## Extension Protocol

To add icons to the curated fast-path:

1. Identify Figma icon names that appear frequently in designs (analytics or manual review)
2. Look up the correct import name in the target library's documentation
3. Add the entry to the adapter's `iconMap` in [library-adapters.md](library-adapters.md)
4. Add the cross-library mapping row to the appropriate table in this file
5. Only add entries where the name **differs** from the kebab-to-PascalCase fallback

To add a new library column:

1. Add a column to each category table above
2. Document the library's naming convention pattern
3. Note the estimated fallback accuracy
4. If accuracy < 50%, recommend a larger curated map or full mapping table

## Cross-References

- [semantic-ir.md](semantic-ir.md) — `resolveIconName()` fallback algorithm definition
- [library-adapters.md](library-adapters.md) — Per-adapter `iconMap` entries (40 for UntitledUI, 10 for shadcn)
- [figma-framework-signatures.md](figma-framework-signatures.md) — Icon naming patterns used for framework detection
