open Flowlog_Types
open Flowlog_Parse_Helpers
open Flowlog_Helpers
open Printf
open ExtList.List

(**********************************************************************)
(* Produce dependency graphs (and associated relations) for Flowlog programs *)
(**********************************************************************)

(* ~~ More types than needed at first,
      expect will eventually add new fields
      e.g., conditions on events/packets.
   ~~ Distinction between incoming/outgoing event tables: is it important? *)

type data_node = | NLocalTable of string 
                 | NRemoteTable of string
                 | NIncomingTable of string
                 | NOutgoingTable of string;;

type data_edge = { dsrc: data_node;
                   dsink: data_node;
                   mode: string};;

type depend_graph = {datanodes: data_node list; 
                     dependencies: data_edge list};;   

type named_program = {program: flowlog_program;
                      name: string}

let make_data_node (prgm: named_program) (r: string): data_node =  
  if is_local_table prgm.program r then NLocalTable(r)
  else if is_remote_table prgm.program r then NRemoteTable(r)
  else if is_incoming_table prgm.program r then NIncomingTable(r)
  else if is_outgoing_table prgm.program r then NOutgoingTable(r)
  else failwith ("make_data_node: unknown "^r);;    

let atom_to_relname (f: formula): string =
  match f with
    | FAtom(_, r, _) -> r 
    | _ -> failwith "atom_to_relname";;

let depends_from_rule (prgm: named_program) (datamod: string) (triggerrel: string) 
                      (headrel: string) (wherefmla: formula): data_edge list =  
  let sink = make_data_node prgm headrel in
  let body_atoms = get_atoms wherefmla in
  let body_sources = map (make_data_node prgm)
                       (map atom_to_relname body_atoms) in  
  let trigger_source = make_data_node prgm triggerrel in
    map (fun src -> {dsrc = src; dsink=sink; mode=datamod}) (trigger_source::body_sources);;


let depends_from_clause (prgm: named_program) (cl: clause): data_edge list =  
  match cl.orig_rule with
    | Rule(triggerrel, _, AInsert(headrel, _, fmla)) ->
      depends_from_rule prgm "+" triggerrel headrel fmla
    | Rule(triggerrel, _, ADelete(headrel, _, fmla)) ->
      depends_from_rule prgm "-" triggerrel headrel fmla
    | Rule(triggerrel, _, ADo(headrel, _, fmla)) -> 
      depends_from_rule prgm "" triggerrel headrel fmla;;

let enhance_graph_with_clause (prgm: named_program) (acc: depend_graph) (cl: clause): depend_graph =
  let new_dependencies = unique (depends_from_clause prgm cl @ acc.dependencies) in
  let new_datanodes = unique (fold_left (fun acc dep -> dep.dsrc :: dep.dsink :: acc) [] new_dependencies) in  
    {datanodes = new_datanodes; dependencies = new_dependencies};;

(* Roll over all the clauses, adding nodes/edges for each *)
let build_depend_graph (prgms: named_program list): depend_graph =
  fold_left (fun (acc: depend_graph) (prg: named_program) -> 
              fold_left (enhance_graph_with_clause prg) acc prg.program.clauses)  
    {datanodes = []; dependencies = []} prgms;;

let string_of_data_node (n: data_node): string = 
  match n with 
    | NLocalTable(str) -> "TABLE("^str^")"
    | NRemoteTable(str) -> "REMOTE("^str^")"
    | NIncomingTable(str) -> "IN("^str^")"
    | NOutgoingTable(str) -> "OUT("^str^")";;

let get_nodes_affecting (es: data_edge list) (n: data_node): data_node list =
  filter_map (fun e -> 
      if e.dsink <> n then None
      else Some e.dsrc)
    es;;
let get_nodes_affected_by (es: data_edge list) (n: data_node): data_node list =
  filter_map (fun e -> 
      if e.dsrc <> n then None
      else Some e.dsink)
    es;;    

let string_of_dependencies (g: depend_graph): string =
  let nodestrs = map (fun (n: data_node) -> 
        (string_of_data_node n) 
        ^" <-- "^
        (String.concat ", " 
          (map string_of_data_node (get_nodes_affecting g.dependencies n)))) g.datanodes in 
    String.concat "\n" nodestrs;;

  let files_to_graph (fnames: string list): depend_graph =  
    let prgms = map (fun fname -> 
       {name=fname; program=desugared_program_of_ast (read_ast fname)}) fnames in
      build_depend_graph prgms;;    

(* Remember that cycles in the dependency graph do not mean Datalog recursion.
E.g. TABLE(ucst) <- TABLE(ucst) means that a modification (+ or -) of ucst
depends on its current value.*)

  (* For debugging+development before creating real tests *)
  printf "%s\n%!" (string_of_dependencies (files_to_graph ["examples/NIB.flg"; "examples/Mac_Learning.flg"]));;

  (* TODO: use program name to disambiguate relation names *)