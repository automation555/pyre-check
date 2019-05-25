(* Copyright (c) 2016-present, Facebook, Inc.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree. *)

open Ast

type attribute = {
  name: Identifier.t;
  parent: Type.t;
  annotation: Annotation.t;
  value: Expression.t;
  defined: bool;
  class_attribute: bool;
  async: bool;
  initialized: bool;
  property: bool;
  final: bool;
  static: bool;
  frozen: bool
}
[@@deriving eq, show]

type t = attribute Node.t [@@deriving eq, show]

val name : t -> Identifier.t

val async : t -> bool

val annotation : t -> Annotation.t

val parent : t -> Type.t

val value : t -> Expression.t

val initialized : t -> bool

val location : t -> Location.t

val defined : t -> bool

val class_attribute : t -> bool

val final : t -> bool

val static : t -> bool

val instantiate : t -> constraints:(Type.t -> Type.t option) -> t

module Table : sig
  type element = t

  type t

  val create : unit -> t

  val add : t -> element -> unit

  val lookup_name : t -> string -> element option

  val to_list : t -> element list

  val clear : t -> unit

  val filter_map : f:(element -> element option) -> t -> unit
end
