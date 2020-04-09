(* Js_of_ocaml compiler
 * http://www.ocsigen.org/js_of_ocaml/
 * Copyright (C) 2010 Jérôme Vouillon
 * Laboratoire PPS - CNRS Université Paris Diderot
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published by
 * the Free Software Foundation, with linking exception;
 * either version 2.1 of the License, or (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA 02111-1307, USA.
 *)
open! Stdlib
open Code
open Flow

let rec function_cardinality info x acc =
  get_approx
    info
    (fun x ->
      match info.info_defs.(Var.idx x) with
      | Expr (Closure (l, _)) -> Some (List.length l)
      | Expr (Prim (Extern "%closure", [ Pc (NativeString prim) ])) -> (
          try Some (Primitive.arity prim) with Not_found -> None)
      | Expr (Apply (f, l, _)) -> (
          if List.mem f ~set:acc
          then None
          else
            match function_cardinality info f (f :: acc) with
            | Some n ->
                let diff = n - List.length l in
                if diff > 0 then Some diff else None
            | None -> None)
      | _ -> None)
    None
    (fun u v ->
      match u, v with
      | Some n, Some m when n = m -> u
      | _ -> None)
    x

let specialize_instr info dummy_funs (acc, free_pc, extra) i =
  match i with
  | Let (x, Apply (f, l, _)) when Config.Flag.optcall () -> (
      let n' = List.length l in
      match function_cardinality info f [] with
      | None -> i :: acc, free_pc, extra
      | Some n when n = n' -> Let (x, Apply (f, l, true)) :: acc, free_pc, extra
      | Some n when n < n' ->
          let v = Code.Var.fresh () in
          let args, rest = Stdlib.List.take n l in
          ( Let (v, Apply (f, args, true)) :: Let (x, Apply (v, rest, false)) :: acc
          , free_pc
          , extra )
      | Some n when n > n' ->
          let missing = Array.init (n - n') ~f:(fun _ -> Code.Var.fresh ()) in
          let missing = Array.to_list missing in
          let block =
            let params' = Array.init (n - n') ~f:(fun _ -> Code.Var.fresh ()) in
            let params' = Array.to_list params' in
            let return' = Code.Var.fresh () in
            { params = params'
            ; body = [ Let (return', Apply (f, l @ params', true)) ]
            ; branch = Return return'
            ; handler = None
            }
          in
          ( Let (x, Closure (missing, (free_pc, missing))) :: acc
          , free_pc + 1
          , (free_pc, block) :: extra )
      | _ -> i :: acc, free_pc, extra)
  (* Some [caml_alloc_dummy_function + caml_update_dummy] can be eliminated *)
  | Let (x, Prim (Extern "caml_alloc_dummy_function", [ _; _ ])) as i ->
      let acc =
        if Var.Map.exists (fun _ x' -> Var.equal x x') dummy_funs then acc else i :: acc
      in
      acc, free_pc, extra
  | Let (_, Prim (Extern "caml_update_dummy", [ Pv _; Pv clo ])) as i ->
      let acc = if Var.Map.mem clo dummy_funs then acc else i :: acc in
      acc, free_pc, extra
  | Let (x, e) when Var.Map.mem x dummy_funs ->
      let acc =
        let new_x = Var.Map.find x dummy_funs in
        Let (new_x, e) :: acc
      in
      acc, free_pc, extra
  | _ -> i :: acc, free_pc, extra

let buid_dummy_functions_map p =
  let dummy_alloc, update =
    Addr.Map.fold
      (fun _ block acc ->
        List.fold_left block.body ~init:acc ~f:(fun ((alloc, update) as acc) i ->
            match i with
            | Let (dummy, Prim (Extern "caml_alloc_dummy_function", [ _; _ ])) ->
                (* [dummy] will be bound once only, it's an invariant *)
                Var.Set.add dummy alloc, update
            | Let (_, Prim (Extern "caml_update_dummy", [ Pv dummy; Pv clo_var ])) ->
                assert (not (Var.Map.mem clo_var update));
                alloc, Var.Map.add clo_var dummy update
            | _ -> acc))
      p
      (Var.Set.empty, Var.Map.empty)
  in
  (* We only want to keep [caml_update_dummy] and correspond to
     [caml_alloc_dummy_function]]. There are occurrences of [caml_update_dummy] that are
     unrelated (e.g. [let rec unfinite_zeros = 0 :: unfinite_zeros]) *)
  Var.Map.filter (fun _clo dummy -> Var.Set.mem dummy dummy_alloc) update

let specialize_instrs info p =
  let dummy_funs = buid_dummy_functions_map p.blocks in
  let blocks, free_pc =
    Addr.Map.fold
      (fun pc block (blocks, free_pc) ->
        let body, free_pc, extra =
          List.fold_right block.body ~init:([], free_pc, []) ~f:(fun i acc ->
              specialize_instr info dummy_funs acc i)
        in
        let blocks =
          List.fold_left extra ~init:blocks ~f:(fun blocks (pc, b) ->
              Addr.Map.add pc b blocks)
        in
        Addr.Map.add pc { block with Code.body } blocks, free_pc)
      p.blocks
      (Addr.Map.empty, p.free_pc)
  in
  { p with blocks; free_pc }

let f info p = specialize_instrs info p
