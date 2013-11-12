(****************************************************************)
(* Most type definitions and a few helpers                      *)
(****************************************************************)

open Printf
open ExtList.List
open NetCore_Types

  type term = 
              | TConst of string 
              | TVar of string 
              | TField of string * string;;  

  type formula = 
              | FTrue 
              | FFalse 
              | FEquals of term * term
              | FNot of formula 
                (* module, relname, args*)
              | FAtom of string * string * term list 
              | FAnd of formula * formula 
              | FOr of formula * formula;;

  type action = 
              | ADelete of string * term list * formula 
              | AInsert of string * term list * formula 
              | ADo of string * term list * formula;;

  type refresh = 
      (* number, units *)
      | RefreshTimeout of int * string
      | RefreshPure
      | RefreshEvery;;

  type assignment = {afield: string; atupvar: string};;      

  type spec_out = 
      | OutForward
      | OutEmit of string
      | OutLoopback
      | OutPrint 
      | OutSend of string * string;;

  type sreactive = 
        (* table name, query name, ip, port, refresh settings *)
      | ReactRemote of string * string * string * string * refresh
        (* out relation name, args, event type name, assignments, spec*)
      | ReactOut of string * string list * string * assignment list * spec_out
        (* incoming event type, trigger relation name*)
      | ReactInc of string * string;;

  type sdecl = 
      | DeclTable of string * string list    
      | DeclRemoteTable of string * string list    
      | DeclInc of string * string   
      | DeclOut of string * string list    
      | DeclEvent of string * string list;;

  type srule = 
       (* onrel, onvar, action*)
      | Rule of string * string * action;;

  type stmt = 
      | SReactive of sreactive 
      | SDecl of sdecl 
      | SRule of srule;;

  type flowlog_ast = 
      | AST of string list * stmt list;;

(*************************************************************)  

  (* Split out a formula by ORs for use with XSB *)
  (* In new semantics, no longer have "on" in clause body. It just gets made an EDB fact. *)
  (* REQUIRE: head, body fmlas atomic or equality *)
  type clause = { orig_rule: srule; 
                  head: formula;
                  body: formula; (* should be always conjunctive *)
                  };;

  type flowlog_program = {  decls: sdecl list; 
                            reacts: sreactive list; 
                            clauses: clause list;
                            (* subset of <clauses> *)
                            can_fully_compile_to_fwd_clauses: clause list; };;

  (* context for values given by decls *)
  module StringMap = Map.Make(String);;
  type event = { typeid: string; values: string StringMap.t};;

  module FmlaMap = Map.Make(struct type t = formula let compare = compare end);;

(*************************************************************)
  let allportsatom = SwitchAction({id with outPort = NetCore_Pattern.All});;

(*************************************************************)
  let string_of_event (notif: event): string =
    notif.typeid^": ["^(String.concat ";" (map (fun (k, v) -> k^":"^v) (StringMap.bindings notif.values)))^"]";;

  (* If verbose flag is not set, prepare for XSB. Otherwise, add extra info for debug. *)
  let string_of_term ?(verbose:bool = false) (t: term): string = 
    match t with
      | TConst(s) -> 
        if verbose then "TConst("^s^")" 
        else (String.lowercase s)
      | TVar(s) ->
        if verbose then "TVar("^s^")"
        else (String.uppercase s)
      | TField(varname, fname) -> 
        if verbose then "TField("^varname^"."^fname^")" 
        else (String.uppercase (varname^"__"^fname));;

  let rec string_of_formula ?(verbose:bool = false) (f: formula): string = 
    match f with
      | FTrue -> "true"
      | FFalse -> "false"
      | FEquals(t1, t2) -> (string_of_term ~verbose:verbose t1) ^ " = "^ (string_of_term ~verbose:verbose t2)
      | FNot(f) ->  "(not "^(string_of_formula ~verbose:verbose f)^")"
      | FAtom("", relname, tlargs) -> 
          relname^"("^(String.concat "," (map (string_of_term ~verbose:verbose) tlargs))^")"
      | FAtom(modname, relname, tlargs) -> 
          modname^"/"^relname^"("^(String.concat "," (map (string_of_term ~verbose:verbose) tlargs))^")"
      | FAnd(f1, f2) -> (string_of_formula ~verbose:verbose f1) ^ ", "^ (string_of_formula ~verbose:verbose f2)
      | FOr(f1, f2) -> (string_of_formula ~verbose:verbose f1) ^ " or "^ (string_of_formula ~verbose:verbose f2)
  
  let action_string outrel argterms fmla: string = 
    let argstring = (String.concat "," (map (string_of_term ~verbose:true) argterms)) in
      outrel^"("^argstring^") WHERE "^(string_of_formula ~verbose:true fmla);;

  let string_of_rule (r: srule): string =
    match r with 
      | Rule(trigrel, trigvar, act) -> 
        match act with 
          | ADelete(outrel, argterms, fmla) ->  
            "ON "^trigrel^"("^trigvar^"): DELETE "^(action_string outrel argterms fmla);                         
          | AInsert(outrel, argterms, fmla) ->
            "ON "^trigrel^"("^trigvar^"): INSERT "^(action_string outrel argterms fmla);
          | ADo(outrel, argterms, fmla) ->  
            "ON "^trigrel^"("^trigvar^"): DO "^(action_string outrel argterms fmla);;

  let string_of_declaration (d: sdecl): string =
    match d with 
      | DeclTable(tname, argtypes) -> "TABLE "^tname^" "^(String.concat "," argtypes);
      | DeclRemoteTable(tname, argtypes) -> "REMOTE TABLE "^tname^" "^(String.concat "," argtypes);
      | DeclInc(tname, argtype) -> "INCOMING "^tname^" "^argtype;
      | DeclOut(tname, argtypes) -> "OUTGOING "^tname^" "^(String.concat "," argtypes);
      | DeclEvent(evname, argnames) -> "EVENT "^evname^" "^(String.concat "," argnames);;

  let string_of_outspec (spec: spec_out) =
    match spec with 
      | OutForward -> "forward"      
      | OutEmit(typ) -> "emit["^typ^"]"
      | OutPrint -> "print"
      | OutLoopback -> "loopback"
      | OutSend(ip, pt) -> ip^":"^pt;;  

  let string_of_reactive (r: sreactive): string =
    match r with       
      | ReactRemote(tblname, qname, ip, port, refresh) ->
        tblname^" (remote) = "^qname^" @ "^ip^" "^port;
      | ReactOut(outrel, args, evtype, assignments, spec) ->
        outrel^"("^(String.concat "," args)^") (output rel) = "^evtype^" @ "^(string_of_outspec spec);
      | ReactInc(evtype, relname) -> 
        relname^" (input rel) "^evtype;;
  
  let string_of_stmt (stmt: stmt): string = 
    match stmt with 
      | SReactive(rstmt) -> (string_of_reactive rstmt);
      | SDecl(dstmt) -> (string_of_declaration dstmt);
      | SRule(rstmt) -> (string_of_rule rstmt);;

  let pretty_print_ast (ast: flowlog_ast): unit =
    match ast with
      | AST(includes, stmts) ->
        iter (fun inc -> printf "INCLUDE %s;\n%!" inc) includes;
        iter (fun stmt -> printf "%s\n%!" (string_of_stmt stmt)) stmts;;

  let string_of_clause ?(verbose: bool = false) (cl: clause): string =
    "CLAUSE: "^(string_of_formula ~verbose:verbose cl.head)^" :- "^(string_of_formula ~verbose:verbose cl.body)^"\n"^
    (if verbose then "FROM RULE: "^(string_of_rule cl.orig_rule) else "");;

(*************************************************************)


(* For every non-negated equality that has one TVar in it
   that is NOT in the exempt list, produces a tuple for substitution.
   (Exempt list is so that vars in the head of a clause won't get substituted out) *)    
let rec gather_nonneg_equalities_involving_vars 
  ?(exempt: term list = []) (f: formula) (neg: bool): (term * term) list =
  match f with 
        | FTrue -> []
        | FFalse -> []
        (* Make sure to use WHEN here, not a condition after ->. Suppose exempt=[y] and y=x. Want 2nd option to apply. *)
        | FEquals((TVar(_) as thevar), t) 
          when (not neg) && (not (thevar = t)) && (not (mem thevar exempt)) -> 
            [(thevar, t)] 
        | FEquals(t, (TVar(_) as thevar)) 
          when (not neg) && (not (thevar = t)) && (not (mem thevar exempt)) -> 
            [(thevar, t)]
        | FEquals(_, _) -> []
        | FAtom(modstr, relstr, argterms) -> []
        | FOr(f1, f2) -> 
            unique ((gather_nonneg_equalities_involving_vars ~exempt:exempt f1 neg) @ 
                    (gather_nonneg_equalities_involving_vars ~exempt:exempt f2 neg))
        | FAnd(f1, f2) -> 
            unique ((gather_nonneg_equalities_involving_vars ~exempt:exempt f1 neg) @ 
                    (gather_nonneg_equalities_involving_vars ~exempt:exempt f2 neg))
        | FNot(f2) -> 
            (gather_nonneg_equalities_involving_vars ~exempt:exempt f2 (not neg));; 

exception SubstitutionLedToInconsistency of formula;;

(* If about to substitute in something like 5=7, abort because the whole conjunction is unsatisfiable *)
let equals_if_consistent (t1: term) (t2: term): formula =
  match (t1, t2) with
    | (TConst(str1), TConst(str2)) when str1 <> str2 -> raise (SubstitutionLedToInconsistency((FEquals(t1, t2))))
    | _ -> FEquals(t1, t2);;

(* f[v -> t] 
   Substitutions of variables apply to fields of that variable, too. *)
let rec substitute_term (f: formula) (v: term) (t: term): formula = 
  let substitute_term_result (curr: term): term =
    match curr, v, t with 
      | x, y, _ when x = y -> t
      (* curr is a field of v, replace with field of t *)
      | TField(x, fx), TVar(y), TVar(z) when x = y -> TField(z, fx)
      | _ -> curr in

    match f with
        | FTrue -> f
        | FFalse -> f
        | FEquals(t1, t2) ->
          let st1 = substitute_term_result t1 in
          let st2 = substitute_term_result t2 in
          (* Remove fmlas which will be "x=x"; avoids inf. loop. *)
          if st1 = st2 then FTrue
          else equals_if_consistent st1 st2           
        | FAtom(modstr, relstr, argterms) -> 
          let newargterms = map (fun arg -> substitute_term_result arg) argterms in
            FAtom(modstr, relstr, newargterms)
        | FOr(f1, f2) ->         
            let subs1 = substitute_term f1 v t in
            let subs2 = substitute_term f2 v t in
            if subs1 = FFalse then subs2 
            else if subs2 = FFalse then subs1            
            else FOr(subs1, subs2)       
        | FAnd(f1, f2) ->
            (* remove superfluous FTrues/FFalses *) 
            let subs1 = substitute_term f1 v t in
            let subs2 = substitute_term f2 v t in
            if subs1 = FTrue then subs2 
            else if subs2 = FTrue then subs1            
            else FAnd(subs1, subs2)       
        | FNot(f2) -> 
            FNot(substitute_term f2 v t);;

let substitute_terms (f: formula) (subs: (term * term) list): formula = 
  fold_left (fun fm (v, t) -> substitute_term fm v t) f subs;;

(* assume a clause body. exempt gives the terms that are in the head, and thus need to not be removed *)
let rec minimize_variables ?(exempt: term list = []) (f: formula): formula = 
  (* OPTIMIZATION: don't need to do gathering step repeatedly: *)
  let var_equals_fmlas = gather_nonneg_equalities_involving_vars ~exempt:exempt f false in
    (*printf "at fmla = %s\n%!" (string_of_formula f);        
    iter (fun pr -> let (t1, t2) = pr in (printf "pair: %s, %s\n%!" 
            (string_of_term t1) (string_of_term t2))) var_equals_fmlas;    *)

    if length var_equals_fmlas < 1 then
      f
    else 
    (* select equalities involving constants first, so we don't lose their context *)
      let constpairs = filter (function | (TVar(_), TConst(_)) -> true | _ -> false) var_equals_fmlas in 
      let (x, t) = if length constpairs > 0 then hd constpairs else hd var_equals_fmlas in  

      (* subst process will discover inconsistency due to multiple vals e.g. x=7, x=9, and throw exception *)
      try
        let newf = (substitute_term f x t) in
          (*printf "will subs out %s to %s. New is: %s.\n%!" (string_of_term x) (string_of_term t) (string_of_formula newf);*)
          minimize_variables ~exempt:exempt newf
        with SubstitutionLedToInconsistency(_) -> FFalse;;

let add_conjunct_to_action (act: action) (f: formula) =  
  match act with 
    | _ when f = FTrue -> act
    | ADelete(a, b, fmla) -> ADelete(a, b, FAnd(f, fmla)) 
    | AInsert(a, b, fmla) -> AInsert(a, b, FAnd(f, fmla))
    | ADo(a, b, fmla) -> ADo(a, b, FAnd(f, fmla));;

(************************************************************************************)
(* BUILT-IN CONSTANTS, MAGIC-NUMBERS, EVENTS, REACTIVE DEFINITIONS, ETC.            *)
(*   If adding a new packet type, new built-in definition, etc. do so here.         *)
(************************************************************************************)

(* Note: all program text is lowercased by parser *)

(* These are prepended to relation names when we pass insert/delete rules to Prolog *)
let plus_prefix = "plus";;
let minus_prefix = "minus";;
(* Avoid using strings for hard-coded type names and relation names. 
   Use these definitions instead. *)
let packet_in_relname = "packet_in";;
let switch_reg_relname = "switch_port_in";;
let switch_down_relname = "switch_down";;
let startup_relname = "startup";;

(*************************************************************)
(* Generalized notion of a flavor of packet, like ARP or ICMP. 
   Avoids ugly multiple lists of "built-ins" where we can forget to add packet types, etc.
   label = string which is prepended to "_packet_in" and appended to "emit_" to arrive at relations.
   superflavor = immediate supertype. If None, means that this is a direct subtype of an ethernet packet.
   condition = a function that, given a variable name, constructs a formula that describes that it means 
               to be a member of this flavor. E.g., to be an ip packet, you must have your dltyp field = 0x800.
   fields = New fields added by this flavor. Must not be present in any superflavors.
 *)
type packet_flavor = { label: string;                        superflavor: string option; 
                       build_condition: (string -> formula); fields: string list};;

let packet_flavors =[
   {label="arp"; superflavor=None;  
    build_condition=(fun vname -> FEquals(TField(vname, "dltyp"), TConst("0x0806"))); 
    fields=["arp_op";"arp_spa";"arp_sha";"arp_tpa";"arp_tha"]};
   
   {label="ip"; superflavor=None;  
    build_condition=(fun vname -> FEquals(TField(vname, "dltyp"), TConst("0x0800"))); 
    fields=["ipsrc"; "ipdest"; "ipproto"]};  (* missing: frag, tos, chksum, ident, ...*) 

  (* {label="lldp"; superflavor=None;  
    build_condition=(fun vname -> FEquals(TField(vname, "dltyp"), TConst("0x88CC"))); 
    fields=["omgwtfbbq"]}; *)
   
   {label="tcp"; superflavor=Some "ip";  
    build_condition=(fun vname -> FAnd(FEquals(TField(vname, "dltyp"), TConst("0x0800")), 
                                 FEquals(TField(vname, "nwproto"), TConst("0x6")))); 
    fields=["tpsrc"; "tpdst"]}; (* expect we'll want flags eventually *)
   
   {label="udp"; superflavor=Some "ip";  
    build_condition=(fun vname -> FAnd(FEquals(TField(vname, "dltyp"), TConst("0x0800")), 
                                 FEquals(TField(vname, "nwproto"), TConst("0x11")))); 
    fields=["tpsrc"; "tpdst"]};

  (* {label="igmp"; superflavor=Some "ip";  
    build_condition=(fun vname -> FAnd(FEquals(TField(vname, "dltyp"), TConst("0x0800")), 
                                 FEquals(TField(vname, "nwproto"), TConst("0x2")))); 
    fields=["omgwtfbbq"]};*)

   {label="icmp"; superflavor=Some "ip";  
    build_condition=(fun vname -> FAnd(FEquals(TField(vname, "dltyp"), TConst("0x0800")), 
                                 FEquals(TField(vname, "nwproto"), TConst("0x1")))); 
    fields=["icmp_type"; "icmp_code"]}; (* checksum will need calculation in runtime? *)
  ];;

(**********************************************)

(* Fields in a base packet *)
let packet_fields = ["locsw";"locpt";"dlsrc";"dldst";"dltyp"];;

(* Fields that OpenFlow permits modification of. *)
let legal_to_modify_packet_fields = ["locpt";"dlsrc";"dldst";"dltyp";"nwsrc";"nwdst"];;

let swpt_fields = ["sw";"pt"];;
let swdown_fields = ["sw"];;

(**********************************************)

(* Some declarations and reactive definitions are built in. E.g., packet_in. *)

let flavor_to_typename (flav: packet_flavor): string = flav.label^"_packet";;
let flavor_to_inrelname (flav: packet_flavor): string = flav.label^"_packet_in";;
let flavor_to_emitrelname (flav: packet_flavor): string = "emit_"^flav.label;;

let create_id_assign (k: string): assignment = {afield=k; atupvar=k};;
let build_flavor_decls (flav: packet_flavor): sdecl list =   
  [DeclInc(flavor_to_inrelname flav, flavor_to_typename flav);
   DeclEvent(flavor_to_typename flav, flav.fields); 
   DeclOut(flavor_to_emitrelname flav, [flavor_to_typename flav])];;
let build_flavor_reacts (flav: packet_flavor): sreactive list =   
  [ReactInc(flavor_to_typename flav, flavor_to_inrelname flav); 
   ReactOut(flavor_to_emitrelname flav, flav.fields, flavor_to_typename flav, 
            map create_id_assign flav.fields, OutEmit(flavor_to_typename flav))];;

let built_in_decls = [DeclInc(packet_in_relname, "packet");                       
                      DeclInc(switch_reg_relname, "switch_port"); 
                      DeclInc(switch_down_relname, "switch_down");
                      DeclInc(startup_relname, "startup");                      
                      DeclOut("forward", ["packet"]);
                      DeclOut("emit", ["packet"]);                      
                      DeclEvent("packet", packet_fields);
                      DeclEvent("startup", []);
                      DeclEvent("switch_port", swpt_fields);                      
                      DeclEvent("switch_down", swdown_fields)]
                    @ flatten (map build_flavor_decls packet_flavors);;

let built_in_reacts = [ ReactInc("packet", packet_in_relname);                         
                        ReactInc("switch_port", switch_reg_relname); 
                        ReactInc("switch_down", switch_down_relname); 
                        ReactInc("startup", startup_relname);                                               
                        ReactOut("forward", packet_fields, "packet", map create_id_assign packet_fields, OutForward);
                        ReactOut("emit", packet_fields, "packet", map create_id_assign packet_fields, OutEmit("packet"));                        
                      ] @ flatten (map build_flavor_reacts packet_flavors);;

(* These output relations have a "condensed" argument. That is, they are unary, 
   with a packet as the argument. Should only be done for certain built-ins. *)
let built_in_condensed_outrels = ["forward"; "emit"] @ map (fun flav -> flavor_to_emitrelname flav) packet_flavors;;

(* All packet types must go here; 
   these are the tables that flag a rule as being "packet-triggered".*)
let built_in_packet_input_tables = [packet_in_relname] @ map (fun flav -> flavor_to_inrelname flav) packet_flavors;;

(* For efficiency *)
let map_from_typename_to_flavor: packet_flavor StringMap.t = 
  fold_left (fun acc flav -> StringMap.add (flavor_to_typename flav) flav acc) StringMap.empty packet_flavors;;
let map_from_relname_to_flavor: packet_flavor StringMap.t = 
  fold_left (fun acc flav -> StringMap.add (flavor_to_emitrelname flav) flav
                                           (StringMap.add (flavor_to_inrelname flav) flav acc))
            StringMap.empty packet_flavors;;

(*************************************************************)

(* If adding a new packet type, make sure to include self and all supertypes here. *)
(* E.g. arp_packet always fires packet also. *)
let rec built_in_supertypes (typename: string): string list = 
  try
    let flav = StringMap.find typename map_from_typename_to_flavor in
    match flav.superflavor with
      | Some superflav -> typename::(built_in_supertypes superflav)
      | None -> [typename]
  with Not_found -> [typename];;
    
(*************************************************************)

(* We don't yet have access to vname until we have a concrete rule *)
(* Remember: field names must be lowercase *)
(* both INCOMING and OUTGOING relations can call this. *)
let built_in_where_for_variable (vart: term) (relname: string): formula = 
  let vname = (match vart with | TVar(x) -> x | _ -> failwith "built_in_where_for_vname") in
  try
    let flav = StringMap.find relname map_from_relname_to_flavor in
      (flav.build_condition vname)
  with Not_found -> FTrue ;;

(*************************************************************)
