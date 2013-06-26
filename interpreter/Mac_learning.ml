open Flowlog;;
open Controller;;

module Mac_learning : PROGRAM = struct
include Flowlog;; 

let learned_vars = [Variable("Sw"); Variable("Pt"); Variable("Mac")];;

let plus_learned = Clause("+learned", packet_vars @ learned_vars,
	[Pos(Equals(Variable("LocSw"), Variable("Sw")));
	Pos(Equals(Variable("DlSrc"), Variable("Mac")));
	Pos(Equals(Variable("LocPt"), Variable("Pt")))]);;

let	plus_learned_relation = Relation("+learned", packet_vars @ learned_vars, [plus_learned]);;

let minus_learned = Clause("-learned", packet_vars @ learned_vars,
	[Pos(Equals(Variable("LocSw"), Variable("Sw")));
	Pos(Equals(Variable("DlSrc"), Variable("Mac")));
	Neg(Equals(Variable("LocPt"), Variable("Pt")))]);;
	
let	minus_learned_relation = Relation("-learned", packet_vars @ learned_vars, [minus_learned]);;

let learned_relation = Relation("learned", learned_vars, []);;

let forward_1 = Clause("forward", packet_vars @ packet_vars_2,
	[Pos(Apply("learned", [Variable("LocSw"); Variable("LocPt2"); Variable("DlDst")]))]);;

let	forward_2 = Clause("forward", packet_vars @ packet_vars_2,
	[Neg(Apply("learned", [Variable("LocSw"); Variable("Any"); Variable("DlDst")]));
	Neg(Equals(Variable("LocPt"), Variable("LocPt2")))]);;
	
let	forward_relation = Relation("forward", packet_vars @ packet_vars_2, [forward_1; forward_2]);;

let program = Program("mac_learning", [plus_learned_relation; minus_learned_relation; learned_relation], forward_relation);;
end

(*module Run = Controller.Make_Controller (Mac_learning);;*)