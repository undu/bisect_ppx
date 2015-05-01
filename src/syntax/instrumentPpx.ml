(*
 * This file is part of Bisect.
 * Copyright (C) 2008-2012 Xavier Clerc.
 *
 * Bisect is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 3 of the License, or
 * (at your option) any later version.
 *
 * Bisect is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 *)

open Parsetree
open Asttypes
open Ast_mapper
open Ast_helper

let intconst x =
  (* E.constant (Const_int x) *)
  Exp.constant (Const_int x)

let lid ?(loc = Location.none) s =
  Location.mkloc (Longident.parse s) loc
  (* Exp.ident ~loc (Location.mkloc (Longident.parse s) loc) *)

let constr id =
  let t = Location.mkloc (Longident.parse id) Location.none in
  Exp.construct t None
  (*let t = Location.mkloc (Longident.parse id) Location.none in
  E.(construct t None false) *)

let trueconst () = constr "true"

let unitconst () = constr "()"

let strconst s =
  Exp.constant (Const_string (s, None)) (* What's the option for? *)

let string_of_ident ident =
  String.concat "." (Longident.flatten ident.txt)

(* To be raised when an offset is already marked. *)
exception Already_marked

let apply_nolabs ?loc lid el =
  Exp.apply ?loc
    (Exp.ident ?loc lid)
    (List.map (fun e -> ("",e)) el)


(* Creates the marking expression for given file, offset, and kind.
   Populates the 'points' global variable.
   Raises 'Already_marked' when the passed file is already marked for the
   passed offset. *)
let marker file ofs kind marked =
  let lst = InstrumentState.get_points_for_file file in
  if List.exists (fun p -> p.Common.offset = ofs) lst then
    raise Already_marked
  else
    let idx = List.length lst in
    if marked then InstrumentState.add_marked_point idx;
    let pt = { Common.offset = ofs; identifier = idx; kind = kind } in
    InstrumentState.set_points_for_file file (pt :: lst);
    let loc = Location.none in
    match !InstrumentArgs.mode with
    | InstrumentArgs.Safe ->
        apply_nolabs ~loc (lid "Bisect.Runtime.mark") [strconst file; intconst idx]
        (* E.(apply_nolabs ~loc
             (lid "Bisect.Runtime.mark")
             [strconst file; intconst idx]) *)
    | InstrumentArgs.Fast
    | InstrumentArgs.Faster ->
        apply_nolabs ~loc (lid "___bisect_mark___") [intconst idx]
        (*E.(apply_nolabs ~loc
             (lid "___bisect_mark___")
             [intconst idx]) *)

(* Tests whether the passed expression is a bare mapping,
   or starts with a bare mapping (if the expression is a sequence).
   Used to avoid unnecessary marking. *)
let rec is_bare_mapping e =
  match e.pexp_desc with
  | Pexp_function _ -> true
  | Pexp_match _ -> true
  | Pexp_sequence (e', _) -> is_bare_mapping e'
  | _ -> false

(* Wraps an expression with a marker, returning the passed expression
   unmodified if the expression is already marked, is a bare mapping,
   has a ghost location, construct instrumentation is disabled, or a
   special comments indicates to ignore line. *)
let wrap_expr k e =
  let enabled = List.assoc k InstrumentArgs.kinds in
  let loc = e.pexp_loc in
  let dont_wrap =
    (is_bare_mapping e)
    || (loc.Location.loc_ghost)
    || (not !enabled) in
  if dont_wrap then
    e
  else
    try
      let ofs = loc.Location.loc_start.Lexing.pos_cnum in
      let file = loc.Location.loc_start.Lexing.pos_fname in
      let line = loc.Location.loc_start.Lexing.pos_lnum in
      let c = CommentsPpx.get file in
      let ignored =
        List.exists
          (fun (lo, hi) ->
            line >= lo && line <= hi)
          c.CommentsPpx.ignored_intervals in
      if ignored then
        e
      else
        let marked = List.mem line c.CommentsPpx.marked_lines in
        Exp.sequence ~loc (marker file ofs k marked) e
        (* E.(sequence ~loc (marker file ofs k marked) e) *)
    with Already_marked -> e

(* Wraps a sequence. *)
let rec wrap_seq k e =
  let _loc = e.pexp_loc in
  match e.pexp_desc with
  | Pexp_sequence (e1, e2) ->
      Exp.sequence (wrap_seq k e1) (wrap_seq Common.Sequence e2)
      (*E.sequence (wrap_seq k e1) (wrap_seq Common.Sequence e2) *)
  | _ ->
      wrap_expr k e

let wrap_case k case =
  match case.pc_guard with
  | None   -> Exp.case case.pc_lhs (wrap_expr k case.pc_rhs)
  | Some e -> Exp.case case.pc_lhs ~guard:(wrap_expr k e) (wrap_expr k case.pc_rhs)

(* Wraps an expression possibly denoting a function. *)
let rec wrap_func k e =
  let loc = e.pexp_loc in
  match e.pexp_desc with
  | Pexp_function clst ->
      List.map (wrap_case k) clst |> Exp.function_ ~loc
  (*| Pexp_function (lbl, eo, l) ->
      let l = List.map (fun (p, e) -> (p, wrap_func k e)) l in
      E.function_ ~loc lbl eo l *)
  | Pexp_poly (e, ct) ->
      (*E.poly ~loc (wrap_func k e) ct *)
      Exp.poly ~loc (wrap_func k e) ct
  | _ -> wrap_expr k e

let wrap_class_field_kind k = function
    | Cfk_virtual _ as cf -> cf
    | Cfk_concrete (o,e) -> Cf.concrete o (wrap_expr k e)

let class_expr ce =
  let loc = ce.pcl_loc in
  (*let ce = super#class_expr ce in *)
  match ce.pcl_desc with
  | Pcl_apply (ce, l) ->
      let l =
        List.map
          (fun (l, e) ->
            (l, (wrap_expr Common.Class_expr e)))
          l in
      (* CE.apply ~loc ce l *)
      Cl.apply ~loc ce l
  | _ -> ce

let class_field cf =
  let loc = cf.pcf_loc in
  (*let cf = super#class_field cf in *)
  match cf.pcf_desc with
  (*| Pcf_val (id, mut, over, e) -> *)
  | Pcf_val (id, mut, cf) ->
      (* CE.val_ ~loc id mut over (wrap_expr Common.Class_val e) *)
      Cf.val_ ~loc id mut (wrap_class_field_kind Common.Class_val cf)
  (* | Pcf_meth (id, priv, over, e) -> *)
  | Pcf_method (id, mut, cf) ->
      (* CE.meth ~loc id priv over (wrap_func Common.Class_meth e) *)
      Cf.method_ ~loc id mut (wrap_class_field_kind Common.Class_meth cf)
  (*| Pcf_init e -> *)
  | Pcf_initializer e ->
      (* CE.init ~loc (wrap_expr Common.Class_init e) *)
      Cf.initializer_ ~loc (wrap_expr Common.Class_init e)
  | _ -> cf

let expr e =
  let loc = e.pexp_loc in
  (* let e' = super#expr e in *)
  let e' = e in
  match e'.pexp_desc with
  | Pexp_let (rec_flag, l, e) ->
      let l =
        List.map (fun vb ->
        {vb with pvb_expr = wrap_expr Common.Binding vb.pvb_expr}) l in
      (*let l = List.map (fun (p, e) -> (p, wrap_expr Common.Binding e)) l in *)
      Exp.let_ ~loc rec_flag l (wrap_expr Common.Binding e)
      (*E.let_ ~loc rec_flag l (wrap_expr Common.Binding e) *)
  | Pexp_apply (e1, [l2, e2; l3, e3]) ->
      (match e1.pexp_desc with
      | Pexp_ident ident
        when
          List.mem (string_of_ident ident) [ "&&"; "&"; "||"; "or" ] ->
            Exp.apply ~loc e1
              [l2, (wrap_expr Common.Lazy_operator e2);
              l3, (wrap_expr Common.Lazy_operator e3)]
          (*E.apply
            ~loc
            e1
            [l2, (wrap_expr Common.Lazy_operator e2);
              l3, (wrap_expr Common.Lazy_operator e3)]
              *)
      | _ -> e')
  | Pexp_match (e, l) ->
      (*let l = List.map (fun (p, e) -> (p, wrap_expr Common.Match e)) l in
      E.match_ ~loc e l *)
      List.map (wrap_case Common.Match) l
      |> Exp.match_ ~loc e
  | Pexp_try (e, l) ->
      (*let l = List.map (fun (p, e) -> (p, wrap_expr Common.Match e)) l in
      E.try_ ~loc (wrap_expr Common.Sequence e) l *)
      List.map (wrap_case Common.Match) l
      |> Exp.try_ ~loc (wrap_expr Common.Sequence e)
  | Pexp_ifthenelse (e1, e2, e3) ->
      (*E.ifthenelse
          ~loc
          e1
          (wrap_expr Common.If_then e2)
          (match e3 with Some x -> Some (wrap_expr Common.If_then x) | None -> None) *)
      Exp.ifthenelse ~loc e1 (wrap_expr Common.If_then e2)
        (match e3 with Some x -> Some (wrap_expr Common.If_then x) | None -> None)
  | Pexp_sequence _ ->
      (wrap_seq Common.Sequence e')
  | Pexp_while (e1, e2) ->
      (* E.while_ ~loc e1 (wrap_seq Common.While e2) *)
      Exp.while_ ~loc e1 (wrap_seq Common.While e2)
  | Pexp_for (id, e1, e2, dir, e3) ->
      (* E.for_ ~loc id e1 e2 dir (wrap_seq Common.For e3) *)
      Exp.for_ ~loc id e1 e2 dir (wrap_seq Common.For e3)
  | _ -> e'

let structure_item si =
  let loc = si.pstr_loc in
  match si.pstr_desc with
  | Pstr_value (rec_flag, l) ->
      let l =
        List.map (fun vb ->
          { vb with pvb_expr =
              match vb.pvb_pat.ppat_desc with
              | Ppat_var ident when Exclusions.contains
                    (ident.loc.Location.loc_start.Lexing.pos_fname)
                  ident.txt -> vb.pvb_expr
              (*| _ -> wrap_func Common.Binding (self#expr vb.pvb_expr)}) *)
              | _ -> wrap_func Common.Binding (expr vb.pvb_expr)})
        l
      (*let l =
        List.map
          (fun (p, e) ->
            match p.ppat_desc with
            | Ppat_var ident
              when Exclusions.contains
                  (ident.loc.Location.loc_start.Lexing.pos_fname)
                  ident.txt ->
                    (p, e)
            | _ ->
                (p, wrap_func Common.Binding (self#expr e)))
          l
          *)
      in
      (*[ M.value ~loc rec_flag l ] *)
        Str.value ~loc rec_flag l
  (*| Pstr_eval e -> *)
  | Pstr_eval (e, a) ->
      (*[ M.eval ~loc (wrap_expr Common.Toplevel_expr (self#expr e)) ]*)
      (*Str.eval ~loc (wrap_expr Common.Toplevel_expr (self#expr e)) *)
      Str.eval ~loc (wrap_expr Common.Toplevel_expr (expr e))
  | _ ->
      si
      (* super#structure_item si *)

let safe file =
  (*let e = E.(apply_nolabs (lid "Bisect.Runtime.init") [strconst file]) in *)
  let e = apply_nolabs (lid "Bisect.Runtime.init") [strconst file] in
  let tab =
    List.fold_right
      (fun idx acc -> (intconst idx) :: acc)
      (InstrumentState.get_marked_points ())
      []
  in
  let mark_array =
    (*E.(apply_nolabs
                  (lid "Bisect.Runtime.mark_array")
                  [strconst file; array tab])*)
    apply_nolabs (lid "Bisect.Runtime.mark_array") [strconst file; Exp.array tab]
  in
  let e =
    if tab <> [] then
      (*E.sequence e mark_array *)
      Exp.sequence e mark_array
    else
      e
  in
  InstrumentState.add_file file;
  (*M.eval e *)
  Str.eval e

let pattern_var id =
  Pat.var (Location.mkloc id Location.none)
  (*P.var { txt = id; loc = Location.none } *)

let faster file =
  let nb = List.length (InstrumentState.get_points_for_file file) in
  let ilid s = Exp.ident (lid s) in
  let init =
    apply_nolabs (lid "Bisect.Runtime.init_with_array")
      [strconst file; ilid "marks"; trueconst ()]
  in
    (*E.(apply_nolabs
          (lid "Bisect.Runtime.init_with_array")
          [strconst file; lid "marks"; trueconst ()]) in *)
  let make = apply_nolabs (lid "Array.make") [intconst nb; intconst 0] in
    (*E.(apply_nolabs
          (lid "Array.make")
          [intconst nb; intconst 0]) in *)
  let marks =
    List.fold_left
      (fun acc (idx, nb) ->
        let mark =
          apply_nolabs (lid "Array.set")
            [ ilid "marks"; intconst idx; intconst nb]
          (*E.(apply_nolabs
                (lid "Array.set")
                [lid "marks"; intconst idx; intconst nb])  *)
        in
        (* E.sequence acc mark) *)
        Exp.sequence acc mark)
      init
      (InstrumentState.get_marked_points_assoc ()) in
  let func =
    let body =
      let if_then_else =
        Exp.ifthenelse
            (apply_nolabs (lid "<") [ilid "curr"; ilid "Pervasives.max_int"])
            (apply_nolabs (lid "Pervasives.succ") [ilid "curr"])
            (Some (ilid "curr"))
        (*E.(ifthenelse
            (apply_nolabs (lid "<") [lid "curr"; lid "Pervasives.max_int"])
            (apply_nolabs (lid "Pervasives.succ") [lid "curr"])
            (Some (lid "curr")))*)
      in
      let vb =
        Vb.mk (pattern_var "curr")
              (apply_nolabs (lid "Array.get") [ilid "marks"; ilid "idx"])
      in
      Exp.let_ Nonrecursive [vb]
          (apply_nolabs
              (lid "Array.set")
              [ilid "marks"; ilid "idx"; if_then_else])
      (*E.(let_ Nonrecursive [pattern_var "curr",
                            apply_nolabs (lid "Array.get") [lid "marks"; lid "idx"]]
            (apply_nolabs
              (lid "Array.set")
              [lid "marks"; lid "idx"; if_then_else]))*)
    in
    let body =
      if !InstrumentArgs.mode = InstrumentArgs.Fast then
        let before = apply_nolabs (lid "hook_before") [unitconst ()] in
        let after = apply_nolabs (lid "hook_after") [unitconst ()] in
        Exp.(sequence (sequence before body) after)
        (* E.(sequence (sequence before body) after) *)
      else
        body
    in
    Exp.(function_ [ case (pattern_var "idx") body ])
    (*E.(function_ "" None [pattern_var "idx", body])*)
  in
  let hooks =
    if !InstrumentArgs.mode = InstrumentArgs.Fast then
      let exp = apply_nolabs (lid "Bisect.Runtime.get_hooks") [unitconst ()] in
      let pat = Pat.tuple [ pattern_var "hook_before" ; pattern_var "hook_after" ] in
      [ Vb.mk pat exp ]
      (*[P.tuple [pattern_var "hook_before"; pattern_var "hook_after"],
        E.(apply_nolabs (lid "Bisect.Runtime.get_hooks") [unitconst ()])] *)
    else
      []
  in
  let vb = (Vb.mk (pattern_var "marks") make) :: hooks in
  let e =
    Exp.(let_ Nonrecursive vb (sequence marks func))
    (*E.(let_ Nonrecursive ((pattern_var "marks", make) :: hooks)
          (sequence marks func))  *)
  in
  InstrumentState.add_file file;
  (*M.value Nonrecursive [pattern_var "___bisect_mark___", e] *)
  Str.value Nonrecursive [ Vb.mk (pattern_var "___bisect_mark__") e]

let get_filename = function
  | [] -> None
  | si :: _ ->
    let f,_,_ = Location.get_pos_info si.pstr_loc.loc_start in
    Some f

(* Initializes storage and applies requested marks. *)
let structure ast =
  (*let _, ast = super#implementation file ast in *)
  match get_filename ast with
  | None -> ast
  | Some file ->
    if not (InstrumentState.is_file file) then
      let header =
        match !InstrumentArgs.mode with
        | InstrumentArgs.Safe   -> safe file
        | InstrumentArgs.Fast
        | InstrumentArgs.Faster -> faster file
      in
      header :: ast
    else
      ast

let instrumenter =
  { default_mapper
      with class_expr     = (fun _mpr ce -> class_expr ce)
         ; class_field    = (fun _mpr cf -> class_field cf)
         ; expr           = (fun _mpr e  -> expr e)
         ; structure_item = (fun _mpr si -> structure_item si)
         ; structure      = (fun _mpr s  -> structure s)
  }
