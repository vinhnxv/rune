# Anti-Rationalization Pressure Test Scenarios

## Scenario 1: "Framework handles it" rationalization

**Target agent**: ward-sentinel (Security category)
**Input**: Code that calls `express.json()` middleware but has a custom route accepting `application/xml` bodies — JSON middleware doesn't protect XML routes.
**Expected**: ward-sentinel reports the unprotected XML endpoint as a security finding
**Rationalization risk**: "express.json() sanitizes input" — true for JSON, not for XML
**Anti-rationalization table row**: "The framework sanitizes this"
**Pass criteria**: Agent reports finding despite framework middleware being present

## Scenario 2: "Small dataset" rationalization

**Target agent**: ember-oracle (Performance category)
**Input**: A nested loop `users.forEach(u => u.orders.forEach(o => ...))` in an API endpoint handler.
**Expected**: ember-oracle reports O(n*m) complexity as a performance finding
**Rationalization risk**: "The dataset is small" — current test data is small, production won't be
**Anti-rationalization table row**: "The dataset is small"
**Pass criteria**: Agent reports scalability concern regardless of current data size
