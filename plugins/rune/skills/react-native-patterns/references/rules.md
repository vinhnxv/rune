# React Native Patterns — Detailed Examples

## 1. List Performance (CRITICAL)

### `list-use-flashlist`

```tsx
// NON-COMPLIANT: FlatList — creates new cell on every scroll
import { FlatList } from 'react-native'

function ContactList({ contacts }) {
  return (
    <FlatList
      data={contacts}
      renderItem={({ item }) => <ContactRow contact={item} />}
      keyExtractor={item => item.id}
    />
  )
}

// COMPLIANT: FlashList — recycles cells like native UICollectionView
import { FlashList } from '@shopify/flash-list'

function ContactList({ contacts }) {
  return (
    <FlashList
      data={contacts}
      renderItem={({ item }) => <ContactRow contact={item} />}
      keyExtractor={item => item.id}
      estimatedItemSize={72} // REQUIRED: height of one row in pixels
    />
  )
}
```

### `list-memoize-items`

```tsx
// NON-COMPLIANT: Re-renders every item when parent re-renders
function ContactRow({ contact }) {
  return <View><Text>{contact.name}</Text></View>
}

// COMPLIANT: Only re-renders when props change
const ContactRow = React.memo(function ContactRow({ contact }) {
  return <View><Text>{contact.name}</Text></View>
})
```

### `list-stable-callbacks`

```tsx
// NON-COMPLIANT: New function reference on every render → FlashList re-renders all cells
function ContactList({ contacts, onSelect }) {
  return (
    <FlashList
      data={contacts}
      renderItem={({ item }) => (
        <Pressable onPress={() => onSelect(item.id)}>
          <Text>{item.name}</Text>
        </Pressable>
      )}
    />
  )
}

// COMPLIANT: Stable callback + memoized renderItem
function ContactList({ contacts, onSelect }) {
  const handleSelect = useCallback((id: string) => onSelect(id), [onSelect])

  const renderItem = useCallback(({ item }) => (
    <ContactRow contact={item} onSelect={handleSelect} />
  ), [handleSelect])

  return <FlashList data={contacts} renderItem={renderItem} estimatedItemSize={72} />
}
```

### `list-no-inline-styles`

```tsx
// NON-COMPLIANT: New object on every render
function ContactRow({ contact }) {
  return (
    <View style={{ padding: 16, flexDirection: 'row', alignItems: 'center' }}>
      <Text style={{ fontSize: 16, fontWeight: '600' }}>{contact.name}</Text>
    </View>
  )
}

// COMPLIANT: StyleSheet.create — cached and optimized
function ContactRow({ contact }) {
  return (
    <View style={styles.row}>
      <Text style={styles.name}>{contact.name}</Text>
    </View>
  )
}

const styles = StyleSheet.create({
  row: { padding: 16, flexDirection: 'row', alignItems: 'center' },
  name: { fontSize: 16, fontWeight: '600' },
})
```

## 2. Animation (HIGH)

### `anim-gpu-properties`

```tsx
// NON-COMPLIANT: Animates layout property → runs on JS thread
const animatedStyle = useAnimatedStyle(() => ({
  width: withSpring(expanded ? 300 : 100), // Layout recalculation!
  height: withSpring(expanded ? 200 : 50),
}))

// COMPLIANT: Transform + opacity → runs on UI thread (GPU)
const animatedStyle = useAnimatedStyle(() => ({
  transform: [
    { scaleX: withSpring(expanded ? 1 : 0.33) },
    { scaleY: withSpring(expanded ? 1 : 0.25) },
  ],
  opacity: withSpring(expanded ? 1 : 0.5),
}))
```

### `anim-reanimated-derived`

```tsx
// NON-COMPLIANT: Multiple useAnimatedStyle for derived values
const opacityStyle = useAnimatedStyle(() => ({ opacity: progress.value }))
const scaleStyle = useAnimatedStyle(() => ({
  transform: [{ scale: interpolate(progress.value, [0, 1], [0.8, 1]) }],
}))

// COMPLIANT: Single derived value + single animated style
const scale = useDerivedValue(() =>
  interpolate(progress.value, [0, 1], [0.8, 1])
)

const animatedStyle = useAnimatedStyle(() => ({
  opacity: progress.value,
  transform: [{ scale: scale.value }],
}))
```

## 3. Navigation (HIGH)

### `nav-native-stack`

```tsx
// NON-COMPLIANT: JS-based stack — transitions are JS-driven, drops frames
import { createStackNavigator } from '@react-navigation/stack'
const Stack = createStackNavigator()

// COMPLIANT: Native stack — uses UINavigationController / Fragment
import { createNativeStackNavigator } from '@react-navigation/native-stack'
const Stack = createNativeStackNavigator()

// Or with Expo Router (built on native-stack)
// app/(tabs)/index.tsx — file-based routing with native transitions
```

## 4. UI Patterns (HIGH)

### `ui-expo-image`

```tsx
// NON-COMPLIANT: Built-in Image — no caching, no placeholders, no transitions
import { Image } from 'react-native'
<Image source={{ uri: photo.url }} style={{ width: 200, height: 200 }} />

// COMPLIANT: expo-image — disk/memory cache, blurhash, crossfade
import { Image } from 'expo-image'
<Image
  source={photo.url}
  placeholder={{ blurhash: photo.blurhash }}
  transition={200}
  contentFit="cover"
  style={{ width: 200, height: 200 }}
/>
```

### `ui-safe-area`

```tsx
// NON-COMPLIANT: Hardcoded padding for notch
<View style={{ paddingTop: 44 }}>{/* Only correct for one device */}</View>

// COMPLIANT: Dynamic safe area insets
import { useSafeAreaInsets } from 'react-native-safe-area-context'

function Screen({ children }) {
  const insets = useSafeAreaInsets()
  return (
    <View style={{ flex: 1, paddingTop: insets.top, paddingBottom: insets.bottom }}>
      {children}
    </View>
  )
}
```

### `ui-pressable`

```tsx
// NON-COMPLIANT: TouchableOpacity — limited interaction states
import { TouchableOpacity } from 'react-native'
<TouchableOpacity onPress={onPress}>
  <Text>Tap me</Text>
</TouchableOpacity>

// COMPLIANT: Pressable — supports pressed, hover, focus states + hitSlop
import { Pressable } from 'react-native'
<Pressable
  onPress={onPress}
  hitSlop={8}
  style={({ pressed }) => [
    styles.button,
    pressed && styles.buttonPressed,
  ]}
>
  <Text>Tap me</Text>
</Pressable>
```

### `ui-context-menus`

```tsx
// COMPLIANT: Native context menu on long press
import { MenuView } from '@react-native-menu/menu'

<MenuView
  title="Actions"
  onPressAction={({ nativeEvent }) => handleAction(nativeEvent.event)}
  actions={[
    { id: 'edit', title: 'Edit', image: 'pencil' },
    { id: 'delete', title: 'Delete', attributes: { destructive: true }, image: 'trash' },
  ]}
>
  <Pressable><Text>Long press me</Text></Pressable>
</MenuView>
```

## 5. State Management (MEDIUM)

### `state-minimize-subscriptions`

```tsx
// NON-COMPLIANT: Re-renders on ANY store change
function Counter() {
  const store = useStore() // Subscribes to entire store
  return <Text>{store.count}</Text>
}

// COMPLIANT: Re-renders only when count changes
function Counter() {
  const count = useStore(state => state.count) // Subscribes to slice
  return <Text>{count}</Text>
}
```

## 6. Rendering (MEDIUM)

### `render-text-wrapping`

```tsx
// NON-COMPLIANT: Bare text crashes React Native
function Greeting({ name }) {
  return <View>Hello, {name}</View> // ← CRASH: text outside <Text>
}

// COMPLIANT: All text in <Text> components
function Greeting({ name }) {
  return <View><Text>Hello, {name}</Text></View>
}
```

## 7. Monorepo (MEDIUM)

### `mono-native-deps`

```
// NON-COMPLIANT: Native dep in shared package
packages/shared/package.json:
  "dependencies": { "react-native-reanimated": "^3.0" }

// COMPLIANT: Native deps in app package only
apps/mobile/package.json:
  "dependencies": { "react-native-reanimated": "^3.0" }
packages/shared/package.json:
  "peerDependencies": { "react-native-reanimated": ">=3.0" }
```

## 8. Configuration (LOW)

### `config-fonts`

```tsx
// COMPLIANT: Pre-load fonts to prevent FOUT
import { useFonts } from 'expo-font'
import * as SplashScreen from 'expo-splash-screen'

SplashScreen.preventAutoHideAsync()

export default function RootLayout() {
  const [loaded] = useFonts({
    'Inter-Regular': require('./assets/fonts/Inter-Regular.otf'),
    'Inter-Bold': require('./assets/fonts/Inter-Bold.otf'),
  })

  useEffect(() => {
    if (loaded) SplashScreen.hideAsync()
  }, [loaded])

  if (!loaded) return null
  return <Stack />
}
```
