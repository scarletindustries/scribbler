//// R14-01 §4.2 — the `ref.func` IMPORT-SPLIT in `scribbler/wasm/lower`, verified against the
//// WebAssembly spec (not a change-detector).
////
//// Per the spec the function index space is UNIFIED: imported functions occupy funcidx
//// `0 .. imported_func_count - 1` and defined functions follow (WebAssembly spec §2.5.11 "Modules
//// — Indices … the index space for functions … starts with the imports"). So `ref.func x`
//// names an IMPORTED function when `x < imported_func_count` and a DEFINED one otherwise, and
//// `lower` must route the two to different IR nodes — `ir.RefFuncImport(slot, ty)` for an import
//// (it can only be materialised through the instance's import table) and `ir.RefFunc("f<x>")` for
//// a defined function. This is the exact mirror of `lower_call`'s import split.
////
//// Both reaches are proven, since a wrong boundary in either silently builds a funcref onto the
//// wrong function:
////   - an ELEMENT SEGMENT's `ElemExprs` init (the cross-module `table.copy` shape), and
////   - a FUNCTION BODY's `ref.func`.
//// The boundary indices are covered from both sides: the LAST import (`x == imported - 1`) and
//// the FIRST defined function (`x == imported`).
////
//// **Scope (the split).** Everything about the `ir.RefFuncImport` NODE itself — that it is
//// expressible, that `effect.classify` makes it an `Effectful` barrier (no CSE, no DCE), that it
//// is memory-inert and not-a-call, its lossless `.ir` round-trip, the unchanged `TrapReason` set,
//// and that `emit_core` emits it — is carder's IR-level freeze, proven in carder's
//// `reffunc_import_freeze_test`. This file proves ONLY that the WebAssembly frontend produces the
//// right node for the right funcidx.

import carder/ir
import gleam/list
import gleam/option
import gleam/set
import gleeunit/should
import scribbler/wasm/ast
import scribbler/wasm/lower
import scribbler/wasm/validate

// ───────────────────────────── local inspection helpers ─────────────────────────────

/// Every expression node in `e`'s tree (itself plus all nested sub-expressions). `RefFuncImport`
/// is a LEAF (only a slot + type), so it lands in the default arm and a membership check over
/// `all_exprs(body)` finds it.
fn all_exprs(e: ir.Expr) -> List(ir.Expr) {
  let nested = case e {
    ir.Let(_, rhs, body) -> list.append(all_exprs(rhs), all_exprs(body))
    ir.Block(_, _, body) -> all_exprs(body)
    ir.Loop(_, _, _, body) -> all_exprs(body)
    ir.If(_, _, t, el) -> list.append(all_exprs(t), all_exprs(el))
    ir.Switch(_, _, arms, default) ->
      list.append(
        list.flat_map(arms, fn(a) { all_exprs(a.body) }),
        all_exprs(default),
      )
    ir.Charge(_, body) -> all_exprs(body)
    _ -> []
  }
  [e, ..nested]
}

/// The single defined function named `name` in the lowered module.
fn func(irm: ir.Module, name: String) -> ir.Function {
  let assert Ok(f) = list.find(irm.functions, fn(f) { f.name == name })
  f
}

/// Build a `validate.TypedModule` directly, bypassing `validate.validate` (mirrors the
/// `tail_call_lower_test` idiom). Only the fields `lower` reads for the `ref.func` import split are
/// meaningful: `imported_func_count` (the split boundary), `func_types` (indexed by ABSOLUTE
/// funcidx — imports first — so an imported funcidx recovers its signature), `types`/`imports` (the
/// import declarations), `funcs`/`func_locals` (the defined functions), and `elements`.
fn typed_module(
  imported: Int,
  types: List(ast.FuncType),
  imports: List(ast.Import),
  func_types: List(ast.FuncType),
  func_locals: List(List(ast.ValType)),
  funcs: List(ast.Func),
  elements: List(ast.ElementSegment),
) -> validate.TypedModule {
  validate.TypedModule(
    module: ast.Module(
      imported_func_count: imported,
      rec_groups: [],
      types: list.map(types, ast.func_def),
      imports: imports,
      tables: [],
      memories: [],
      globals: [],
      tags: [],
      funcs: funcs,
      start: option.None,
      elements: elements,
      data: [],
      data_count: option.None,
      exports: [],
    ),
    imported_func_count: imported,
    imported_global_count: 0,
    imported_table_count: 0,
    imported_memory_count: 0,
    func_types: func_types,
    func_locals: func_locals,
    global_types: [],
    table_types: [],
    memory_idx_types: [],
    elem_types: [],
    refs: set.new(),
    imported_tag_count: 0,
    tag_types: [],
  )
}

/// Lower `tm`, asserting success (the fixtures are structurally lowerable).
fn lower_ok(tm: validate.TypedModule) -> ir.Module {
  let assert Ok(irm) = lower.lower(tm)
  irm
}

// ───────────────────────────── the split fixture ─────────────────────────────

/// The `(i32) -> (i32)` and `(f64) -> ()` import signatures + the `() -> ()` unit, used across the
/// split fixture. `func_types` is indexed by absolute funcidx: `[ty0, ty1, unit, unit]`.
fn split_types() -> #(ast.FuncType, ast.FuncType, ast.FuncType) {
  #(
    ast.FuncType([ast.I32], [ast.I32]),
    ast.FuncType([ast.F64], []),
    ast.FuncType([], []),
  )
}

/// Two function imports (funcidx 0, 1) + two defined functions (funcidx 2, 3). `f2`'s body
/// `ref.func`s the IMPORT at funcidx 0; `f3`'s body `ref.func`s the DEFINED function at funcidx 2;
/// an active element segment `ref.func`s funcidx 0,1,2,3 in order (the whole boundary in one list).
fn split_module() -> validate.TypedModule {
  let #(ty0, ty1, unit) = split_types()
  typed_module(
    2,
    // module.types: 0=unit, 1=ty0, 2=ty1 (import type indices)
    [unit, ty0, ty1],
    [
      ast.Import("a", "ef0", ast.ImportFunc(1)),
      ast.Import("a", "ef1", ast.ImportFunc(2)),
    ],
    // func_types by absolute funcidx: imports first, then the two defined (unit)
    [ty0, ty1, unit, unit],
    [[], []],
    [
      ast.Func(0, [], [ast.RefFunc(0), ast.Drop, ast.End]),
      ast.Func(0, [], [ast.RefFunc(2), ast.Drop, ast.End]),
    ],
    [
      ast.ElementSegment(
        ast.ElemActive(0, [ast.I32Const(0), ast.End]),
        ast.FuncRef,
        ast.ElemExprs([
          [ast.RefFunc(0), ast.End],
          [ast.RefFunc(1), ast.End],
          [ast.RefFunc(2), ast.End],
          [ast.RefFunc(3), ast.End],
        ]),
      ),
    ],
  )
}

// ───────────────────────────── §4.2 the import-split is CORRECT ─────────────────────────────

/// §4.2 — the ELEMENT-SEGMENT split (the load-bearing cross-module path — `table.copy`'s shape).
/// Per the spec, `ref.func x` names the function at unified funcidx `x`; imports occupy
/// `0..imported-1`. So with `imported == 2` the segment `[ref.func 0, 1, 2, 3]` lowers to
/// `[RefFuncImport(0, ty0), RefFuncImport(1, ty1), RefFunc("f2"), RefFunc("f3")]` — imported items
/// (incl. the boundary `f == imported - 1 == 1`) become `RefFuncImport` carrying that import's
/// signature; defined items (incl. the first defined `f == imported == 2`) stay `RefFunc`.
pub fn ref_func_import_split_in_element_segment_test() {
  let #(ty0, ty1, _unit) = split_types()
  let irm = lower_ok(split_module())
  let assert [seg] = irm.elements
  seg.init
  |> should.equal([
    ir.RefFuncImport(0, ir.FuncType([ir.TI32], [ir.TI32])),
    ir.RefFuncImport(1, ir.FuncType([ir.TF64], [])),
    ir.RefFunc("f2"),
    ir.RefFunc("f3"),
  ])
  // Guard the fixture's premise: the two imported sigs really are ty0 / ty1.
  ty0 |> should.equal(ast.FuncType([ast.I32], [ast.I32]))
  ty1 |> should.equal(ast.FuncType([ast.F64], []))
}

/// §4.2 — the FUNCTION-BODY split. `f2`'s `ref.func 0` (an import, `0 < imported`) lowers to
/// `RefFuncImport(0, ty0)`; `f3`'s `ref.func 2` (defined, `2 >= imported`) lowers to
/// `RefFunc("f2")` — the exact mirror of `lower_call`'s split.
pub fn ref_func_import_split_in_function_body_test() {
  let irm = lower_ok(split_module())

  all_exprs(func(irm, "f2").body)
  |> list.contains(ir.RefFuncImport(0, ir.FuncType([ir.TI32], [ir.TI32])))
  |> should.equal(True)
  // …and NOT a defined `RefFunc("f0")` for the import.
  all_exprs(func(irm, "f2").body)
  |> list.contains(ir.RefFunc("f0"))
  |> should.equal(False)

  all_exprs(func(irm, "f3").body)
  |> list.contains(ir.RefFunc("f2"))
  |> should.equal(True)
  // …and the defined callee is NOT mis-routed to a `RefFuncImport`.
  all_exprs(func(irm, "f3").body)
  |> list.any(fn(e) {
    case e {
      ir.RefFuncImport(_, _) -> True
      _ -> False
    }
  })
  |> should.equal(False)
}
