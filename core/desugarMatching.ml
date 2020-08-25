open Sugartypes
open Utility
open SourceCode

(* This module desugars pattern-matching functions

  This transformation convert function like that:

  fun foo(a1, ..., an) match {
    | case (p1_1, ..., p1_n) -> b_1
    | ...
    | case (pm_1, pm_n) -> b_m
  }

  to function with switch body like that:

  fun foo(a1 as x1, ..., an as xn) {
    switch ((x1, ..., xn)) {
      case (p1_1, ..., p1_n) -> b_1
      ...
      case (pm_1, ..., pm_n) -> b_m
      case (_, ..., _) -> error("non-exhaustive")
  }

  The last non-exhaustive case with wild card pattern is always attached to the end of switch body.

*)

let with_pos = SourceCode.WithPos.make

let pattern_matching_sugar =
  Settings.(
    flag "pattern_matching_sugar"
    |> synopsis
         "Toggles whether to enable the switch pattern matching syntax sugar"
    |> convert parse_bool
    |> sync)

let pattern_matching_sugar_guard pos =
  let pattern_matching_sugar_disabled pos =
    Errors.disabled_extension ~pos ~setting:("pattern_matching_sugar", true) "Pattern Matching Sugar"
  in
  if not (Settings.get pattern_matching_sugar)
  then raise (pattern_matching_sugar_disabled pos)

let nullary_guard tuple pos =
  let nullary_error pos =
    Errors.desugaring_error ~pos:pos ~stage:Errors.DesugarMatching ~message:"Can't match over nullary function"
  in
  match tuple with
    | [] -> raise (nullary_error pos)
    | _ -> ()

let desugar_matching =
object ((self : 'self_type))
    inherit SugarTraversals.map as super
    method! binding = fun b ->
      let pos = WithPos.pos b in
      match WithPos.node b with
      |  Fun ({ fun_definition = (tvs, MatchFunlit (patterns, cases)); _ } as fn) ->
          pattern_matching_sugar_guard pos;
          (* bind the arguments with unique var name *)
          let name_list = List.map (fun pats -> List.map (fun pat -> (pat, Utility.gensym())) pats) patterns in
          let switch_tuple = List.map (fun (_, name) -> with_pos (Var name)) (List.flatten name_list) in
          nullary_guard switch_tuple pos;
          (* assemble exhaustive handler *)
          let exhaustive_patterns = with_pos (Pattern.Any) in
          let exhaustive_position = Format.sprintf "non-exhaustive pattern matching at %s" (SourceCode.Position.show pos) in
          let exhaustive_case = FnAppl (with_pos (Var "error"), [with_pos (Constant (CommonTypes.Constant.String exhaustive_position))]) in
          let normal_args =
            List.map (fun pats -> List.map (fun (pat, name) ->
                                              with_pos (Pattern.As (with_pos (Binder.make ~name ()), pat)))
                                            pats) name_list in
          let cases = cases@[(exhaustive_patterns, with_pos exhaustive_case)] in
          let switch_body = Switch (with_pos (TupleLit switch_tuple), cases, None) in
          let normal_fnlit = NormalFunlit (normal_args, with_pos switch_body) in
          let normal_fnlit = self#funlit normal_fnlit in
          let node = Fun { fun_binder = fn.fun_binder;
                           fun_linearity = fn.fun_linearity;
                           fun_definition = (tvs, normal_fnlit);
                           fun_location = fn.fun_location;
                           fun_signature = fn.fun_signature;
                           fun_unsafe_signature = fn.fun_unsafe_signature;
                           fun_frozen = fn.fun_frozen;
                           } in
          WithPos.make ~pos node
      | _ -> super#binding b
end

module Untyped
  = Transform.Untyped.Make.Transformer(struct
        let name = "desugar_match_functions"
        let obj = desugar_matching
      end)
