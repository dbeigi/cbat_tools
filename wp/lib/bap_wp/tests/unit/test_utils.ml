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
open Bap_wp

module Pre = Precondition
module Constr = Constraint
module Env = Environment

(* Helper functions to assist in building basic blocks and subroutines *)
let zero : Exp.t = Bil.int @@ Word.zero 32
let one : Exp.t  = Bil.int @@ Word.one 32
let two : Exp.t = Bil.int @@ Word.of_int 2 ~width:32

let i32 (n : int) : Exp.t =
  Bil.int (Word.of_int ~width:32 n)

let mk_def ?tid:(tid = Tid.create ()) (var : var) (exp : exp) (block : Blk.t) : Blk.t =
  Term.append def_t block (Def.create ~tid:tid var exp)

let mk_phi (phi : Phi.t) (block : Blk.t) : Blk.t =
  Term.append phi_t block phi

let mk_jmp ?tid:(tid = Tid.create ()) (dst : Blk.t) (src : Blk.t) : Blk.t =
  Term.append jmp_t src (Jmp.create_goto ~tid:tid (Label.direct (Term.tid dst)))

let mk_call ?tid:(tid = Tid.create ()) (return : label) (target : label) (block : Blk.t)
  : Blk.t =
  let call = Call.create ~return:return ~target:target () in
  Term.append jmp_t block (Jmp.create_call ~tid:tid call)

let mk_int ?tid:(tid = Tid.create ()) (i : int) (return : Blk.t) (block : Blk.t)
  : Blk.t =
  Term.append jmp_t block (Jmp.create_int ~tid:tid i (Term.tid return))

let mk_cond ?tid:(tid = Tid.create ()) (cond : exp) (t : 'a Term.t) (f : 'b Term.t)
    (block : Blk.t) : Blk.t =
  let jmp_true = Jmp.create_goto ~tid:tid ~cond:cond (Label.direct (Term.tid t)) in
  let jmp_false = Jmp.create_goto (Label.direct (Term.tid f)) in
  Term.append jmp_t (Term.append jmp_t block jmp_true) jmp_false

let mk_arg ~intent:(intent : intent) (v : Var.t) : Arg.t =
  Bap.Std.Arg.create ~intent:intent (Var.create ~fresh:true "arg" (Var.typ v)) (Bil.var v)

let mk_sub ?tid:(tid = Tid.create ()) ?args:(args = []) ?name:(name = "")
    (blocks : Blk.t list) : Sub.t =
  let blk_build = Sub.Builder.create ~tid:tid ~name:name () in
  List.iter blocks ~f:(Sub.Builder.add_blk blk_build);
  List.iter args ~f:(Sub.Builder.add_arg blk_build);
  Sub.Builder.result blk_build

let mk_z3_expr (env : Env.t) (e : Exp.t) : Constr.z3_expr =
  let e, _, _, _ = Pre.exp_to_z3 e env in e

let mk_z3_var (env : Env.t) (v : Var.t) : Constr.z3_expr =
  fst (Env.get_var env v)

let print_z3_model (ff : Format.formatter) (solver : Z3.Solver.solver)
    (exp : Z3.Solver.status) (real : Z3.Solver.status) (ctx : Z3.context)
    (goals : Constr.t) : unit =
  if real = exp || real = Z3.Solver.UNSATISFIABLE then () else
    match Z3.Solver.get_model solver with
    | None -> ()
    | Some model ->
      let refuted_goals = Constr.get_refuted_goals goals solver ctx in
      Format.fprintf ff "\n\nCountermodel:\n%s\n%!" (Z3.Model.to_string model);
      Format.fprintf ff "\nRefuted goals:\n%!";
      Seq.iter refuted_goals ~f:(fun g ->
          Format.fprintf ff "%s\n%!" (Constr.refuted_goal_to_string g model))

(* Obtains the tid of a jump in a sub given its jump condition. *)
let jump_tid (sub : Sub.t) (cond : Exp.t) : Tid.t =
  let jumps =
    Term.enum blk_t sub
    |> Seq.map ~f:(fun b -> Term.enum jmp_t b)
    |> Seq.concat
  in
  Term.tid (Seq.find_exn jumps ~f:(fun j -> Exp.equal (Jmp.cond j) cond))

(* z3_expr representing a jump being taken. *)
let jump_taken (ctx : Z3.context) : Constr.z3_expr =
  Pre.z3_expr_one ctx 1

(* z3_expr representing a jump not being taken. *)
let jump_not_taken (ctx : Z3.context) : Constr.z3_expr =
  Pre.z3_expr_zero ctx 1

(* Evaluates a BIR expression to a z3_expr given the values in the Z3 model. *)
let eval_model (model : Z3.Model.model) (expr : Exp.t) (env : Env.t) : Constr.z3_expr =
  Z3.Model.eval model (mk_z3_expr env expr) true
  |> Option.value_exn ?here:None ?error:None ?message:None

let true_constr (ctx : Z3.context) : Constr.t =
  Z3.Boolean.mk_true ctx
  |> Constr.mk_goal "true"
  |> Constr.mk_constr

let false_constr (ctx : Z3.context) : Constr.t =
  Z3.Boolean.mk_false ctx
  |> Constr.mk_goal "false"
  |> Constr.mk_constr
