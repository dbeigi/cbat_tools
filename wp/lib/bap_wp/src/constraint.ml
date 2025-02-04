(***************************************************************************)
(*                                                                         *)
(*  Copyright (C) 2018/2019 The Charles Stark Draper Laboratory, Inc.      *)
(*                                                                         *)
(*  This file is provided under the license found in the LICENSE file in   *)
(*  the top-level directory of this project.                               *)
(*                                                                         *)
(*  This work is funded in part by ONR/NAWC Contract N6833518C0107.  Its   *)
(*  content does not necessarily reflect the position or policy of the US  *)
(*  Government and no official endorsement should be inferred.             *)
(*                                                                         *)
(***************************************************************************)

open !Core_kernel
open Bap.Std

module Expr = Z3.Expr
module Bool = Z3.Boolean

type z3_expr = Expr.expr

type path = bool Bap.Std.Tid.Map.t

type goal = { goal_name : string; goal_val : z3_expr }

let goal_to_string (g : goal) : string =
  Format.sprintf "%s: %s%!" g.goal_name (Expr.to_string (Expr.simplify g.goal_val None))

let refuted_goal_to_string (g : goal) (model : Z3.Model.model) : string =
  let buf = Buffer.create 1024 in
  Buffer.add_string buf (Format.sprintf "%s:" g.goal_name);
  if Bool.is_eq g.goal_val then begin
    let args = Expr.get_args g.goal_val in
    Buffer.add_string buf "\n\tConcrete values: = ";
    List.iter args ~f:(fun arg ->
        let value = Option.value_exn (Z3.Model.eval model arg true) in
        Buffer.add_string buf (Format.sprintf "%s " (Expr.to_string value)));
    Buffer.add_string buf "\n\tZ3 Expression: = ";
    List.iter args ~f:(fun arg ->
        let simplified = Expr.simplify arg None in
        Buffer.add_string buf (Format.sprintf "%s " (Expr.to_string simplified)));
  end else begin
    Buffer.add_string buf (Format.sprintf "\n\tZ3 Expression: %s"
                             (Expr.to_string (Expr.simplify g.goal_val None)));
  end;
  Buffer.contents buf

let mk_goal (name : string) (value : z3_expr) : goal =
  { goal_name = name; goal_val = value }

let get_goal_name (g : goal) : string =
  g.goal_name

let get_goal_val (g : goal) : z3_expr =
  g.goal_val

type t =
  | Goal of goal
  | ITE of Tid.t * z3_expr * t * t
  | Clause of t list * t list
  | Subst of t * z3_expr list * z3_expr list

let rec pp_constr (ch : Format.formatter) (constr : t) : unit =
  match constr with
  | Goal g -> Format.fprintf ch "%s" (goal_to_string g)
  | ITE (tid, e, c1, c2) ->
    Format.fprintf ch "ITE(%s, %s, %a, %a)"
      (Tid.to_string tid) (Expr.to_string e) pp_constr c1 pp_constr c2
  | Clause (hyps, concs) ->
    Format.fprintf ch "(";
    (List.iter hyps ~f:(fun h -> Format.fprintf ch "%a" pp_constr h));
    Format.fprintf ch ") => (";
    (List.iter concs ~f:(fun c -> Format.fprintf ch "%a" pp_constr c));
    Format.fprintf ch ")"
  | Subst (c, olds, news) ->
    Format.fprintf ch "Substitute: %s to %s in %a"
      (List.to_string ~f:Expr.to_string olds) (List.to_string ~f:Expr.to_string news)
      pp_constr c

let to_string (constr : t) : string =
  Format.asprintf "%a" pp_constr constr

let mk_constr (g : goal) : t =
  Goal g

let mk_ite (tid : Tid.t) (cond : z3_expr) (c1 : t) (c2 : t) : t =
  ITE (tid, cond, c1, c2)

let mk_clause (hyps: t list) (concs : t list) : t =
  Clause (hyps, concs)

let rec eval_aux (constr : t) (olds : z3_expr list) (news : z3_expr list)
    (ctx : Z3.context) : z3_expr =
  match constr with
  | Goal { goal_val = v; _ } -> Expr.substitute v olds news
  | ITE (_, e, c1, c2) ->
    let e' = Expr.substitute e olds news in
    Bool.mk_ite ctx e' (eval_aux c1 olds news ctx) (eval_aux c2 olds news ctx)
  | Clause (hyps, concs) ->
    let hyps_expr = List.map hyps ~f:(fun h -> eval_aux h olds news ctx)
                    |> Bool.mk_and ctx in
    let concs_expr = List.map concs ~f:(fun c -> eval_aux c olds news ctx)
                     |> Bool.mk_and ctx in
    Bool.mk_implies ctx hyps_expr concs_expr
  | Subst (c, o, n) ->
    let n' = List.map n ~f:(fun x -> Expr.substitute x olds news) in
    eval_aux c (olds @ o) (news @ n') ctx

(* This needs to be evaluated in the same context as was used to create the root goals *)
let eval (constr : t) (ctx : Z3.context) : z3_expr =
  eval_aux constr [] [] ctx

let substitute (constr : t) (olds : z3_expr list) (news : z3_expr list) : t =
  Subst (constr, olds, news)

let substitute_one (constr : t) (old_exp : z3_expr) (new_exp : z3_expr) : t =
  Subst (constr, [old_exp], [new_exp])

let get_refuted_goals_and_paths (constr : t) (solver : Z3.Solver.solver)
    (ctx : Z3.context) : (goal * path) seq =
  let model = Z3.Solver.get_model solver
              |> Option.value_exn ?here:None ?error:None ?message:None in
  let rec worker (constr : t) (current_path : path) (olds : z3_expr list)
      (news : z3_expr list) : (goal * path) seq =
    match constr with
    | Goal g ->
      let goal_val = Expr.substitute g.goal_val olds news in
      let goal_res = Option.value_exn (Z3.Model.eval model goal_val true) in
      begin
        match Z3.Solver.check solver [goal_res] with
        | Z3.Solver.SATISFIABLE -> Seq.empty
        | Z3.Solver.UNSATISFIABLE ->
          Seq.singleton ({g with goal_val = goal_val}, current_path)
        | Z3.Solver.UNKNOWN ->
          failwith (Format.sprintf "get_refuted_goals: Unable to resolve %s" g.goal_name)
      end
    | ITE (tid, cond, c1, c2) ->
      let cond_val = Expr.substitute cond olds news in
      let cond_res = Option.value_exn (Z3.Model.eval model cond_val true) in
      begin
        match Z3.Solver.check solver [cond_res] with
        | Z3.Solver.SATISFIABLE ->
          worker c1 (Tid.Map.set current_path ~key:tid ~data:true) olds news
        | Z3.Solver.UNSATISFIABLE ->
          worker c2 (Tid.Map.set current_path ~key:tid ~data:false) olds news
        | Z3.Solver.UNKNOWN ->
          failwith (Format.sprintf "get_refuted_goals: Unable to resolve branch \
                                    condition at %s" (Tid.to_string tid))
      end
    | Clause (hyps, concs) ->
      let hyp_vals =
        List.map hyps ~f:(fun h ->
            Z3.Model.eval model (eval_aux h olds news ctx) true
            |> Option.value_exn ?here:None ?error:None ?message:None)
      in
      let hyps_false =
        match Z3.Solver.check solver hyp_vals with
        | Z3.Solver.SATISFIABLE -> false
        | Z3.Solver.UNSATISFIABLE -> true
        | Z3.Solver.UNKNOWN ->
          failwith "get_refuted_goals: Unable to resolve value of hypothesis"
      in
      if hyps_false then
        Seq.empty
      else
        List.fold concs ~init:Seq.empty
          ~f:(fun accum c -> Seq.append (worker c current_path olds news) accum)
    | Subst (e, o, n) ->
      let n' = List.map n ~f:(fun x -> Expr.substitute x olds news) in
      worker e current_path (olds @ o) (news @ n')
  in
  worker constr Tid.Map.empty [] []

let get_refuted_goals (constr : t) (solver : Z3.Solver.solver) (ctx : Z3.context)
  : goal seq =
  Seq.map (get_refuted_goals_and_paths constr solver ctx) ~f:(fun (g,_) -> g)
