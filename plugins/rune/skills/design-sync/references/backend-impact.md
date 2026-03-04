# Backend Impact Analysis

## Default: FRONTEND-ONLY

Design-sync tasks are frontend-only by default.
Backend changes require explicit user permission.

## Permission Detection

| Signal | Permission Level |
|--------|-----------------|
| No backend mention in task/plan | FRONTEND-ONLY |
| Plan says "frontend only" or "UI changes" | FRONTEND-ONLY |
| Plan says "full-stack" or "include API" | BACKEND-ALLOWED |
| User explicitly says "update the API too" | BACKEND-ALLOWED |

## Decision Tree

```
Does this component need backend data?
+-- NO -> FRONTEND-ONLY -> mock data + TypeScript interfaces -> proceed
+-- YES -> Does the API endpoint already exist?
    +-- YES (BACKEND-EXISTS) -> use existing API, proceed
    +-- NO -> Is it simple CRUD?
        +-- YES (BACKEND-SIMPLE) -> define TypeScript contract + mock data + TODO marker
        +-- NO (BACKEND-COMPLEX) -> STOP, escalate to planning (/rune:devise)
```

## When FRONTEND-ONLY

Workers MUST:
1. Generate TypeScript interface for expected API shape
2. Create mock data matching the interface
3. Add `// TODO: Replace mock with real API call` markers
4. Inform user of backend dependency in Seal message

## Plan Tracking Section

Every design-sync plan includes:

```markdown
## Backend Impact
- **Branch**: frontend-only | backend-exists | backend-simple | backend-complex
- **API Dependencies**: (table of endpoints if applicable)
- **Mock Data**: (location of mock files if frontend-only)
```
