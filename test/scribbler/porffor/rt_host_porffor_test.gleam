//// Security + semantics tests for the Porffor host provider `scribbler/porffor/host` (P7-08
//// §A/§B). These assert the **measured Porffor 0.61.13 intrinsic semantics**
//// (`precompile.js`/`wrap.js` — `a`=print, `b`=printChar, `c`=time, `d`=timeOrigin) and the
//// **fail-closed** capability boundary (spec §4.5.4 — an unprovided import is not callable),
//// never "whatever the code emits".
////
//// WHERE THE BOUNDARY MOVED (the carder/scribbler split): pre-split these four were arms of
//// carder's `rt_host.resolve_handler`, reached through the numeric `call_host` ABI and gated at
//// the CALL SITE by a `HostWhitelist`. They are now closures owned by a `link.Namespace`
//// provider, resolved and matched at LINK time. So the fail-closed assertions below are made
//// where the decision now lives — the resolvers return `Error(Nil)` for anything outside
//// `{a,b,c,d}`, which carder renders as the spec's `UnknownImport` ("unknown import"), and a
//// mis-declared signature is `IncompatibleImportType` (spec §3.2.7 — a TIGHTENING over the
//// pre-split call-site-only gate). Both are asserted twice: directly against the provider's
//// resolvers, and through the real linker (`link.link_func_imports`).
////
//// The pre-split `{capability_denied, …}` proof is NOT dropped, it is re-stated where it still
//// bites: `call_host` remains the fate of a `""` import when scribbler's provider is ABSENT, and
//// `intrinsics_denied_without_the_provider_test` asserts that path denies under the deny-all
//// default AND under the Porffor whitelist. The two halves together say the whole thing — the
//// authority is the handed-in provider (D3a), never the posture and never ambient.
////
//// Isolation (F4/E1): the host output buffer is process-local, so every assertion that touches it
//// runs in its OWN spawned process (`in_process`) — buffers cannot leak across tests.

import carder/ir
import carder/runtime/instance.{HostDenyAll, HostWhitelist}
import carder/runtime/link
import carder/runtime/rt_host
import gleam/dynamic.{type Dynamic}
import gleam/erlang/process
import gleam/list
import gleam/option
import gleam/string
import gleeunit/should
import scribbler/porffor/host

// ───────────────────────────── harness ─────────────────────────────

/// Apply a fun VALUE to an argument list (`erlang:apply(Fun, Args)`), capturing a raise as
/// `Error(rendered_reason)` instead of crashing the runner. Needed because a capability DENIAL is
/// a raise (`{capability_denied, Cap, Name}`), so it cannot be observed by a plain call.
@external(erlang, "scribbler_emit_test_ffi", "apply_fun")
fn apply_fun(
  f: fn(List(Dynamic)) -> List(Dynamic),
  args: List(List(Dynamic)),
) -> Result(List(Dynamic), String)

/// Identity coercion `Int` → the closure ABI's `Dynamic`. Sound because a raw WASM argument
/// crossing carder's function-import ABI is always a bit pattern rendered as an Erlang integer
/// (D5), so the term is unchanged — this is the same coercion `scribbler/porffor/host` performs.
@external(erlang, "gleam_stdlib", "identity")
fn int_to_dyn(x: Int) -> Dynamic

/// Identity coercion of a returned raw bit pattern (`Dynamic`) back to `Int`; sound for the same
/// reason as `int_to_dyn`.
@external(erlang, "gleam_stdlib", "identity")
fn dyn_to_int(x: Dynamic) -> Int

/// Run `work` in a FRESH process (isolated pdict, so a fresh host output buffer) and return its
/// value. Panics via `let assert` only if the spawned process fails to reply within 5 s — a
/// genuinely impossible state for these pure, total handlers.
fn in_process(work: fn() -> a) -> a {
  let reply = process.new_subject()
  let _ = process.spawn(fn() { process.send(reply, work()) })
  let assert Ok(value) = process.receive(reply, within: 5000)
  value
}

/// The two resolvers behind `host.provider()`, as `#(func, state)`.
///
/// `let assert` on `link.Namespace` is safe by construction: `host.provider/0` is documented to
/// return a `Namespace` (it is a literal constructor call), never a `Registered`.
fn resolvers() -> #(
  fn(String, ir.FuncType) -> Result(link.Provided, Nil),
  fn(String) -> Result(link.Provided, Nil),
) {
  let assert link.Namespace(_link_name, func, state) = host.provider()
  #(func, state)
}

/// Resolve intrinsic `letter` through the provider using its OWN declared signature, then apply
/// the resolved closure to `args` (raw bit patterns).
///
/// Returns `Ok(results)` — the raw result bit patterns — or `Error(Nil)` when the provider does not
/// export `letter` as a function (the fail-closed "unknown import" answer).
fn call(letter: String, args: List(Int)) -> Result(List(Int), Nil) {
  let #(func, _state) = resolvers()
  let declared = case host.func_type(letter) {
    Ok(ty) -> ty
    // An unknown letter has no signature of ours; any declaration will do, since the resolver is
    // expected to reject the NAME before it ever looks at the type.
    Error(Nil) -> ir.FuncType([], [])
  }
  case func(letter, declared) {
    Ok(link.ProvidedFunc(_ty, run)) ->
      Ok(list.map(run(list.map(args, int_to_dyn)), dyn_to_int))
    Ok(_other) -> Error(Nil)
    Error(Nil) -> Error(Nil)
  }
}

// ── print (a): a number → its ECMAScript decimal string, appended to the buffer ──────────────

/// `""."a"` applied to `f64_bits(42.0)` returns `[]` AND the buffer gains the bytes `"42"`
/// (Porffor `print`, `i => print(i.toString())`).
pub fn print_appends_number_test() {
  let #(result, buffer) =
    in_process(fn() {
      let r = call("a", [0x4045000000000000])
      #(r, rt_host.host_output())
    })
  result |> should.equal(Ok([]))
  buffer |> should.equal(<<"42">>)
}

/// A `NaN` argument prints `"NaN"` (the special bit pattern, §F).
pub fn print_appends_nan_test() {
  let #(result, buffer) =
    in_process(fn() {
      let r = call("a", [0x7FF8000000000000])
      #(r, rt_host.host_output())
    })
  result |> should.equal(Ok([]))
  buffer |> should.equal(<<"NaN">>)
}

// ── printChar (b): a code unit → its UTF-8 byte(s), appended ──────────────────────────────────

/// `""."b"` applied to `f64_bits(65.0)` returns `[]` AND the buffer gains `"A"`
/// (Porffor `printChar`, `i => print(String.fromCharCode(i))`).
pub fn print_char_appends_ascii_test() {
  let #(result, buffer) =
    in_process(fn() {
      let r = call("b", [0x4050400000000000])
      #(r, rt_host.host_output())
    })
  result |> should.equal(Ok([]))
  buffer |> should.equal(<<"A">>)
}

/// Effect order is preserved: successive print/printChar calls concatenate in call order (the
/// `CallImport` barrier — the buffer accumulates). `printChar(72)` then `print(9)` then
/// `printChar(33)` → `"H9!"`.
pub fn buffer_preserves_order_test() {
  let buffer =
    in_process(fn() {
      // 'H' = 72.0 bits, 9.0 bits, '!' = 33.0 bits
      let _ = call("b", [0x4052000000000000])
      let _ = call("a", [0x4022000000000000])
      let _ = call("b", [0x4040800000000000])
      rt_host.host_output()
    })
  buffer |> should.equal(<<"H9!">>)
}

// ── time / timeOrigin (c / d): a deterministic f64 result ─────────────────────────────────────

/// `time` and `timeOrigin` return a single f64 result (the raw bits of the deterministic `0.0`,
/// §B.2), and write nothing to the buffer.
pub fn time_returns_scalar_test() {
  let #(result, buffer) =
    in_process(fn() {
      let r = call("c", [])
      #(r, rt_host.host_output())
    })
  result |> should.equal(Ok([0]))
  buffer |> should.equal(<<>>)

  in_process(fn() { call("d", []) }) |> should.equal(Ok([0]))
}

// ── fail-closed (J3/J5): an unprovided intrinsic never resolves ──────────────────────────────

/// An `""` name OUTSIDE {a,b,c,d} (e.g. a future `""."e"`, the PGO `profileLocalSet`) does NOT
/// resolve — the four-arm universe is the whole authority surface; never a silent stub. carder
/// turns this `Error(Nil)` into the spec's `UnknownImport` ("unknown import", §4.5.4).
pub fn unprovided_intrinsic_denies_test() {
  let #(func, _state) = resolvers()
  func("e", ir.FuncType([ir.TF64], []))
  |> should.equal(Error(Nil))
  call("e", [0]) |> should.equal(Error(Nil))
}

/// Porffor imports only FUNCTIONS from `""`, so the state resolver never answers — a global/table/
/// memory import of `""` is "unknown import", whatever its name.
pub fn state_import_never_resolves_test() {
  let #(_func, state) = resolvers()
  state("a") |> should.equal(Error(Nil))
  state("memory") |> should.equal(Error(Nil))
}

/// The resolver returns ITS OWN signature, not the guest's declared one, so carder's fail-closed
/// `sig == declared` equality REJECTS a mis-declared `""."a"` as `IncompatibleImportType`
/// ("incompatible import type") instead of mis-dispatching it.
pub fn resolver_returns_its_own_signature_test() {
  let #(func, _state) = resolvers()
  // Declare `a` wrongly as `[i32] -> [i32]`; the provider still answers `[f64] -> []`.
  let assert Ok(link.ProvidedFunc(ty, _run)) =
    func("a", ir.FuncType([ir.TI32], [ir.TI32]))
  ty |> should.equal(ir.FuncType([ir.TF64], []))
}

// ── the WHOLE-LINK fail-closed proofs: the authority comes from the PROVIDER (D3a) ─────────────

/// A minimal IR module whose only content is `imports` — enough to exercise the real linker, which
/// is where the `""` namespace is now resolved.
fn importing_module(imports: List(ir.ImportDecl)) -> ir.Module {
  ir.Module(
    name: "scribbler@porffor@host_test",
    uses_numerics: True,
    memories: [],
    globals: [],
    imports: imports,
    functions: [],
    exports: [],
    data_segments: [],
    tables: [],
    elements: [],
    start: option.None,
    tags: [],
  )
}

/// Resolve ONE `""` function import through the REAL link path (`link.link_func_imports` — the
/// call `scribbler/porffor/run` makes) against `providers`, yielding its dispatch closure or the
/// fail-closed `ImportError`.
fn link_one(
  name: String,
  ty: ir.FuncType,
  providers: List(link.Provider),
) -> Result(fn(List(Dynamic)) -> List(Dynamic), link.ImportError) {
  case
    link.link_func_imports(
      importing_module([ir.ImportFn("", name, ty)]),
      providers,
    )
  {
    Ok([p]) -> Ok(link.provided_func_call(p))
    Ok(_) -> panic as "one function import must yield exactly one closure"
    Error(e) -> Error(e)
  }
}

/// Through the real linker, an `""` name outside {a,b,c,d} is the spec's `UnknownImport`
/// ("unknown import", §4.5.4) — the provider's `Error(Nil)` really does become a LINK failure, so
/// a Porffor build that grows a PGO `""."e"` fails to link rather than silently acquiring a stub.
pub fn unknown_intrinsic_fails_to_link_test() {
  link_one("e", ir.FuncType([ir.TF64], []), [host.provider()])
  |> should.equal(Error(link.UnknownImport("", "e")))

  let assert Error(err) =
    link_one("e", ir.FuncType([ir.TF64], []), [host.provider()])
  link.import_error_phrase(err) |> should.equal("unknown import")
}

/// Through the real linker, a KNOWN intrinsic declared with the WRONG signature is
/// `IncompatibleImportType` ("incompatible import type", spec §3.2.7 — function types match by
/// EQUALITY): the provider's own signature wins, so a mis-declared `""."a"` is rejected rather
/// than mis-dispatched.
pub fn mis_declared_intrinsic_fails_to_link_test() {
  let assert Error(err) =
    link_one("a", ir.FuncType([], [ir.TF64]), [host.provider()])
  link.import_error_phrase(err) |> should.equal("incompatible import type")
}

/// **carder ALONE grants no `""` authority** — the pre-split "deny-all denies every intrinsic"
/// proof, re-stated where the decision now lives.
///
/// Link the same `""."a"` import WITHOUT scribbler's provider: no provider owns the namespace, so
/// carder treats it as a genuine host capability and hands back its `call_host`-wrapping closure,
/// gated at the CALL SITE. That call is then denied — under the fail-closed deny-all default
/// (`{capability_denied, "", "a"}`), and equally under the Porffor whitelist itself, because
/// carder ships no `""` handler for an admitting posture to invoke. So the intrinsics exist ONLY
/// because scribbler hands in the provider (D3a — a supplied capability, never ambient authority),
/// and no posture can conjure them.
pub fn intrinsics_denied_without_the_provider_test() {
  let assert Ok(call) = link_one("a", ir.FuncType([ir.TF64], []), [])

  // the fail-closed default posture
  in_process(fn() {
    rt_host.seed_policy(HostDenyAll)
    apply_fun(call, [[int_to_dyn(0x4045000000000000)]])
  })
  |> is_denial
  |> should.be_true

  // and even the Porffor whitelist, which NAMES `#("", "a")` — carder has no handler to admit
  in_process(fn() {
    rt_host.seed_policy(HostWhitelist(host.allow()))
    apply_fun(call, [[int_to_dyn(0x4045000000000000)]])
  })
  |> is_denial
  |> should.be_true
}

/// `True` iff `outcome` is the capability gate's raised rejection for the `#("", "a")` import —
/// the term `{capability_denied, <<>>, <<"a">>}` as rendered by the catching FFI. A NORMAL return
/// is `False`: the call was not denied, which is exactly the regression this guards.
fn is_denial(outcome: Result(List(Dynamic), String)) -> Bool {
  case outcome {
    Ok(_) -> False
    Error(text) ->
      string.contains(text, "capability_denied")
      && string.contains(text, "<<\"a\">>")
  }
}

// ── the intrinsic FuncType signature face (§B.5) ─────────────────────────────────────────────

/// `host.func_type` returns each intrinsic's declared signature (print/printChar `[f64] -> []`;
/// time/timeOrigin `[] -> [f64]`), and `Error(Nil)` for an unknown letter.
pub fn porffor_func_type_signatures_test() {
  host.func_type("a")
  |> should.equal(Ok(ir.FuncType([ir.TF64], [])))
  host.func_type("b")
  |> should.equal(Ok(ir.FuncType([ir.TF64], [])))
  host.func_type("c")
  |> should.equal(Ok(ir.FuncType([], [ir.TF64])))
  host.func_type("d")
  |> should.equal(Ok(ir.FuncType([], [ir.TF64])))
  host.func_type("e") |> should.equal(Error(Nil))
}

/// The pinned letter→builtin map (§A.3) is the four creation-order idents — a legible constant so
/// a Porffor version bump is a conscious re-measure.
pub fn porffor_intrinsics_pin_test() {
  host.intrinsics
  |> should.equal([
    #("a", "print"),
    #("b", "printChar"),
    #("c", "time"),
    #("d", "timeOrigin"),
  ])
}

// ── the buffer self-initialises empty + seeds empty ──────────────────────────────────────────

/// A never-printed instance reads `<<>>` (the buffer self-initialises empty per process, E1), and
/// `rt_host.host_output_seed` explicitly clears it.
pub fn buffer_empty_by_default_test() {
  in_process(fn() { rt_host.host_output() })
  |> should.equal(<<>>)

  in_process(fn() {
    let _ = call("a", [0x4045000000000000])
    rt_host.host_output_seed()
    rt_host.host_output()
  })
  |> should.equal(<<>>)
}
