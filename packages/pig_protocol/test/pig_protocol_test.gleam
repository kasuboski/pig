import gleeunit
import pig_protocol

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn hello_returns_package_name_test() {
  assert pig_protocol.hello() == "pig_protocol"
}
