# Frontend Race Condition Patterns

Detailed patterns for framework-specific frontend race conditions. Referenced by tide-watcher.md (Hotwire/Turbo, React, and Vue concurrency sections).

---

## Event Handler Serialization

### Rapid Click Race
User clicks "Submit" twice quickly. Both handlers fire, both API calls sent.

```javascript
// BAD: onclick directly calls async handler
button.addEventListener('click', async () => {
  await submitOrder();
});

// GOOD: Disable on first click, re-enable on response
button.addEventListener('click', async () => {
  if (button.disabled) return;
  button.disabled = true;
  try { await submitOrder(); }
  finally { button.disabled = false; }
});
```

### Detection Patterns
- Button/link click handlers without disabling mechanism
- Form submit handlers without submission guard
- Async handlers on frequently-fired events (scroll, resize, input) without debounce/throttle

---

## Form Submission Safety

### Double-Submit Prevention
- Server-side: Idempotency key in request header
- Client-side: Disable submit button + loading state
- Both required for safety

### Concurrent Field Validation
```javascript
// BAD: No cancellation — rapid typing sends multiple requests
input.addEventListener('input', async (e) => {
  const available = await checkUsername(e.target.value);
  setAvailability(available); // May show result for OLD value
});

// GOOD: AbortController cancels previous request
let controller;
input.addEventListener('input', async (e) => {
  controller?.abort();
  controller = new AbortController();
  try {
    const available = await checkUsername(e.target.value, { signal: controller.signal });
    setAvailability(available);
  } catch (e) {
    if (e.name === 'AbortError') return;
    throw e;
  }
});
```

---

## Hotwire/Turbo/Stimulus Lifecycle

### initialize() vs connect()

```javascript
// BAD: State in initialize() persists across Turbo navigations
export default class extends Controller {
  initialize() {
    this.count = 0; // NOT reset when navigating back to this page
  }
}

// GOOD: State in connect() resets on each page visit
export default class extends Controller {
  connect() {
    this.count = 0; // Fresh state on each Turbo visit
  }
  disconnect() {
    // Cleanup here
  }
}
```

### Handler Disposal

```javascript
// BAD: Event listener without cleanup
connect() {
  document.addEventListener('click', this.handleClick);
}

// GOOD: Paired connect/disconnect
connect() {
  this.handleClick = this.handleClick.bind(this);
  document.addEventListener('click', this.handleClick);
}
disconnect() {
  document.removeEventListener('click', this.handleClick);
}
```

### Turbo Stream Animation Race
```javascript
// BAD: replaceChildren restarts CSS animations
turbo_stream.replace(element); // Animation at 80% resets to 0%

// GOOD: Use morph or check animation state
if (element.getAnimations().length > 0) {
  await Promise.all(element.getAnimations().map(a => a.finished));
}
turbo_stream.replace(element);
```

---

## React Hooks Race Conditions

### useEffect Cleanup Ordering

useEffect cleanup runs BOTH before the next effect execution AND on component unmount.

```jsx
// BAD: Stale closure — async result applied after dependency changed
useEffect(() => {
  fetchData(userId).then(setData); // userId may have changed by now
}, [userId]);

// GOOD: Cleanup with abort + stale guard
useEffect(() => {
  let stale = false;
  const controller = new AbortController();
  fetchData(userId, { signal: controller.signal })
    .then(data => { if (!stale) setData(data); })
    .catch(e => { if (e.name !== 'AbortError') throw e; });
  return () => {
    stale = true;
    controller.abort();
  };
}, [userId]);
```

### Concurrent Mode Interleaving

```jsx
// BAD: Assumes sequential state updates
function Counter() {
  const [count, setCount] = useState(0);
  const increment = () => {
    setCount(count + 1); // Stale if called during transition
  };

  // GOOD: Functional update
  const increment = () => {
    setCount(prev => prev + 1); // Always uses latest
  };
}
```

---

## Vue Composition API Race Conditions

### watch vs watchEffect

```javascript
// watch: lazy — callback does NOT fire on initial setup
watch(source, (newVal) => { /* runs on change only */ });

// watchEffect: eager — callback fires immediately AND on change
watchEffect(() => { /* runs now + on every dependency change */ });

// Wrong choice: using watch when you need initial value handling
// Result: missed first value, UI shows stale/empty state until first change
```

### onUnmounted Timing

```javascript
// BAD: DOM already removed when onUnmounted fires
onUnmounted(() => {
  const el = document.querySelector('.my-element'); // null!
  el.removeEventListener('click', handler);
});

// GOOD: Track references during setup
const elRef = ref(null);
onMounted(() => {
  elRef.value?.addEventListener('click', handler);
});
onBeforeUnmount(() => {
  elRef.value?.removeEventListener('click', handler);
});
```

---

## WebSocket/SSE Message Ordering

### Out-of-Order Messages
WebSocket messages can arrive out of order during reconnection. Server sends [A, B, C], client receives [A, C, B] after network blip.

### Solutions
- **Sequence numbers**: Reject or reorder messages if sequence is non-monotonic
- **Last-event-id**: SSE reconnection header for server to resume from correct point
- **Snapshot + delta**: Periodic full state prevents drift accumulation from missed/reordered deltas

### Reconnection Race

```javascript
// BAD: Reconnect without clearing stale state
ws.onclose = () => {
  setTimeout(() => { ws = new WebSocket(url); }, 1000);
};

// GOOD: Clear state and re-sync on reconnect
ws.onclose = () => {
  clearLocalState();
  setTimeout(() => {
    ws = new WebSocket(url);
    ws.onopen = () => requestFullSync();
  }, 1000);
};
```

---

## CSS Animation Race Conditions

### DOM Replacement During Animation
Turbo/React replaceChildren restarts CSS animations from frame 0. If animation is at 80%, replacement resets to 0% — visual glitch.

### Solutions
- Use CSS `animation-fill-mode: forwards` + check `animationend` before replacement
- FLIP technique: capture initial state, apply change, animate from captured to new
- `getAnimations()` API: check if animations are running before DOM mutation

---

## Timer Cancellation Patterns

### Every setTimeout/setInterval MUST have a cleanup path

```javascript
// BAD: No cleanup reference
connect() { setInterval(this.poll, 5000) }

// GOOD: Paired setup/teardown
connect() { this.pollTimer = setInterval(this.poll, 5000) }
disconnect() { clearInterval(this.pollTimer) }
```

### requestAnimationFrame Chains

```javascript
// GOOD: Cancelable animation loop
connect() {
  const loop = () => { this.update(); this.rafId = requestAnimationFrame(loop); };
  this.rafId = requestAnimationFrame(loop);
}
disconnect() { cancelAnimationFrame(this.rafId); }
```

### Detection: Uncancelled Timers
- setTimeout/setInterval without corresponding clear in cleanup/unmount/disconnect
- requestAnimationFrame without cancelAnimationFrame
- addEventListener without removeEventListener in cleanup

---

## State Machine Patterns

### Boolean Flag Explosion

```typescript
// BAD: 3 booleans = 8 possible states, most invalid
const [isLoading, setIsLoading] = useState(false);
const [hasError, setIsError] = useState(false);
const [isComplete, setIsComplete] = useState(false);
// Can accidentally be loading AND error AND complete simultaneously!

// GOOD: State machine — 4 valid states only
type State = 'idle' | 'loading' | 'error' | 'complete';
const [state, setState] = useState<State>('idle');
```

### Symbol-Based State (Advanced)

```javascript
// Prevents string comparison bugs and accidental state creation
const STATES = Object.freeze({
  idle: Symbol('idle'),
  loading: Symbol('loading'),
  error: Symbol('error'),
  complete: Symbol('complete'),
});
```
