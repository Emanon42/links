open Notfound

module type S = 
sig
  type name
  type 'a t
  val empty : 'a t
  val bind : 'a t -> name * 'a -> 'a t
  val extend : 'a t -> 'a t -> 'a t
  val has : 'a t -> name -> bool
  val lookup : 'a t -> name -> 'a
  val find : 'a t -> name -> 'a option
  module Dom : Utility.Set.S
  val domain : 'a t -> Dom.t
  val range : 'a t -> 'a list

  val map : ('a -> 'b) -> 'a t -> 'b t
  val fold : (name -> 'a -> 'b -> 'b) -> 'a t -> 'b -> 'b
  val show_t : 'a Show.show -> 'a t Show.show
end

module Make (Ord : Utility.OrderedShow) :
  S with type name = Ord.t 
    and module Dom = Utility.Set.Make(Ord) =
struct
  module M = Utility.Map.Make(Ord)

  type name = Ord.t
  type 'a t = 'a M.t

  let empty = M.empty
  let bind env (n,v) = M.add n v env
  let extend = M.superimpose
  let has env name = M.mem name env
  let lookup env name = M.find name env
  let find env name = M.lookup name env
  module Dom = Utility.Set.Make(Ord)
  let domain map = M.fold (fun k _ -> Dom.add k) map Dom.empty
  let range map = M.fold (fun _ v l -> v::l) map []
  let map = M.map
  let fold = M.fold
  let show_t = M.show_t
end

module String
  = Make(Utility.String)
module Int
  = Make(Utility.Int)

(* Given an environment mapping source names to IR names return
   the inverse environment mapping IR names to source names.

   Moved here from links.ml. Takes an Env.String.t and now returns an
   Env.Int.t instead of an IntMap.t, which makes much more sense. *)
let invert_env env =
  String.fold
    (fun name var env ->
       if Int.has env var then
         failwith ("(invert_env) duplicate variable in environment")
       else
         Int.bind env (var, name))
    env Int.empty