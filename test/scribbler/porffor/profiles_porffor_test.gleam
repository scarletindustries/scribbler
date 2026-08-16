//// Tests for the JS-on-BEAM posture `scribbler/porffor/host.binding()` (P7-08 §G). Asserts it is a
//// **Safe** `HostWhitelist` admitting EXACTLY the four `""` intrinsics — never `HostOpen`, and
//// otherwise byte-identical to `profiles.safe()` (the fail-closed enumeration is unperturbed, J5).
////
//// Since the carder/scribbler split the posture is scribbler's, not carder's: carder ships no
//// producer-specific profile, so `profiles.porffor()`/`js()`/`porffor_allow()` are gone and the
//// binding is rebuilt here as `Binding(..profiles.safe(), host_policy: HostWhitelist(allow()))`.

import carder/runtime/instance.{HostWhitelist, Safe, Unsafe}
import carder/runtime/profiles
import gleam/list
import gleeunit/should
import scribbler/porffor/host

/// `host.allow()` is exactly the four `#("", letter)` pairs — the closed authority surface.
pub fn porffor_allow_is_four_pairs_test() {
  host.allow()
  |> should.equal([#("", "a"), #("", "b"), #("", "c"), #("", "d")])
}

/// `host.binding()` is a **Safe** posture (mode `Safe`) whose host policy is the whitelist of the
/// four intrinsics — NOT `HostOpen`, so no unrelated capability is reachable.
pub fn porffor_is_safe_whitelist_test() {
  let binding = host.binding()
  binding.mode |> should.equal(Safe)
  binding.host_policy
  |> should.equal(
    HostWhitelist([#("", "a"), #("", "b"), #("", "c"), #("", "d")]),
  )
}

/// `host.binding()` differs from `profiles.safe()` ONLY in `host_policy` — every other field
/// (mode, tiers, caps, module names) is inherited unchanged (conformance-neutral, J6).
pub fn porffor_differs_only_in_host_policy_test() {
  let base = profiles.safe()
  let porf = host.binding()
  should.equal(porf, instance.Binding(..base, host_policy: porf.host_policy))
}

/// `host.binding()` links cleanly (it changes only `host_policy`, so it is a coherent Safe binding).
pub fn porffor_links_ok_test() {
  profiles.link(host.binding()) |> should.be_ok
}

/// **The fail-closed posture enumeration is unperturbed (J5).** Admitting Porffor's four
/// intrinsics did NOT add an Unsafe opt-out anywhere: `host.binding()` and every named Safe
/// constructor carder still ships are `mode: Safe`, and `profiles.unsafe()` / `profiles.ceiling()`
/// remain the ONLY `mode: Unsafe` constructors. So a JS guest cannot reach the aggressive
/// optimizer / open BIF+host gates by naming a profile — the whole JS-on-BEAM path stays inside
/// the Safe posture, and its only extra authority is the four whitelisted `""` intrinsics above.
///
/// This assertion moved here with the split: pre-split it guarded carder's own
/// `profiles.porffor()`/`js()`, which are gone; the posture is scribbler's now, so the enumeration
/// it must not perturb is asserted from scribbler.
pub fn unsafe_enumeration_is_unperturbed_test() {
  [
    host.binding(),
    profiles.safe(),
    profiles.safe_capped(64),
    profiles.safe_metered(1000),
    profiles.portable(),
    profiles.engine(),
  ]
  |> list.each(fn(binding) { binding.mode |> should.equal(Safe) })

  [profiles.unsafe(), profiles.ceiling()]
  |> list.each(fn(binding) { binding.mode |> should.equal(Unsafe) })
}
