//// `scribbler_test` — the gleeunit entry point for the whole test suite.
////
//// `gleam test` runs `main/0` of the module named after the package (`scribbler`), and
//// `gleeunit.main()` is what turns that single entry into a full test run: it auto-discovers
//// **every** function whose name ends in `_test` across every module under `test/` and runs
//// it. Without this file `gleam test` discovers nothing at all — no test module is reachable,
//// and the suite silently reports success on zero tests.
////
//// Nothing else belongs here. Actual tests live in modules under `test/scribbler/`, mirroring
//// the `src/scribbler/` layout; run one in isolation with `gleam test -- <module>`.

import gleeunit

/// Runs the entire discovered test suite.
///
/// Takes no parameters. Returns `Nil` once every discovered `*_test` function has run;
/// `gleeunit.main()` reports failures to stdout and sets a non-zero exit status itself, so a
/// return here does **not** imply the suite passed — read the process exit code for that.
pub fn main() -> Nil {
  gleeunit.main()
}
