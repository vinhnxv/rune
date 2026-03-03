# Async & Concurrency Patterns Reference

Multi-language code examples for Tide Watcher analysis. Each section shows BAD (anti-pattern) and GOOD (correct) implementations across Python, Rust, TypeScript, and Go.

---

## 1. Sequential Await / Waterfall Pattern

Independent async operations executed sequentially waste time.

**Python**
```python
# BAD: Waterfall — 3 round-trips sequentially (~3 seconds)
async def get_dashboard(user_id: UUID) -> Dashboard:
    user = await user_repo.get(user_id)
    campaigns = await campaign_repo.list_by_user(user_id)
    analytics = await analytics.get_summary(user_id)
    return Dashboard(user=user, campaigns=campaigns, analytics=analytics)

# GOOD: Concurrent — 1 round-trip time (~1 second)
async def get_dashboard(user_id: UUID) -> Dashboard:
    user, campaigns, analytics = await asyncio.gather(
        user_repo.get(user_id),
        campaign_repo.list_by_user(user_id),
        analytics.get_summary(user_id),
    )
    return Dashboard(user=user, campaigns=campaigns, analytics=analytics)
```

**Rust**
```rust
// BAD: Sequential futures
let user = get_user(user_id).await?;
let campaigns = get_campaigns(user_id).await?;
let analytics = get_analytics(user_id).await?;

// GOOD: Concurrent with tokio::join!
let (user, campaigns, analytics) = tokio::try_join!(
    get_user(user_id),
    get_campaigns(user_id),
    get_analytics(user_id),
)?;
```

**TypeScript**
```typescript
// BAD: Sequential awaits
const user = await getUser(userId);
const campaigns = await getCampaigns(userId);
const analytics = await getAnalytics(userId);

// GOOD: Concurrent with Promise.all
const [user, campaigns, analytics] = await Promise.all([
  getUser(userId),
  getCampaigns(userId),
  getAnalytics(userId),
]);
```

**Go**
```go
// BAD: Sequential
user, err := getUser(ctx, userID)
campaigns, err := getCampaigns(ctx, userID)

// GOOD: Concurrent with errgroup
g, ctx := errgroup.WithContext(ctx)
var user *User
var campaigns []*Campaign
g.Go(func() error { var err error; user, err = getUser(ctx, userID); return err })
g.Go(func() error { var err error; campaigns, err = getCampaigns(ctx, userID); return err })
if err := g.Wait(); err != nil { return err }
```

**Detection heuristic**: 3+ consecutive `await` / `.await` statements in the same function, where the results of earlier awaits are NOT used as arguments to later ones.

---

## 2. Unbounded Concurrency

Spawning tasks/goroutines without limits can overwhelm databases, APIs, and memory.

**Python**
```python
# BAD: Unbounded — 10K concurrent database connections!
async def process_all(user_ids: list[UUID]) -> list[Result]:
    tasks = [process_user(uid) for uid in user_ids]
    return await asyncio.gather(*tasks)

# GOOD: Bounded with semaphore
async def process_all(user_ids: list[UUID]) -> list[Result]:
    semaphore = asyncio.Semaphore(50)
    async def bounded(uid: UUID) -> Result:
        async with semaphore:
            return await process_user(uid)
    return await asyncio.gather(*[bounded(uid) for uid in user_ids])
```

**Rust**
```rust
// BAD: Unbounded task spawning
for item in items {
    tokio::spawn(process_item(item));  // No limit!
}

// GOOD: Bounded with tokio::sync::Semaphore
let semaphore = Arc::new(Semaphore::new(50));
for item in items {
    let permit = semaphore.clone().acquire_owned().await?;
    tokio::spawn(async move {
        let result = process_item(item).await;
        drop(permit);
        result
    });
}
```

**TypeScript**
```typescript
// BAD: Unbounded Promise.all
const results = await Promise.all(items.map(item => processItem(item)));

// GOOD: p-limit or manual batching
import pLimit from 'p-limit';
const limit = pLimit(50);
const results = await Promise.all(
  items.map(item => limit(() => processItem(item)))
);
```

**Go**
```go
// BAD: Unbounded goroutines
for _, item := range items {
    go processItem(ctx, item)  // No limit!
}

// GOOD: Worker pool pattern
sem := make(chan struct{}, 50)
for _, item := range items {
    sem <- struct{}{}
    go func(item Item) {
        defer func() { <-sem }()
        processItem(ctx, item)
    }(item)
}
```

**Detection patterns:**
```
# Python: gather without semaphore
rg "asyncio\.gather\(" --type py -A 5 | rg -v "Semaphore"

# Rust: spawn in loop without semaphore
rg "tokio::spawn" --type rust -B 3 | rg "for .* in"

# TypeScript: Promise.all with map
rg "Promise\.all\(.*\.map" --type ts

# Go: goroutine in loop
rg "go func\(" --type go -B 2 | rg "for .* range"
```

---

## 3. Structured Concurrency

Tasks must be bound to a scope — when the parent completes or fails, all children are cleaned up.

**Python (3.11+)**
```python
# BAD: Unstructured — if task1 raises, task2/task3 keep running
task1 = asyncio.create_task(sync_users())
task2 = asyncio.create_task(sync_campaigns())
task3 = asyncio.create_task(sync_analytics())
await task1  # If this raises, task2/task3 are orphaned!
await task2
await task3

# GOOD: TaskGroup — all cancel on first error
async with asyncio.TaskGroup() as tg:
    tg.create_task(sync_users())
    tg.create_task(sync_campaigns())
    tg.create_task(sync_analytics())
# All completed or all cancelled
```

**Rust**
```rust
// BAD: Spawned tasks outlive their parent scope
tokio::spawn(background_job());  // Who owns this?
return response;  // Parent returns, task keeps running

// GOOD: JoinSet for structured concurrency
let mut set = JoinSet::new();
set.spawn(background_job_1());
set.spawn(background_job_2());
while let Some(result) = set.join_next().await {
    result??;
}
```

**TypeScript**
```typescript
// BAD: Fire-and-forget promises
processInBackground(data);  // No await — errors are lost!
return response;

// GOOD: Track all promises
const pending: Promise<void>[] = [];
pending.push(processInBackground(data));
// ... later
await Promise.allSettled(pending);
```

---

## 4. Cancellation Handling

Async operations must handle cancellation gracefully — cleanup resources, stop work, propagate signals.

**Python**
```python
# BAD: Swallowing CancelledError
try:
    result = await long_operation()
except Exception:  # Catches CancelledError too!
    logger.error("Failed")
    return None

# GOOD: Re-raise cancellation
try:
    result = await long_operation()
except asyncio.CancelledError:
    logger.info("Cancelled — cleaning up")
    await cleanup()
    raise  # MUST re-raise!
except Exception:
    logger.error("Failed")
    return None
```

**Python — SystemExit and KeyboardInterrupt:**
```python
# BAD: Catches everything including system signals
except Exception:  # In Python 3.11+, CancelledError is BaseException
    pass

# GOOD: Explicit exception hierarchy
except (KeyboardInterrupt, SystemExit, asyncio.CancelledError):
    raise  # Never swallow these
except Exception:
    handle_error()
```

**TypeScript (AbortController)**
```typescript
// BAD: No cancellation support
async function fetchData(url: string): Promise<Data> {
  const response = await fetch(url);
  return response.json();
}

// GOOD: AbortController support
async function fetchData(url: string, signal?: AbortSignal): Promise<Data> {
  const response = await fetch(url, { signal });
  return response.json();
}

// Usage with timeout
const controller = new AbortController();
const timeout = setTimeout(() => controller.abort(), 5000);
try {
  const data = await fetchData(url, controller.signal);
} finally {
  clearTimeout(timeout);
}
```

**Rust**
```rust
// BAD: No cancellation check in long-running loop
async fn process_batch(items: Vec<Item>) -> Result<()> {
    for item in items {
        process_item(item).await?;  // No way to cancel mid-batch
    }
    Ok(())
}

// GOOD: Check cancellation token
async fn process_batch(items: Vec<Item>, cancel: CancellationToken) -> Result<()> {
    for item in items {
        tokio::select! {
            _ = cancel.cancelled() => return Err(anyhow!("Cancelled")),
            result = process_item(item) => result?,
        }
    }
    Ok(())
}
```

**Go**
```go
// BAD: Ignoring context cancellation
func processItems(ctx context.Context, items []Item) error {
    for _, item := range items {
        processItem(item)  // Ignores ctx!
    }
    return nil
}

// GOOD: Check context
func processItems(ctx context.Context, items []Item) error {
    for _, item := range items {
        select {
        case <-ctx.Done():
            return ctx.Err()
        default:
            if err := processItem(ctx, item); err != nil {
                return err
            }
        }
    }
    return nil
}
```

---

## 5. Race Conditions

**TOCTOU (Time-of-Check-Time-of-Use)**
```python
# BAD: Check-then-act without atomicity
if not await repo.exists(user_id):
    await repo.create(User(id=user_id))  # Race: another request creates between check and create!

# GOOD: Atomic upsert
await repo.upsert(User(id=user_id))

# Or: Use database constraints + handle conflict
try:
    await repo.create(User(id=user_id))
except IntegrityError:
    pass  # Already exists
```

**Shared mutable state**
```python
# BAD: Shared dict without lock in async context
cache = {}
async def get_or_fetch(key: str) -> Value:
    if key not in cache:  # Race: two coroutines check simultaneously
        cache[key] = await fetch(key)  # Duplicate fetches!
    return cache[key]

# GOOD: asyncio.Lock
lock = asyncio.Lock()
async def get_or_fetch(key: str) -> Value:
    async with lock:
        if key not in cache:
            cache[key] = await fetch(key)
        return cache[key]
```

```rust
// BAD: Arc<Mutex> with await inside lock
let data = mutex.lock().await;
let result = fetch_external(data.id).await;  // Holding lock across await!
drop(data);

// GOOD: Minimize lock scope
let id = {
    let data = mutex.lock().await;
    data.id  // Copy what you need, release lock
};
let result = fetch_external(id).await;  // No lock held
```

```typescript
// BAD: Race in React state update
const [count, setCount] = useState(0);
const increment = async () => {
  const current = count;  // Stale closure!
  await someAsyncWork();
  setCount(current + 1);  // May overwrite concurrent update
};

// GOOD: Functional update
const increment = async () => {
  await someAsyncWork();
  setCount(prev => prev + 1);  // Always reads latest
};
```

---

## 6. Timer & Resource Cleanup

Timers, event listeners, and subscriptions must be cleaned up to prevent leaks.

**Python**
```python
# BAD: Timer not cancelled on shutdown
class Scheduler:
    def start(self):
        self._task = asyncio.create_task(self._run_loop())

    async def _run_loop(self):
        while True:
            await self.do_work()
            await asyncio.sleep(60)
    # No stop() method — task runs forever!

# GOOD: Cancellable with cleanup
class Scheduler:
    def start(self):
        self._task = asyncio.create_task(self._run_loop())

    async def stop(self):
        self._task.cancel()
        try:
            await self._task
        except asyncio.CancelledError:
            pass

    async def _run_loop(self):
        while True:
            await self.do_work()
            await asyncio.sleep(60)
```

**TypeScript (Frontend)**
```typescript
// BAD: setInterval without cleanup
useEffect(() => {
  setInterval(() => fetchData(), 5000);
  // Memory leak! Interval survives unmount
}, []);

// GOOD: Cleanup on unmount
useEffect(() => {
  const interval = setInterval(() => fetchData(), 5000);
  return () => clearInterval(interval);
}, []);
```

```typescript
// BAD: Event listener without removal
element.addEventListener('scroll', handleScroll);
// Never removed!

// GOOD: AbortController for event listeners
const controller = new AbortController();
element.addEventListener('scroll', handleScroll, { signal: controller.signal });
// Cleanup: controller.abort() removes all listeners
```

**Rust**
```rust
// BAD: Spawned task never joined or cancelled
tokio::spawn(async move {
    loop {
        do_periodic_work().await;
        tokio::time::sleep(Duration::from_secs(60)).await;
    }
});
// Task leaked — runs until process exits

// GOOD: Store JoinHandle and abort on drop
struct Scheduler {
    handle: JoinHandle<()>,
}
impl Drop for Scheduler {
    fn drop(&mut self) {
        self.handle.abort();
    }
}
```

---

## 7. Blocking Calls in Async Context

Synchronous blocking calls in async code starve the event loop / runtime thread pool.

**Python**
```python
# BAD: Blocking calls in async function
async def process():
    time.sleep(5)           # Blocks event loop!
    data = requests.get(url)  # Blocks event loop!
    result = json.loads(open("large.json").read())  # Blocks!

# GOOD: Use async equivalents or run_in_executor
async def process():
    await asyncio.sleep(5)
    async with httpx.AsyncClient() as client:
        data = await client.get(url)
    result = await asyncio.to_thread(lambda: json.loads(open("large.json").read()))
```

**Rust**
```rust
// BAD: Blocking in async context (holds tokio worker thread)
async fn handler() -> Response {
    let data = std::fs::read_to_string("large.json")?;  // Blocks!
    let hash = expensive_hash(data);  // CPU-bound, blocks!

    // GOOD: Use tokio's async I/O and spawn_blocking
    let data = tokio::fs::read_to_string("large.json").await?;
    let hash = tokio::task::spawn_blocking(move || expensive_hash(data)).await?;
}
```

**Detection patterns:**
```
# Python: Blocking calls in async functions
rg "async def" -A 30 --type py | rg "time\.sleep|requests\.(get|post)|open\("

# Rust: std::fs in async context
rg "std::fs::" --type rust

# TypeScript: fs.readFileSync in async
rg "readFileSync|writeFileSync" --type ts
```

---

## 8. Frontend Timing & DOM Lifecycle

Specific patterns for frontend async code that interacts with DOM and rendering.

**Animation race conditions**
```typescript
// BAD: Starting new animation without cancelling previous
function animateElement(el: HTMLElement, target: number) {
  requestAnimationFrame(function step() {
    el.style.left = `${current}px`;
    if (current < target) requestAnimationFrame(step);
  });
}
// If called twice quickly, two animation loops fight!

// GOOD: Cancel previous animation
let animationId: number | null = null;
function animateElement(el: HTMLElement, target: number) {
  if (animationId) cancelAnimationFrame(animationId);
  animationId = requestAnimationFrame(function step() {
    el.style.left = `${current}px`;
    if (current < target) {
      animationId = requestAnimationFrame(step);
    } else {
      animationId = null;
    }
  });
}
```

**Stale async response**
```typescript
// BAD: Race condition on search input
async function onSearch(query: string) {
  const results = await fetchResults(query);
  setResults(results);  // If user typed "ab" then "abc", "ab" results may arrive AFTER "abc"
}

// GOOD: Abort previous request
let controller: AbortController | null = null;
async function onSearch(query: string) {
  controller?.abort();
  controller = new AbortController();
  try {
    const results = await fetchResults(query, { signal: controller.signal });
    setResults(results);
  } catch (e) {
    if (e instanceof DOMException && e.name === 'AbortError') return;
    throw e;
  }
}
```

**State machine over booleans**
```typescript
// BAD: Boolean flags for mutually exclusive states
const [isLoading, setIsLoading] = useState(false);
const [isError, setIsError] = useState(false);
const [isSuccess, setIsSuccess] = useState(false);
// Can accidentally be loading AND error simultaneously!

// GOOD: State machine
type State = 'idle' | 'loading' | 'success' | 'error';
const [state, setState] = useState<State>('idle');
// Mutually exclusive by construction
```

---

## 9. WebSocket/SSE Reconnection Races

Messages can arrive out of order during reconnection. Clear local state and re-sync.

**TypeScript**
```typescript
// BAD: Reconnect without state reset — stale data persists
ws.onclose = () => {
  setTimeout(() => { ws = new WebSocket(url); }, 1000);
};

// GOOD: Clear state and request full sync on reconnect
ws.onclose = () => {
  clearLocalState();
  setTimeout(() => {
    ws = new WebSocket(url);
    ws.onopen = () => ws.send(JSON.stringify({ type: 'sync' }));
  }, 1000);
};
```

**Detection**: WebSocket `onclose`/`onerror` handlers that reconnect without clearing cached state or requesting full re-sync.

For detailed frontend-specific patterns (Hotwire, React, Vue), see [frontend-race-patterns.md](frontend-race-patterns.md).
