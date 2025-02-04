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

(**

   This module creates utilities to create preconditions for comparing
   BIR blocks and subroutines.

   Usage typically involves creating a new (abstract) {!Environment.t}
   value, a Z3 context and a {!Environment.var_gen} using the utility
   functions.

   The resulting precondition can then be tested for satisfiability or
   provability using the Z3 Solver module using the {!precondition}
   module utilities.

*)

module Env = Environment

module Constr = Constraint

(** Compare two blocks by composition: given a set of common
    input and output variables, return a precondition which is provable
    only if (modulo soundness bugs) the subroutines have equal output
    variables given equal input variables. *)
val compare_blocks
  : input:Bap.Std.Var.Set.t
  -> output:Bap.Std.Var.Set.t
  -> original:(Bap.Std.Blk.t * Env.t)
  -> modified:(Bap.Std.Blk.t * Env.t)
  -> Constr.t * Env.t * Env.t

(** Compare two subroutines by composition for equality of return
    values:

    Given a set of common input and output variables, return a
    precondition which is provable only if (modulo soundness bugs) the
    subroutines have equal output variables given equal input
    variables. *)
val compare_subs_eq
  :  input:Bap.Std.Var.Set.t
  -> output:Bap.Std.Var.Set.t
  -> original:(Bap.Std.Sub.t * Env.t)
  -> modified:(Bap.Std.Sub.t * Env.t)
  -> Constr.t * Env.t * Env.t

(** Compare two subroutines by composition for an empty postcondition:

    Given two subroutines and environments, return a
    precondition which is provable only if (modulo soundness bugs) the VCs generated
    by the hooks provided by the environment are satisfied. *)
val compare_subs_empty
  :  original:(Bap.Std.Sub.t * Env.t)
  -> modified:(Bap.Std.Sub.t * Env.t)
  -> Constr.t * Env.t * Env.t

(** Compare two subroutines by composition for an empty
    postcondition:

    Given two subroutines and environments, return a precondition
    which is provable only if (modulo soundness bugs), for equal
    inputs, the VCs generated by the hooks provided by the environment
    are satisfied. *)
val compare_subs_empty_post
  :  input:Bap.Std.Var.Set.t
  -> original:(Bap.Std.Sub.t * Env.t)
  -> modified:(Bap.Std.Sub.t * Env.t)
  -> Constr.t * Env.t * Env.t

(** Compare two subroutines by composition for conservation of function calls:

    Given two subroutines and environments, return a
    precondition which is provable only if (modulo soundness bugs) every call made by
    the original subroutine is made by the modified one, given equal variables
    on input. *)
val compare_subs_fun
  :  original:(Bap.Std.Sub.t * Env.t)
  -> modified:(Bap.Std.Sub.t * Env.t)
  -> Constr.t * Env.t * Env.t
