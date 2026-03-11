# shadcn/ui Doc Pack

## Etched — shadcn/ui: Component Installation Patterns (2026-03-11)

**Source**: `doc-pack:shadcn-ui@1.0.0`
**Category**: pattern

### CLI Installation

- `npx shadcn@latest add <component>` — adds component to `components/ui/`
- Components are copied into your project, not imported as dependencies — you own the code
- Always run from project root where `components.json` exists
- Use `npx shadcn@latest diff <component>` to check for upstream updates

### Component Customization

- Modify `components/ui/<component>.tsx` directly — no upstream to break
- Use `cn()` utility from `lib/utils.ts` for conditional class merging
- Theme via CSS variables in `globals.css`, not component props
- `components.json` controls output paths, Tailwind config, and aliases

### Common Gotchas

- `components.json` must exist before `add` works — run `npx shadcn@latest init` first
- Path aliases (`@/components/ui`) must match `tsconfig.json` paths
- Some components require peer dependencies (e.g., `@radix-ui/react-*`) — CLI installs them automatically
- Tailwind CSS v4 is required for latest shadcn/ui components

## Etched — shadcn/ui: Theming and Design Tokens (2026-03-11)

**Source**: `doc-pack:shadcn-ui@1.0.0`
**Category**: pattern

### CSS Variable System

- All theme values use CSS custom properties: `--background`, `--foreground`, `--primary`, etc.
- HSL format: `--primary: 222.2 47.4% 11.2%` (no `hsl()` wrapper — Tailwind applies it)
- Dark mode: define overrides in `.dark` class or `@media (prefers-color-scheme: dark)`
- Radius: `--radius` variable controls border-radius globally

### Adding Custom Colors

- Define in `globals.css`: `--custom: 210 40% 50%`
- Extend in `tailwind.config`: `custom: "hsl(var(--custom))"`
- Use in components: `className="bg-custom text-custom-foreground"`

### Typography

- Default uses `Inter` font — override in `layout.tsx` with `next/font`
- Font variables: `--font-sans`, `--font-mono`
- Use `text-sm`, `text-base`, etc. for consistent sizing — avoid arbitrary values

## Etched — shadcn/ui: Form Patterns with React Hook Form (2026-03-11)

**Source**: `doc-pack:shadcn-ui@1.0.0`
**Category**: pattern

### Form Component Integration

- shadcn/ui Form wraps `react-hook-form` with accessible field components
- Use `<FormField>` for each input — provides label, description, error message
- Validation via `zod` schemas passed to `useForm({ resolver: zodResolver(schema) })`
- `<FormMessage>` auto-displays validation errors per field

### Best Practices

- Define Zod schema separately from form component for reuse
- Use `form.reset()` after successful submission, not manual state clearing
- Prefer controlled components (`<FormField control={form.control}>`) over uncontrolled
- Toast notifications for form success/error via `sonner` (included in shadcn/ui)
