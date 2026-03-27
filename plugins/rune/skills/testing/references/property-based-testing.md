# Property-Based Testing Reference

Reference document for trial-forger's PBT pattern detection and arc Phase 7.7 Tier 1.5.

**Concept**: Instead of testing with specific examples (`add(2,3) === 5`), PBT tests invariants with randomly generated inputs (`for all x, y: add(x,y) === add(y,x)`). The framework generates hundreds of inputs, shrinking failures to minimal reproducible cases.

## Library Selection by Stack

| Stack | Library | Install | Import |
|-------|---------|---------|--------|
| TypeScript/JavaScript | fast-check | `npm i -D fast-check` | `import * as fc from 'fast-check'` |
| Python | hypothesis | `pip install hypothesis` | `from hypothesis import given, strategies as st` |
| Rust | proptest | `proptest = "1.0"` in Cargo.toml | `use proptest::prelude::*;` |
| Go | rapid | `go get pgregory.net/rapid` | `import "pgregory.net/rapid"` |

### Library Detection

```javascript
// Check for PBT library presence
function detectPBTLibrary(changedFiles) {
  // JavaScript/TypeScript
  const pkgJson = tryRead("package.json")
  if (pkgJson && (pkgJson.includes('"fast-check"'))) return { lib: "fast-check", stack: "typescript" }

  // Python
  const requirements = tryRead("requirements.txt") ?? tryRead("requirements-dev.txt") ?? ""
  const pyproject = tryRead("pyproject.toml") ?? ""
  if (requirements.includes("hypothesis") || pyproject.includes("hypothesis")) return { lib: "hypothesis", stack: "python" }

  // Rust
  const cargo = tryRead("Cargo.toml") ?? ""
  if (cargo.includes("proptest")) return { lib: "proptest", stack: "rust" }

  // Go
  const goMod = tryRead("go.mod") ?? ""
  if (goMod.includes("pgregory.net/rapid")) return { lib: "rapid", stack: "go" }

  return null  // No PBT library installed
}
```

## Code Templates

### TypeScript/JavaScript (fast-check)

```typescript
import * as fc from 'fast-check';

// Roundtrip property: encode/decode
test('encode/decode roundtrip', () => {
  fc.assert(fc.property(fc.string(), (input) => {
    expect(decode(encode(input))).toEqual(input);
  }));
});

// Idempotency property
test('normalize is idempotent', () => {
  fc.assert(fc.property(fc.string(), (input) => {
    expect(normalize(normalize(input))).toEqual(normalize(input));
  }));
});

// Validator property: valid inputs accepted
test('valid emails are accepted', () => {
  fc.assert(fc.property(
    fc.emailAddress(),
    (email) => { expect(validateEmail(email)).toBe(true); }
  ));
});

// Sorting property: idempotent + length preserved
test('sort is stable and length-preserving', () => {
  fc.assert(fc.property(
    fc.array(fc.integer()),
    (arr) => {
      const sorted = customSort(arr);
      expect(sorted.length).toBe(arr.length);
      expect(customSort(sorted)).toEqual(sorted);
    }
  ));
});

// Commutativity property
test('add is commutative', () => {
  fc.assert(fc.property(
    fc.integer(), fc.integer(),
    (a, b) => { expect(add(a, b)).toBe(add(b, a)); }
  ));
});
```

#### Useful fast-check Arbitraries

| Arbitrary | Generates | Use For |
|-----------|-----------|---------|
| `fc.string()` | Random strings | Text processing, encoding |
| `fc.integer()` | Random integers | Math operations, indices |
| `fc.float()` | Random floats | Numeric computation |
| `fc.emailAddress()` | Valid email addresses | Email validation |
| `fc.webUrl()` | Valid URLs | URL parsing |
| `fc.json()` | Random JSON values | Serialization |
| `fc.array(fc.integer())` | Integer arrays | Sorting, filtering |
| `fc.record({...})` | Object with shape | Data structure operations |
| `fc.oneof(...)` | Union of generators | Variant testing |
| `fc.tuple(a, b)` | Paired values | Binary operations |

### Python (hypothesis)

```python
from hypothesis import given, strategies as st, settings

# Roundtrip property
@given(st.text())
def test_json_roundtrip(data):
    assert json.loads(json.dumps(data)) == data

# Validator property
@given(st.emails())
def test_valid_email_accepted(email):
    assert validate_email(email) is True

# Idempotency property
@given(st.text())
def test_normalize_idempotent(text):
    assert normalize(normalize(text)) == normalize(text)

# Sorting property
@given(st.lists(st.integers()))
def test_sort_preserves_length(lst):
    sorted_lst = custom_sort(lst)
    assert len(sorted_lst) == len(lst)
    assert custom_sort(sorted_lst) == sorted_lst

# Data structure invariant
@given(st.lists(st.tuples(st.text(), st.integers())))
def test_cache_invariant(operations):
    cache = LRUCache(capacity=10)
    for key, value in operations:
        cache.put(key, value)
        assert cache.size() <= cache.capacity

# Custom settings for slow properties
@settings(max_examples=50, deadline=500)
@given(st.binary())
def test_compression_roundtrip(data):
    assert decompress(compress(data)) == data
```

#### Useful hypothesis Strategies

| Strategy | Generates | Use For |
|----------|-----------|---------|
| `st.text()` | Unicode strings | String processing |
| `st.integers()` | Arbitrary integers | Numeric operations |
| `st.floats()` | Floats (incl. NaN, inf) | Numeric edge cases |
| `st.emails()` | Valid email addresses | Email validation |
| `st.binary()` | Byte sequences | Binary/encoding |
| `st.lists(st.integers())` | Integer lists | Collection operations |
| `st.dictionaries(st.text(), st.integers())` | Dicts | Mapping operations |
| `st.builds(MyClass, ...)` | Class instances | OOP testing |
| `st.one_of(st.text(), st.none())` | Optional values | Null handling |

### Rust (proptest)

```rust
use proptest::prelude::*;

proptest! {
    // Roundtrip property
    #[test]
    fn encode_decode_roundtrip(input in any::<String>()) {
        let encoded = encode(&input);
        let decoded = decode(&encoded).unwrap();
        prop_assert_eq!(decoded, input);
    }

    // Idempotency property
    #[test]
    fn normalize_idempotent(input in "\\PC*") {
        let once = normalize(&input);
        let twice = normalize(&once);
        prop_assert_eq!(once, twice);
    }

    // Sorting property
    #[test]
    fn sort_preserves_length(vec in prop::collection::vec(any::<i32>(), 0..100)) {
        let sorted = custom_sort(&vec);
        prop_assert_eq!(sorted.len(), vec.len());
    }
}
```

### Go (rapid)

```go
import (
    "testing"
    "pgregory.net/rapid"
)

// Roundtrip property
func TestEncodeDecodeRoundtrip(t *testing.T) {
    rapid.Check(t, func(t *rapid.T) {
        input := rapid.String().Draw(t, "input")
        encoded := Encode(input)
        decoded, err := Decode(encoded)
        if err != nil {
            t.Fatalf("decode failed: %v", err)
        }
        if decoded != input {
            t.Fatalf("roundtrip failed: got %q, want %q", decoded, input)
        }
    })
}

// Idempotency property
func TestNormalizeIdempotent(t *testing.T) {
    rapid.Check(t, func(t *rapid.T) {
        input := rapid.String().Draw(t, "input")
        once := Normalize(input)
        twice := Normalize(once)
        if once != twice {
            t.Fatalf("not idempotent: normalize(%q)=%q, normalize(%q)=%q",
                input, once, once, twice)
        }
    })
}
```

## Common Properties to Test

| Property | What it Proves | When to Apply |
|----------|---------------|---------------|
| **Roundtrip** (`decode(encode(x)) === x`) | Lossless encoding | Serializers, encoders, parsers |
| **Idempotency** (`f(f(x)) === f(x)`) | Stability under re-application | Normalizers, formatters, dedupers |
| **Commutativity** (`f(a,b) === f(b,a)`) | Order independence | Math ops, merge functions |
| **Associativity** (`f(f(a,b),c) === f(a,f(b,c))`) | Grouping independence | Concatenation, aggregation |
| **Length preservation** (`len(f(x)) === len(x)`) | No data loss/gain | Mapping, transformation |
| **Monotonicity** (`a <= b → f(a) <= f(b)`) | Order preservation | Scoring, ranking |
| **No-throw on valid input** (`parse(valid) !== throw`) | Robustness | Parsers, validators |
| **Invariant maintenance** (after any op sequence) | Structural integrity | Data structures, state machines |

## Arc Phase 7.7 — Tier 1.5 Integration

PBT runs as Tier 1.5 between unit tests (Tier 1) and integration tests (Tier 2).

### Discovery Protocol

```javascript
function discoverPBTTests(changedFiles) {
  const pbtLib = detectPBTLibrary(changedFiles)
  if (!pbtLib) return { skip: true, reason: "no-library" }

  // Find existing PBT test files
  const pbtPatterns = {
    "fast-check": "fc.assert|fc.property",
    "hypothesis": "@given|@settings",
    "proptest": "proptest!",
    "rapid": "rapid.Check"
  }

  const pattern = pbtPatterns[pbtLib.lib]
  const existingPBT = Grep(pattern, "**/*.test.*,**/*.spec.*,**/test_*.*")

  // Find PBT-suitable patterns in changed source files
  const sourceFiles = changedFiles.filter(f => !f.includes("test"))
  const suitablePatterns = []
  for (const file of sourceFiles) {
    const content = Read(file)
    if (hasRoundtripPattern(content)) suitablePatterns.push({ file, type: "roundtrip" })
    if (hasIdempotentPattern(content)) suitablePatterns.push({ file, type: "idempotent" })
    if (hasValidatorPattern(content)) suitablePatterns.push({ file, type: "validator" })
    if (hasParserPattern(content)) suitablePatterns.push({ file, type: "parser" })
  }

  return {
    skip: false,
    library: pbtLib,
    existingTests: existingPBT,
    suitablePatterns,
    suggestion: suitablePatterns.length > 0 && existingPBT.length === 0
      ? `PBT patterns detected but no property tests exist. Consider adding ${pbtLib.lib} tests.`
      : null
  }
}
```

### Skip Conditions

- No PBT library in project dependencies AND no PBT-suitable patterns detected → skip silently
- PBT library absent but patterns detected → skip with suggestion to install library
- PBT library present → run existing PBT tests + generate new ones for uncovered patterns

### Execution

PBT tests run with the same test runner as unit tests (vitest, pytest, cargo test, go test). No special runner needed — PBT libraries integrate natively with each language's test framework.

**Timeout**: PBT tests run with a 2x timeout multiplier vs unit tests (property generation is CPU-intensive). Configurable via `talisman.testing.tiers.pbt.timeout_multiplier` (default: 2).
