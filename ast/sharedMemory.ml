(* Copyright (c) 2016-present, Facebook, Inc.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree. *)

open Core
open Pyre
module SharedMemory = Memory

module IntKey = struct
  type t = int

  let to_string = Int.to_string

  let compare = Int.compare

  type out = int

  let from_string = Int.of_string
end

module SymlinksToPaths = struct
  module SymlinkTarget = struct
    type t = string

    let to_string = ident

    let compare = String.compare

    type out = string

    let from_string = ident
  end

  module SymlinkSource = struct
    type t = PyrePath.t

    let prefix = Prefix.make ()

    let description = "SymlinkSource"
  end

  module SymlinksToPaths = SharedMemory.NoCache (SymlinkTarget) (SymlinkSource)

  let get target = SymlinksToPaths.get target

  let add target = SymlinksToPaths.add target

  let remove ~targets =
    List.filter ~f:SymlinksToPaths.mem targets
    |> SymlinksToPaths.KeySet.of_list
    |> SymlinksToPaths.remove_batch


  let hash_of_key = SymlinksToPaths.hash_of_key

  let serialize_key = SymlinksToPaths.serialize_key

  let compute_hashes_to_keys = SymlinksToPaths.compute_hashes_to_keys
end

module Sources = struct
  module SourceValue = struct
    type t = Source.t

    let prefix = Prefix.make ()

    let description = "AST"
  end

  module Sources = SharedMemory.NoCache (Reference.Key) (SourceValue)

  let get = Sources.get

  let add ({ Source.qualifier; _ } as source) = Sources.add qualifier source

  let remove qualifiers = Sources.KeySet.of_list qualifiers |> Sources.remove_batch

  let hash_of_qualifier = Sources.hash_of_key

  let serialize_qualifier = Sources.serialize_key

  let compute_hashes_to_keys ~keys =
    let add map qualifier =
      Map.set map ~key:(hash_of_qualifier qualifier) ~data:(serialize_qualifier qualifier)
    in
    List.fold keys ~init:String.Map.empty ~f:add
end

module Handles = struct
  module PathValue = struct
    type t = string

    let prefix = Prefix.make ()

    let description = "Path"
  end

  module Paths = SharedMemory.WithCache (IntKey) (PathValue)

  let get ~hash = Paths.get hash

  let add_handle_hash ~handle = Paths.write_through (String.hash handle) handle

  let hash_of_key = Paths.hash_of_key

  let serialize_key = Paths.serialize_key

  let compute_hashes_to_keys ~keys =
    List.map keys ~f:String.hash |> fun keys -> Paths.compute_hashes_to_keys ~keys
end

module Modules = struct
  module ModuleValue = struct
    type t = Module.t

    let prefix = Prefix.make ()

    let description = "Module"
  end

  module Modules = SharedMemory.WithCache (Reference.Key) (ModuleValue)

  let add ~qualifier ~ast_module = Modules.write_through qualifier ast_module

  let remove ~qualifiers =
    let references = List.filter ~f:Modules.mem qualifiers in
    Modules.remove_batch (Modules.KeySet.of_list references)


  let get ~qualifier = Modules.get qualifier

  let get_exports ~qualifier = get ~qualifier >>| Module.wildcard_exports

  let exists ~qualifier = Modules.mem qualifier

  let hash_of_key = Modules.hash_of_key

  let serialize_key = Modules.serialize_key

  let compute_hashes_to_keys = Modules.compute_hashes_to_keys
end

let heap_size () =
  Memory.SharedMemory.heap_size () |> Float.of_int |> (fun size -> size /. 1.0e6) |> Int.of_float
