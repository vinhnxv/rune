---
name: react-native-patterns
description: |
  React Native and Expo best practices — list performance (FlashList),
  animations (Reanimated GPU), navigation (native stack), UI patterns
  (expo-image, safe areas), state management, and monorepo configuration.
  Trigger keywords: React Native, Expo, FlashList, Reanimated, react-navigation,
  expo-image, safe area, mobile, iOS, Android.
user-invocable: false
disable-model-invocation: false
---

# React Native Patterns

Best practices for React Native and Expo development. Organized by impact priority — list performance and animations have the biggest user-visible impact.

## When This Loads

Auto-loaded by the Stacks context router when:
- `react-native` or `expo` detected in `package.json`
- Changed files touch `.native.tsx`, `.ios.tsx`, `.android.tsx`, or React Native components
- Review/work/forge workflows involve mobile development

## Rule Categories

### 1. List Performance (CRITICAL)

Lists are the most common performance bottleneck in React Native apps.

#### `list-use-flashlist`

Replace `FlatList` with `@shopify/flash-list`. FlashList recycles cells like native UICollectionView/RecyclerView — 5-10x fewer re-renders.

```tsx
// NON-COMPLIANT
import { FlatList } from 'react-native'
<FlatList data={items} renderItem={renderItem} />

// COMPLIANT
import { FlashList } from '@shopify/flash-list'
<FlashList data={items} renderItem={renderItem} estimatedItemSize={72} />
```

**Critical**: Always provide `estimatedItemSize` — FlashList uses it for scroll position calculation.

#### `list-memoize-items`

Wrap list item components with `React.memo` to prevent re-renders when the parent list re-renders.

#### `list-stable-callbacks`

Use `useCallback` for `renderItem`, `keyExtractor`, and `onEndReached` — unstable references cause full list re-renders.

#### `list-no-inline-styles`

Move styles outside the component. Inline style objects create new references on every render, defeating memoization.

```tsx
// NON-COMPLIANT
<View style={{ padding: 16, backgroundColor: '#fff' }} />

// COMPLIANT
<View style={styles.container} />
const styles = StyleSheet.create({ container: { padding: 16, backgroundColor: '#fff' } })
```

### 2. Animation (HIGH)

Smooth 60fps animations require GPU-accelerated properties and worklet-based execution.

#### `anim-gpu-properties`

Only animate `transform` and `opacity` — these run on the UI thread. Properties like `width`, `height`, `margin`, `borderRadius` trigger layout recalculation on the JS thread.

#### `anim-reanimated-derived`

Use Reanimated `useDerivedValue` for computed animations instead of chaining `useAnimatedStyle`:

```tsx
// COMPLIANT
const scale = useDerivedValue(() => interpolate(progress.value, [0, 1], [0.8, 1]))
const animatedStyle = useAnimatedStyle(() => ({ transform: [{ scale: scale.value }] }))
```

#### `anim-gesture-detector`

Use `react-native-gesture-handler` for gesture recognition — the built-in gesture system runs on the JS thread and drops frames under load.

### 3. Navigation (HIGH)

Use native navigation stacks. JS-based navigation creates visible transition jank.

#### `nav-native-stack`

Use `@react-navigation/native-stack` (or Expo Router) — NOT `@react-navigation/stack`. The native version uses platform navigation controllers (UINavigationController on iOS, Fragment on Android).

#### `nav-native-tabs`

Use `@react-navigation/bottom-tabs` with native driver. Ensure tab icons are pre-loaded to avoid flash.

### 4. UI Patterns (HIGH)

Platform-native UI patterns that users expect from mobile apps.

#### `ui-expo-image`

Use `expo-image` instead of React Native's `<Image>`. It supports caching, blurhash placeholders, and transitions.

```tsx
import { Image } from 'expo-image'
<Image source={uri} placeholder={{ blurhash }} transition={200} contentFit="cover" />
```

#### `ui-safe-area`

Always use `react-native-safe-area-context` for safe area insets. Never hardcode notch padding.

```tsx
import { useSafeAreaInsets } from 'react-native-safe-area-context'
const insets = useSafeAreaInsets()
<View style={{ paddingTop: insets.top, paddingBottom: insets.bottom }} />
```

#### `ui-pressable`

Use `<Pressable>` with `hitSlop` instead of `<TouchableOpacity>`. Pressable supports press, hover, and focus states.

```tsx
<Pressable onPress={onPress} hitSlop={8} style={({ pressed }) => [styles.btn, pressed && styles.pressed]}>
```

#### `ui-scroll-config`

Configure `ScrollView` for the platform:
- `keyboardShouldPersistTaps="handled"` — dismiss keyboard on tap outside inputs
- `showsVerticalScrollIndicator={false}` for custom scroll indicators
- `contentContainerStyle` for padding (not wrapping View)

#### `ui-context-menus`

Use `@react-native-menu/menu` or Expo's context menu for long-press actions. Renders native iOS/Android context menus.

#### `ui-native-modals`

Use native modal presentations (`presentation: 'modal'` in navigation) instead of React Native's `<Modal>` component. Native modals support swipe-to-dismiss and proper gesture handling.

### 5. State Management (MEDIUM)

#### `state-minimize-subscriptions`

Use fine-grained selectors with Zustand/Jotai — avoid subscribing to the entire store. Each subscription triggers a re-render.

```tsx
// NON-COMPLIANT: Subscribes to entire store
const store = useStore()

// COMPLIANT: Subscribes to specific slice
const count = useStore(s => s.count)
```

#### `state-react-compiler`

React Compiler (React 19) automatically memoizes components and hooks. When using React Compiler, remove manual `useMemo`/`useCallback`/`React.memo` — they add overhead without benefit.

### 6. Rendering (MEDIUM)

#### `render-text-wrapping`

Always wrap text content in `<Text>` — React Native crashes on bare text outside `<Text>` components (unlike web).

#### `render-conditional`

For toggle UI (tabs, accordions), prefer opacity/translate animations over mount/unmount to preserve state.

### 7. Monorepo (MEDIUM)

#### `mono-native-deps`

Keep native dependencies (`react-native-*`, `expo-*`) in the app package, not shared packages. Metro bundler resolves native modules from the app's `node_modules`.

#### `mono-consistent-versions`

Use a single version of React Native across all apps in the monorepo. Mismatched versions cause native build failures.

### 8. Configuration (LOW)

#### `config-fonts`

Use `expo-font` with `useFonts` hook. Pre-load fonts in the root layout to prevent FOUT (Flash of Unstyled Text).

#### `config-design-system`

Map your design system tokens to React Native `StyleSheet` values. Use a shared theme object, not inline values.

#### `config-i18n`

Use `expo-localization` + `i18next` for internationalization. Use `Intl` APIs (polyfilled via `intl-pluralrules`) for number/date formatting.

## Full Rule Details

See [rules.md](references/rules.md) for extended examples and platform-specific considerations.
