---
name: gleam-testing
description: Best practices for writing Gleam tests with gleeunit. Use when writing or reviewing Gleam test files, fixing silently-passing tests, or choosing between should functions and let assert patterns.
---

# Gleam Testing Best Practices

## Critical: gleeunit Only Fails on Panics

Gleeunit tests pass if the function completes without panicking. **Returning `False` does NOT fail the test.** This is the #1 source of silently-passing bogus tests.

```gleam
// ❌ WRONG — returns False, test silently passes
pub fn my_test() {
  value == "expected"
}

// ✅ CORRECT — panics on mismatch
pub fn my_test() {
  should.equal(value, "expected")
}
```

The same applies to boolean expressions as the last line of any test. A bare `count == 4` evaluates and discards. Use assertions.

## Assertion Strategies

### `should.equal` — equality checks
```gleam
import gleeunit/should

should.equal(value, "expected")
should.equal(count, 4)
should.equal(keys, ["alpha", "beta"])
```
Order convention: `should.equal(actual, expected)`.

### `should.be_true` / `should.be_false` — boolean conditions
```gleam
should.be_true(mode == "wal" || mode == "memory")
should.be_true(string.contains(output, "hello"))
should.be_false(string.contains(output, "config"))
```

### `should.be_ok` / `should.be_error` — Result unwrapping
```gleam
let value = should.be_ok(result)    // unwraps Ok value
let error = should.be_error(result)  // unwraps Error value
```

### `should.be_some` / `should.be_none` — Option unwrapping
```gleam
let value = should.be_some(option_value)
should.be_none(maybe_thing)
```

### `let assert` — pattern matching as assertion
```gleam
let assert Ok(Nil) = some_operation()
let assert Error(NotFound(key: "foo")) = lookup("foo")
let assert [item] = list_with_one_item()
```
Use when you want to both assert a shape AND bind variables from it.

## `should` vs `let assert` — When to Use Which

| Situation | Use |
|---|---|
| Check exact equality | `should.equal(actual, expected)` |
| Compound boolean (OR, AND) | `should.be_true(a \|\| b)` |
| Assert Result is Ok AND use the value | `let assert Ok(val) = result` |
| Assert Result is Ok, don't need value | `should.be_ok(result)` or `let assert Ok(Nil) = ...` |
| Assert specific error variant | `let assert Error(NotFound(key: k)) = ...` |
| Assert string/list contains | `should.be_true(string.contains(s, "x"))` |

## Common Pitfalls

### Bare boolean as last expression
```gleam
// ❌ Silent pass on False
pub fn test_something() {
  let assert Ok(value) = compute()
  value == "expected"  // <-- returned, not asserted
}

// ✅ Fix
pub fn test_something() {
  let assert Ok(value) = compute()
  should.equal(value, "expected")
}
```

### `should.be_ok` without checking specific value
```gleam
// Weak — only checks it's Ok, not the value
should.be_ok(result)

// Stronger — checks the exact value
let assert Ok("expected") = result
should.equal(should.be_ok(result), "expected")
```

### Piping into should
```gleam
list.length(items)
|> should.equal(3)

string.contains(output, "hello")
|> should.be_true()
```

## Test File Structure

```gleam
import gleeunit
import gleeunit/should

pub fn main() -> Nil {
  gleeunit.main()
}

fn with_db(f: fn(sqlight.Connection) -> a) -> a {
  let assert Ok(conn) = sqlight.open(":memory:")
  let assert Ok(Nil) = schema.init(conn)
  let result = f(conn)
  let assert Ok(Nil) = sqlight.close(conn)
  result
}

pub fn my_feature_test() {
  with_db(fn(conn) {
    let assert Ok(Nil) = write(conn, "/file.txt", "hello")
    let assert Ok(content) = read(conn, "/file.txt")
    should.equal(content, "hello")
  })
}
```

## `gleeunit/should` Function Reference

| Function | Signature | Purpose |
|---|---|---|
| `equal` | `(t, t) -> Nil` | Assert equality |
| `not_equal` | `(t, t) -> Nil` | Assert inequality |
| `be_ok` | `Result(a, e) -> a` | Assert Ok, unwrap value |
| `be_error` | `Result(a, e) -> e` | Assert Error, unwrap error |
| `be_some` | `Option(a) -> a` | Assert Some, unwrap value |
| `be_none` | `Option(a) -> Nil` | Assert None |
| `be_true` | `Bool -> Nil` | Assert True |
| `be_false` | `Bool -> Nil` | Assert False |
| `fail` | `() -> Nil` | Unconditional fail |
