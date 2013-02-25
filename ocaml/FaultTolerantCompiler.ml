open MessagesDef
open OpenFlow0x04Parser
open OpenFlow0x04Types
open PatternImplDef


(* Egh. Assuming each action list only has a single port. Otherwise we
   need to use watch groups instead of a watch port and that's just more
   messy crap *)

let ofpp_any = Int32.of_int (-1)
(* Not even specified in OF 1.3. It's like they're not even trying... *)
let ofpg_any = Int32.of_int (-1)

let rec watchport acts = match acts with
  | NetCoreEval.Forward (modif, MessagesDef.PhysicalPort pid) :: acts -> (Int32.of_int pid)
  | _ :: acts -> watchport acts
  | _ -> ofpp_any

(* OFPG_ANY *)
let insert_groups = List.mapi (fun idx (pat,(a,b)) -> (pat, (Int32.of_int idx, [(0, (watchport a), a); (0, (watchport b), b)])))

let blast_inport' pat : pattern =
    { ptrnDlSrc = pat.ptrnDlSrc; ptrnDlDst = pat.ptrnDlDst;
      ptrnDlType = pat.ptrnDlType; ptrnDlVlan =
      pat.ptrnDlVlan; ptrnDlVlanPcp = pat.ptrnDlVlanPcp; ptrnNwSrc =
      pat.ptrnNwSrc; ptrnNwDst = pat.ptrnNwDst; ptrnNwProto =
      pat.ptrnNwProto; ptrnNwTos = pat.ptrnNwTos;
      ptrnTpSrc = pat.ptrnTpSrc; ptrnTpDst = pat.ptrnTpDst; ptrnInPort = Wildcard.WildcardAll }

let blast_inport = List.map (fun (pat, acts) -> (blast_inport' pat, acts))

let rec compile_primary_backup primary backup (sw : switchId) =
    let pr_tbl = NetCoreCompiler.compile_opt primary sw in
    let bk_tbl = NetCoreCompiler.compile_opt backup sw in
    let merge (a : pattern) (b : pattern) = (a,b) in
    let overlap = insert_groups (Classifier.inter merge pr_tbl (blast_inport bk_tbl)) in
    let groups = List.map snd overlap in
    let inter = List.map (fun (pat, (a,b)) -> (pat, [NetCoreEval13.Group a])) overlap in
    let foo = (NetCoreCompiler.compile_opt (NetCoreEval.PoUnion (primary, backup)) sw) in
    (inter @ foo, groups)
    
