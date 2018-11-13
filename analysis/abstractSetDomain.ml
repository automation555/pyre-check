(** Copyright (c) 2016-present, Facebook, Inc.

    This source code is licensed under the MIT license found in the
    LICENSE file in the root directory of this source tree. *)

open Core

open AbstractDomain


module Make(Element : Set.Elt) = struct
  module Set = struct
    module ElementSet = Set.Make(Element)
    include ElementSet.Tree
  end

  include Set


  let bottom =
    Set.empty


  let is_bottom =
    Set.is_empty


  let join left right =
    Set.union left right


  let widen ~iteration:_ ~previous ~next =
    join previous next


  let less_or_equal ~left ~right =
    Set.is_subset left ~of_:right


  let show set =
    Sexp.to_string [%message (set: Set.t)]


  type _ part +=
    | Element: Element.t part


  let fold (type a b) (part: a part) ~(f: b -> a -> b) ~(init: b) set : b =
    match part with
    | Element ->
        fold ~f ~init set
    | _ ->
        Obj.extension_constructor part
        |> Obj.extension_name
        |> failwith "Unknown part %s in fold"


  let transform (type a) (part: a part) ~(f: a -> a) set =
    match part with
    | Element ->
        elements set
        |> List.fold ~f:(fun result element -> add result (f element)) ~init:empty
    | _ ->
        Obj.extension_constructor part
        |> Obj.extension_name
        |> failwith "Unknown part %s in transform"


  let partition (type a b) (part: a part) ~(f: a -> b) set =
    let update element = function
      | None -> singleton element
      | Some set -> Set.add set element
    in
    match part with
    | Element ->
        let f result element =
          let key = f element in
          Map.Poly.update result key ~f:(update element)
        in
        Set.fold set ~f ~init:Map.Poly.empty
    | _ ->
        Obj.extension_constructor part
        |> Obj.extension_name
        |> failwith "Unknown part %s in partition"

end
