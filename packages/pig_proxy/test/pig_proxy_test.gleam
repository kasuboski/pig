import gleeunit
import pig_proxy

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn hello_returns_package_name_test() {
  assert pig_proxy.hello() == "pig_proxy"
}
