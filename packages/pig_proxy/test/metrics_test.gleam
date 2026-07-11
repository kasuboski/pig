import gleam/dict
import gleeunit
import pig_proxy/metrics

pub fn main() -> Nil {
  gleeunit.main()
}

// ── percentile ──────────────────────────────────────────────────

pub fn percentile_empty_list_returns_zero_test() {
  assert 0 == metrics.percentile([], 50)
}

pub fn percentile_single_element_test() {
  assert 42 == metrics.percentile([42], 50)
  assert 42 == metrics.percentile([42], 95)
  assert 42 == metrics.percentile([42], 99)
}

pub fn percentile_p50_of_five_elements_test() {
  // sorted: [1, 2, 3, 4, 5], p=50, index = 50*5/100 = 2 → element at index 2 = 3
  assert 3 == metrics.percentile([1, 2, 3, 4, 5], 50)
}

pub fn percentile_p95_of_five_elements_test() {
  // sorted: [1, 2, 3, 4, 5], p=95, index = 95*5/100 = 4 → element at index 4 = 5
  assert 5 == metrics.percentile([1, 2, 3, 4, 5], 95)
}

pub fn percentile_p99_of_five_elements_test() {
  // sorted: [1, 2, 3, 4, 5], p=99, index = 99*5/100 = 4 → element at index 4 = 5
  assert 5 == metrics.percentile([1, 2, 3, 4, 5], 99)
}

pub fn percentile_p0_test() {
  // p=0, index = 0 → first element
  assert 10 == metrics.percentile([10, 20, 30], 0)
}

pub fn percentile_p100_clamps_to_last_test() {
  // p=100, index = 100*3/100 = 3, clamped to 2 → last element = 30
  assert 30 == metrics.percentile([10, 20, 30], 100)
}

pub fn percentile_unsorted_input_sorts_first_test() {
  // input [30, 10, 20], sorted [10, 20, 30], p=50, index = 1 → 20
  assert 20 == metrics.percentile([30, 10, 20], 50)
}

pub fn percentile_p50_of_ten_elements_test() {
  // sorted: [10, 20, 30, 40, 50, 60, 70, 80, 90, 100]
  // p=50, index = 50*10/100 = 5 → element at index 5 = 60
  assert 60 == metrics.percentile([10, 20, 30, 40, 50, 60, 70, 80, 90, 100], 50)
}

pub fn percentile_p95_of_ten_elements_test() {
  // p=95, index = 95*10/100 = 9 → element at index 9 = 100
  assert 100 == metrics.percentile([10, 20, 30, 40, 50, 60, 70, 80, 90, 100], 95)
}

// ── empty_snapshot ──────────────────────────────────────────────

pub fn empty_snapshot_has_no_models_test() {
  let snap = metrics.empty_snapshot()
  assert 0 == dict.size(snap.models)
}
