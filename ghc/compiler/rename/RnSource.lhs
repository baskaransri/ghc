%
% (c) The GRASP/AQUA Project, Glasgow University, 1992-1996
%
\section[RnSource]{Main pass of renamer}

\begin{code}
#include "HsVersions.h"

module RnSource ( rnSource, rnTyDecl, rnClassDecl, rnInstDecl, rnPolyType ) where

IMP_Ubiq()
IMPORT_DELOOPER(RnLoop)		-- *check* the RnPass/RnExpr/RnBinds loop-breaking

import HsSyn
import HsPragmas
import RdrHsSyn
import RnHsSyn
import RnMonad
import RnBinds		( rnTopBinds, rnMethodBinds )
import RnUtils		( getLocalsFromRnEnv, lookupGlobalRnEnv, lubExportFlag )

import Bag		( emptyBag, unitBag, consBag, unionManyBags, unionBags, listToBag, bagToList )
import Class		( derivableClassKeys )
import CmdLineOpts	( opt_CompilingGhcInternals )
import ErrUtils		( addErrLoc, addShortErrLocLine, addShortWarnLocLine )
import FiniteMap	( emptyFM, lookupFM, addListToFM_C )
import Id		( GenId{-instance NamedThing-} )
import ListSetOps	( unionLists, minusList )
import Maybes		( maybeToBool, catMaybes )
import Name		( isLocallyDefined, isLexVarId, getLocalName, ExportFlag(..), 
			  nameImportFlag, RdrName, pprNonSym, Name )
import Outputable	-- ToDo:rm
import PprStyle 	-- ToDo:rm 
import Pretty
import SrcLoc		( SrcLoc )
import TyCon		( tyConDataCons, TyCon{-instance NamedThing-} )
import Unique		( Unique )
import UniqFM		( emptyUFM, addListToUFM_C, listToUFM, plusUFM, lookupUFM, eltsUFM )
import UniqSet		( SYN_IE(UniqSet) )
import Util		( isIn, isn'tIn, thenCmp, sortLt, removeDups, mapAndUnzip3, cmpPString,
			  panic, assertPanic, pprTrace{-ToDo:rm-} )
\end{code}

rnSource `renames' the source module and export list.
It simultaneously performs dependency analysis and precedence parsing.
It also does the following error checks:
\begin{enumerate}
\item
Checks that tyvars are used properly. This includes checking
for undefined tyvars, and tyvars in contexts that are ambiguous.
\item
Checks that all variable occurences are defined.
\item 
Checks the (..) etc constraints in the export list.
\end{enumerate}


\begin{code}
rnSource :: [Module]			-- imported modules
	 -> Bag (Module,RnName)		-- unqualified imports from module
	 -> Bag RenamedFixityDecl	-- fixity info for imported names
	 -> RdrNameHsModule
	 -> RnM s (RenamedHsModule,
		   Name -> ExportFlag,		-- export info
		   Bag (RnName, RdrName))	-- occurrence info

rnSource imp_mods unqual_imps imp_fixes
	(HsModule mod version exports _ fixes
	   ty_decls specdata_sigs class_decls
	   inst_decls specinst_sigs defaults
	   binds _ src_loc)

  = pushSrcLocRn src_loc $

    rnExports (mod:imp_mods) unqual_imps exports	`thenRn` \ exported_fn ->
    rnFixes fixes					`thenRn` \ src_fixes ->
    let
	all_fixes     = src_fixes ++ bagToList imp_fixes
	all_fixes_fm  = listToUFM (map pair_name all_fixes)

	pair_name inf = (fixDeclName inf, inf)
    in
    setExtraRn all_fixes_fm $

    mapRn rnTyDecl	ty_decls	`thenRn` \ new_ty_decls ->
    mapRn rnSpecDataSig specdata_sigs	`thenRn` \ new_specdata_sigs ->
    mapRn rnClassDecl	class_decls	`thenRn` \ new_class_decls ->
    mapRn rnInstDecl	inst_decls	`thenRn` \ new_inst_decls ->
    mapRn rnSpecInstSig specinst_sigs   `thenRn` \ new_specinst_sigs ->
    rnDefaultDecl	defaults	`thenRn` \ new_defaults ->
    rnTopBinds binds			`thenRn` \ new_binds ->

    getOccurrenceUpRn			`thenRn` \ occ_info ->

    returnRn (
	      HsModule mod version
		trashed_exports trashed_imports	all_fixes
		new_ty_decls new_specdata_sigs new_class_decls
		new_inst_decls new_specinst_sigs new_defaults
		new_binds [] src_loc,
	      exported_fn,
	      occ_info
	     )
  where
    trashed_exports = {-trace "rnSource:trashed_exports"-} Nothing
    trashed_imports = {-trace "rnSource:trashed_imports"-} []
\end{code}


%*********************************************************
%*							*
\subsection{Export list}
%*							*
%*********************************************************

\begin{code}
rnExports :: [Module]
	  -> Bag (Module,RnName)
	  -> Maybe [RdrNameIE]
	  -> RnM s (Name -> ExportFlag)

rnExports mods unqual_imps Nothing
  = returnRn (\n -> if isLocallyDefined n then ExportAll else NotExported)

rnExports mods unqual_imps (Just exps)
  = getModuleRn			   `thenRn` \ this_mod ->
    getRnEnv			   `thenRn` \ rn_env ->
    mapAndUnzipRn (rnIE mods) exps `thenRn` \ (mod_maybes, exp_bags) ->
    let 
	(tc_bags, val_bags) = unzip exp_bags
	tc_names  = bagToList (unionManyBags tc_bags)
        val_names = bagToList (unionManyBags val_bags)
        exp_mods  = catMaybes mod_maybes

	-- Warn for duplicate names and modules
	(_, dup_tc_names)  = removeDups cmp_fst tc_names
	(_, dup_val_names) = removeDups cmp_fst val_names
	cmp_fst (x,_) (y,_) = x `cmp` y

	(uniq_mods, dup_mods) = removeDups cmpPString exp_mods
	(expmods_this, expmods_imps) = partition (== this_mod) uniq_mods

	-- Get names for module This_Mod export
	(this_tcs, this_vals)
	  = if null expmods_this 
	    then ([], [])
	    else getLocalsFromRnEnv rn_env

	-- Get names for exported imported modules
	(mod_tcs, mod_vals, empty_mods)
	  = case mapAndUnzip3 get_mod_names expmods_imps of
	      (tcs, vals, emptys) -> (concat tcs, concat vals, catMaybes emptys)
		
	(unqual_tcs, unqual_vals) = partition (isRnTyConOrClass.snd) (bagToList unqual_imps)

        get_mod_names mod
	  = (tcs, vals, empty_mod)
          where
            tcs  = [(getName rn, nameImportFlag (getName rn))
		   | (mod',rn) <- unqual_tcs, mod == mod']
            vals = [(getName rn, nameImportFlag (getName rn))
		   | (mod',rn) <- unqual_vals, mod == mod']
	    empty_mod = if null tcs && null vals
			then Just mod
			else Nothing
							    
	-- Build finite map of exported names to export flag
	tc_map0  = addListToUFM_C lub_expflag emptyUFM (map pair_fst tc_names)
	tc_map1  = addListToUFM_C lub_expflag tc_map0  (map pair_fst mod_tcs)
	tc_map   = addListToUFM_C lub_expflag tc_map1  (map (pair_fst.exp_all) this_tcs)
	
        val_map0 = addListToUFM_C lub_expflag emptyUFM (map pair_fst val_names)
        val_map1 = addListToUFM_C lub_expflag val_map0 (map pair_fst mod_vals)
        val_map  = addListToUFM_C lub_expflag val_map1 (map (pair_fst.exp_all) this_vals)

	pair_fst pr@(n,_) = (n,pr)
	exp_all rn = (getName rn, ExportAll)
	lub_expflag (n, flag1) (_, flag2) = (n, lubExportFlag flag1 flag2)

	-- Check for exporting of duplicate local names
	tc_locals  = [(getLocalName n, n) | (n,_) <- eltsUFM tc_map]
	val_locals = [(getLocalName n, n) | (n,_) <- eltsUFM val_map]
	(_, dup_tc_locals)  = removeDups cmp_local tc_locals
	(_, dup_val_locals) = removeDups cmp_local val_locals
	cmp_local (x,_) (y,_) = x `cmpPString` y

	-- Build export flag function
	final_exp_map = plusUFM tc_map val_map
	exp_fn n = case lookupUFM final_exp_map n of
		      Nothing       -> NotExported
		      Just (_,flag) -> flag
    in
    getSrcLocRn 							`thenRn` \ src_loc ->
    mapRn (addWarnRn . dupNameExportWarn  src_loc) dup_tc_names 	`thenRn_`
    mapRn (addWarnRn . dupNameExportWarn  src_loc) dup_val_names 	`thenRn_`
    mapRn (addWarnRn . dupModExportWarn   src_loc) dup_mods 		`thenRn_`
    mapRn (addWarnRn . emptyModExportWarn src_loc) empty_mods 		`thenRn_`
    mapRn (addErrRn  . dupLocalsExportErr src_loc) dup_tc_locals	`thenRn_`
    mapRn (addErrRn  . dupLocalsExportErr src_loc) dup_val_locals	`thenRn_`
    returnRn exp_fn


rnIE mods (IEVar name)
  = lookupValue name	`thenRn` \ rn ->
    checkIEVar rn	`thenRn` \ exps ->
    returnRn (Nothing, exps)
  where
    checkIEVar (RnName    n)      = returnRn (emptyBag, unitBag (n,ExportAll))
    checkIEVar (WiredInId i)	  = returnRn (emptyBag, unitBag (getName i, ExportAll))
    checkIEVar rn@(RnClassOp _ _) = getSrcLocRn `thenRn` \ src_loc ->
			            failButContinueRn (emptyBag, emptyBag) (classOpExportErr rn src_loc)
    checkIEVar rn@(RnField _ _)	  = getSrcLocRn `thenRn` \ src_loc ->
			            failButContinueRn (emptyBag, emptyBag) (fieldExportErr rn src_loc)
    checkIEVar rn		  = --pprTrace "rnIE:IEVar:panic? ToDo?:" (ppr PprDebug rn) $
				    returnRn (emptyBag, emptyBag)

rnIE mods (IEThingAbs name)
  = lookupTyConOrClass name	`thenRn` \ rn ->
    checkIEAbs rn		`thenRn` \ exps ->
    returnRn (Nothing, exps)
  where
    checkIEAbs (RnSyn n)      	= returnRn (unitBag (n,ExportAbs), emptyBag)
    checkIEAbs (RnData n _ _) 	= returnRn (unitBag (n,ExportAbs), emptyBag)
    checkIEAbs (RnClass n _)  	= returnRn (unitBag (n,ExportAbs), emptyBag)
    checkIEAbs (WiredInTyCon t) = returnRn (unitBag (getName t,ExportAbs), emptyBag)
    checkIEAbs rn               = --pprTrace "rnIE:IEAbs:panic? ToDo?:" (ppr PprDebug rn) $
				  returnRn (emptyBag, emptyBag)

rnIE mods (IEThingAll name)
  = lookupTyConOrClass name	`thenRn` \ rn ->
    checkIEAll rn		`thenRn` \ exps ->
    checkImportAll rn           `thenRn_`
    returnRn (Nothing, exps)
  where
    checkIEAll (RnData n cons fields)
      = returnRn (unitBag (exp_all n),
	    listToBag (map exp_all cons) `unionBags` listToBag (map exp_all fields))

    checkIEAll (WiredInTyCon t)
      = returnRn (unitBag (exp_all (getName t)), listToBag (map exp_all cons))
      where
	cons   = map getName (tyConDataCons t)

    checkIEAll (RnClass n ops)
      = returnRn (unitBag (exp_all n), listToBag (map exp_all ops))
    checkIEAll rn@(RnSyn n)
      = getSrcLocRn `thenRn` \ src_loc ->
	warnAndContinueRn (unitBag (n, ExportAbs), emptyBag)
			  (synAllExportErr False{-warning-} rn src_loc)

    checkIEAll rn = pprTrace "rnIE:IEAll:panic? ToDo?:" (ppr PprDebug rn) $
		    returnRn (emptyBag, emptyBag)

    exp_all n = (n, ExportAll)

rnIE mods (IEThingWith name names)
  = lookupTyConOrClass name	`thenRn` \ rn ->
    mapRn lookupValue names	`thenRn` \ rns ->
    checkIEWith rn rns		`thenRn` \ exps ->
    checkImportAll rn    	`thenRn_`
    returnRn (Nothing, exps)
  where
    checkIEWith rn@(RnData n cons fields) rns
	| same_names (cons++fields) rns
	= returnRn (unitBag (exp_all n), listToBag (map exp_all cons)
					   `unionBags`
					 listToBag (map exp_all fields))
	| otherwise
	= rnWithErr "constructors (and fields)" rn (cons++fields) rns 
    checkIEWith rn@(RnClass n ops) rns
	| same_names ops rns
	= returnRn (unitBag (exp_all n), listToBag (map exp_all ops))
	| otherwise
	= rnWithErr "class ops" rn ops rns
    checkIEWith rn@(RnSyn _) rns
	= getSrcLocRn `thenRn` \ src_loc ->
	  failButContinueRn (emptyBag, emptyBag) (synAllExportErr True{-error-} rn src_loc)
    checkIEWith (WiredInTyCon _) rns = panic "RnSource.rnIE:checkIEWith:WiredInTyCon:ToDo (boring)"
    checkIEWith rn rns
	= pprTrace "rnIE:IEWith:panic? ToDo?:" (ppr PprDebug rn) $
	  returnRn (emptyBag, emptyBag)

    exp_all n = (n, ExportAll)

    same_names has rns
      = all (not.isRnUnbound) rns &&
	sortLt (<) (map uniqueOf has) == sortLt (<) (map uniqueOf rns)

    rnWithErr str rn has rns
      = getSrcLocRn `thenRn` \ src_loc ->
	failButContinueRn (emptyBag, emptyBag) (withExportErr str rn has rns src_loc)

rnIE mods (IEModuleContents mod)
  | isIn "rnIE:IEModule" mod mods
  = returnRn (Just mod, (emptyBag, emptyBag))
  | otherwise
  = getSrcLocRn `thenRn` \ src_loc ->
    failButContinueRn (Nothing, (emptyBag, emptyBag)) (badModExportErr mod src_loc)


checkImportAll rn 
  = case nameImportFlag (getName rn) of
      ExportAll -> returnRn ()
      exp	-> getSrcLocRn `thenRn` \ src_loc ->
		   addErrRn (importAllErr rn src_loc)
\end{code}

%*********************************************************
%*							*
\subsection{Type declarations}
%*							*
%*********************************************************

@rnTyDecl@ uses the `global name function' to create a new type
declaration in which local names have been replaced by their original
names, reporting any unknown names.

Renaming type variables is a pain. Because they now contain uniques,
it is necessary to pass in an association list which maps a parsed
tyvar to its Name representation. In some cases (type signatures of
values), it is even necessary to go over the type first in order to
get the set of tyvars used by it, make an assoc list, and then go over
it again to rename the tyvars! However, we can also do some scoping
checks at the same time.

\begin{code}
rnTyDecl :: RdrNameTyDecl -> RnM_Fixes s RenamedTyDecl

rnTyDecl (TyData context tycon tyvars condecls derivings pragmas src_loc)
  = pushSrcLocRn src_loc $
    lookupTyCon tycon		       `thenRn` \ tycon' ->
    mkTyVarNamesEnv src_loc tyvars     `thenRn` \ (tv_env, tyvars') ->
    rnContext tv_env src_loc context   `thenRn` \ context' ->
    rnConDecls tv_env condecls	       `thenRn` \ condecls' ->
    rn_derivs tycon' src_loc derivings `thenRn` \ derivings' ->
    ASSERT(isNoDataPragmas pragmas)
    returnRn (TyData context' tycon' tyvars' condecls' derivings' noDataPragmas src_loc)

rnTyDecl (TyNew context tycon tyvars condecl derivings pragmas src_loc)
  = pushSrcLocRn src_loc $
    lookupTyCon tycon		      `thenRn` \ tycon' ->
    mkTyVarNamesEnv src_loc tyvars    `thenRn` \ (tv_env, tyvars') ->
    rnContext tv_env src_loc context  `thenRn` \ context' ->
    rnConDecls tv_env condecl	      `thenRn` \ condecl' ->
    rn_derivs tycon' src_loc derivings `thenRn` \ derivings' ->
    ASSERT(isNoDataPragmas pragmas)
    returnRn (TyNew context' tycon' tyvars' condecl' derivings' noDataPragmas src_loc)

rnTyDecl (TySynonym name tyvars ty src_loc)
  = pushSrcLocRn src_loc $
    lookupTyCon name		    `thenRn` \ name' ->
    mkTyVarNamesEnv src_loc tyvars  `thenRn` \ (tv_env, tyvars') ->
    rnMonoType tv_env ty	    `thenRn` \ ty' ->
    returnRn (TySynonym name' tyvars' ty' src_loc)

rn_derivs tycon2 locn Nothing -- derivs not specified
  = returnRn Nothing

rn_derivs tycon2 locn (Just ds)
  = mapRn (rn_deriv tycon2 locn) ds `thenRn` \ derivs ->
    returnRn (Just derivs)
  where
    rn_deriv tycon2 locn clas
      = lookupClass clas	    `thenRn` \ clas_name ->
	addErrIfRn (uniqueOf clas_name `not_elem` derivableClassKeys)
		   (derivingNonStdClassErr clas_name locn)
				    `thenRn_`
	returnRn clas_name
      where
	not_elem = isn'tIn "rn_deriv"
\end{code}

@rnConDecls@ uses the `global name function' to create a new
constructor in which local names have been replaced by their original
names, reporting any unknown names.

\begin{code}
rnConDecls :: TyVarNamesEnv
	   -> [RdrNameConDecl]
	   -> RnM_Fixes s [RenamedConDecl]

rnConDecls tv_env con_decls
  = mapRn rn_decl con_decls
  where
    rn_decl (ConDecl name tys src_loc)
      = pushSrcLocRn src_loc $
	lookupConstr name	`thenRn` \ new_name ->
	mapRn rn_bang_ty tys	`thenRn` \ new_tys  ->
	returnRn (ConDecl new_name new_tys src_loc)

    rn_decl (ConOpDecl ty1 op ty2 src_loc)
      = pushSrcLocRn src_loc $
	lookupConstr op		`thenRn` \ new_op  ->
	rn_bang_ty ty1  	`thenRn` \ new_ty1 ->
	rn_bang_ty ty2  	`thenRn` \ new_ty2 ->
	returnRn (ConOpDecl new_ty1 new_op new_ty2 src_loc)

    rn_decl (NewConDecl name ty src_loc)
      = pushSrcLocRn src_loc $
	lookupConstr name	`thenRn` \ new_name ->
	rn_mono_ty ty		`thenRn` \ new_ty  ->
	returnRn (NewConDecl new_name new_ty src_loc)

    rn_decl (RecConDecl name fields src_loc)
      = pushSrcLocRn src_loc $
	lookupConstr name	`thenRn` \ new_name ->
	mapRn rn_field fields	`thenRn` \ new_fields ->
	returnRn (RecConDecl new_name new_fields src_loc)

    rn_field (names, ty)
      = mapRn lookupField names `thenRn` \ new_names ->
	rn_bang_ty ty		`thenRn` \ new_ty ->
	returnRn (new_names, new_ty) 

    rn_mono_ty = rnMonoType tv_env
    rn_poly_ty = rnPolyType tv_env

    rn_bang_ty (Banged ty)
      = rn_poly_ty ty `thenRn` \ new_ty ->
	returnRn (Banged new_ty)
    rn_bang_ty (Unbanged ty)
      = rn_poly_ty ty `thenRn` \ new_ty ->
	returnRn (Unbanged new_ty)
\end{code}

%*********************************************************
%*							 *
\subsection{SPECIALIZE data pragmas}
%*							 *
%*********************************************************

\begin{code}
rnSpecDataSig :: RdrNameSpecDataSig
	      -> RnM_Fixes s RenamedSpecDataSig

rnSpecDataSig (SpecDataSig tycon ty src_loc)
  = pushSrcLocRn src_loc $
    let
	tyvars = extractMonoTyNames is_tyvar_name ty
    in
    mkTyVarNamesEnv src_loc tyvars     	`thenRn` \ (tv_env,_) ->
    lookupTyCon tycon			`thenRn` \ tycon' ->
    rnMonoType tv_env ty		`thenRn` \ ty' ->
    returnRn (SpecDataSig tycon' ty' src_loc)

is_tyvar_name n = isLexVarId (getLocalName n)
\end{code}

%*********************************************************
%*							*
\subsection{Class declarations}
%*							*
%*********************************************************

@rnClassDecl@ uses the `global name function' to create a new
class declaration in which local names have been replaced by their
original names, reporting any unknown names.

\begin{code}
rnClassDecl :: RdrNameClassDecl -> RnM_Fixes s RenamedClassDecl

rnClassDecl (ClassDecl context cname tyvar sigs mbinds pragmas src_loc)
  = pushSrcLocRn src_loc $
    mkTyVarNamesEnv src_loc [tyvar]	    `thenRn` \ (tv_env, [tyvar']) ->
    rnContext tv_env src_loc context	    `thenRn` \ context' ->
    lookupClass cname			    `thenRn` \ cname' ->
    mapRn (rn_op cname' tyvar' tv_env) sigs `thenRn` \ sigs' ->
    rnMethodBinds cname' mbinds		    `thenRn` \ mbinds' ->
    ASSERT(isNoClassPragmas pragmas)
    returnRn (ClassDecl context' cname' tyvar' sigs' mbinds' NoClassPragmas src_loc)
  where
    rn_op clas clas_tyvar tv_env sig@(ClassOpSig op ty pragmas locn)
      = pushSrcLocRn locn $
	lookupClassOp clas op		`thenRn` \ op_name ->
	rnPolyType tv_env ty		`thenRn` \ new_ty  ->
	let
	    (HsForAllTy tvs ctxt op_ty) = new_ty
	    ctxt_tvs = extractCtxtTyNames ctxt
	    op_tvs   = extractMonoTyNames is_tyvar_name op_ty
	in
	-- check that class tyvar appears in op_ty
        ( if isIn "rn_op" clas_tyvar op_tvs
	  then returnRn ()
	  else addErrRn (classTyVarNotInOpTyErr clas_tyvar sig locn)
	) `thenRn_`

	-- check that class tyvar *doesn't* appear in the sig's context
        ( if isIn "rn_op(2)" clas_tyvar ctxt_tvs
	  then addErrRn (classTyVarInOpCtxtErr clas_tyvar sig locn)
	  else returnRn ()
	) `thenRn_`

	ASSERT(isNoClassOpPragmas pragmas)
	returnRn (ClassOpSig op_name new_ty noClassOpPragmas locn)
\end{code}


%*********************************************************
%*							*
\subsection{Instance declarations}
%*							*
%*********************************************************


@rnInstDecl@ uses the `global name function' to create a new of
instance declaration in which local names have been replaced by their
original names, reporting any unknown names.

\begin{code}
rnInstDecl :: RdrNameInstDecl -> RnM_Fixes s RenamedInstDecl

rnInstDecl (InstDecl cname ty mbinds from_here modname uprags pragmas src_loc)
  = pushSrcLocRn src_loc $
    lookupClass cname 		     	`thenRn` \ cname' ->

    rnPolyType [] ty			`thenRn` \ ty' ->
	-- [] tv_env ensures that tyvars will be foralled

    rnMethodBinds cname' mbinds		`thenRn` \ mbinds' ->
    mapRn (rn_uprag cname') uprags	`thenRn` \ new_uprags ->

    ASSERT(isNoInstancePragmas pragmas)
    returnRn (InstDecl cname' ty' mbinds'
		       from_here modname new_uprags noInstancePragmas src_loc)
  where
    rn_uprag class_name (SpecSig op ty using locn)
      = pushSrcLocRn src_loc $
	lookupClassOp class_name op	`thenRn` \ op_name ->
	rnPolyType nullTyVarNamesEnv ty	`thenRn` \ new_ty ->
	rn_using using			`thenRn` \ new_using ->
	returnRn (SpecSig op_name new_ty new_using locn)

    rn_uprag class_name (InlineSig op locn)
      = pushSrcLocRn locn $
	lookupClassOp class_name op	`thenRn` \ op_name ->
	returnRn (InlineSig op_name locn)

    rn_uprag class_name (DeforestSig op locn)
      = pushSrcLocRn locn $
	lookupClassOp class_name op	`thenRn` \ op_name ->
	returnRn (DeforestSig op_name locn)

    rn_uprag class_name (MagicUnfoldingSig op str locn)
      = pushSrcLocRn locn $
	lookupClassOp class_name op	`thenRn` \ op_name ->
	returnRn (MagicUnfoldingSig op_name str locn)

    rn_using Nothing 
      = returnRn Nothing
    rn_using (Just v)
      = lookupValue v	`thenRn` \ new_v ->
	returnRn (Just new_v)
\end{code}

%*********************************************************
%*							*
\subsection{@SPECIALIZE instance@ user-pragmas}
%*							*
%*********************************************************

\begin{code}
rnSpecInstSig :: RdrNameSpecInstSig
	      -> RnM_Fixes s RenamedSpecInstSig

rnSpecInstSig (SpecInstSig clas ty src_loc)
  = pushSrcLocRn src_loc $
    let
	tyvars = extractMonoTyNames is_tyvar_name ty
    in
    mkTyVarNamesEnv src_loc tyvars     	`thenRn` \ (tv_env,_) ->
    lookupClass clas			`thenRn` \ new_clas ->
    rnMonoType tv_env ty		`thenRn` \ new_ty ->
    returnRn (SpecInstSig new_clas new_ty src_loc)
\end{code}

%*********************************************************
%*							*
\subsection{Default declarations}
%*							*
%*********************************************************

@rnDefaultDecl@ uses the `global name function' to create a new set
of default declarations in which local names have been replaced by
their original names, reporting any unknown names.

\begin{code}
rnDefaultDecl :: [RdrNameDefaultDecl] -> RnM_Fixes s [RenamedDefaultDecl]

rnDefaultDecl [] = returnRn []
rnDefaultDecl [DefaultDecl tys src_loc]
  = pushSrcLocRn src_loc $
    mapRn (rnMonoType nullTyVarNamesEnv) tys `thenRn` \ tys' ->
    returnRn [DefaultDecl tys' src_loc]
rnDefaultDecl defs@(d:ds)
  = addErrRn (dupDefaultDeclErr defs) `thenRn_`
    rnDefaultDecl [d]
\end{code}

%*************************************************************************
%*									*
\subsection{Fixity declarations}
%*									*
%*************************************************************************

\begin{code}
rnFixes :: [RdrNameFixityDecl]  -> RnM s [RenamedFixityDecl]

rnFixes fixities
  = getSrcLocRn	`thenRn` \ src_loc ->
    let
        (_, dup_fixes) = removeDups cmp_fix fixities
	cmp_fix fix1 fix2 = fixDeclName fix1 `cmp` fixDeclName fix2

        rn_fixity fix@(InfixL name i)
      	  = rn_fixity_pieces InfixL name i fix
    	rn_fixity fix@(InfixR name i)
      	  = rn_fixity_pieces InfixR name i fix
    	rn_fixity fix@(InfixN name i)
      	  = rn_fixity_pieces InfixN name i fix

    	rn_fixity_pieces mk_fixity name i fix
      	  = getRnEnv `thenRn` \ env ->
	      case lookupGlobalRnEnv env name of
	  	Just res | isLocallyDefined res || opt_CompilingGhcInternals
		  -- the opt_CompilingGhcInternals thing is a *HACK* to get (:)'s
		  -- fixity decl to go through.  It has a builtin name, which
		  -- doesn't respond to isLocallyDefined...  sigh.
	  	  -> returnRn (Just (mk_fixity res i))
	  	_ -> failButContinueRn Nothing (undefinedFixityDeclErr src_loc fix)
    in
    mapRn (addErrRn . dupFixityDeclErr src_loc) dup_fixes `thenRn_`
    mapRn rn_fixity fixities				  `thenRn` \ fixes_maybe ->
    returnRn (catMaybes fixes_maybe)
\end{code}

%*********************************************************
%*							*
\subsection{Support code to rename types}
%*							*
%*********************************************************

\begin{code}
rnPolyType :: TyVarNamesEnv
	   -> RdrNamePolyType
	   -> RnM_Fixes s RenamedPolyType

rnPolyType tv_env (HsForAllTy tvs ctxt ty)
  = rn_poly_help tv_env tvs ctxt ty

rnPolyType tv_env (HsPreForAllTy ctxt ty)
  = rn_poly_help tv_env forall_tyvars ctxt ty
  where
    mentioned_tyvars = extractCtxtTyNames ctxt `unionLists` extractMonoTyNames is_tyvar_name ty
    forall_tyvars    = {-
		       pprTrace "mentioned:" (ppCat (map (ppr PprShowAll) mentioned_tyvars)) $
		       pprTrace "from_ty:" (ppCat (map (ppr PprShowAll) (extractMonoTyNames is_tyvar_name ty))) $
		       -}
		       mentioned_tyvars `minusList` domTyVarNamesEnv tv_env

------------
rn_poly_help :: TyVarNamesEnv
	     -> [RdrName]
	     -> RdrNameContext
	     -> RdrNameMonoType
	     -> RnM_Fixes s RenamedPolyType

rn_poly_help tv_env tyvars ctxt ty
  = {-
    pprTrace "rnPolyType:"
 	(ppCat [ppCat (map (ppr PprShowAll . snd) tv_env),
    		ppStr ";tvs=", ppCat (map (ppr PprShowAll) tyvars),
    		ppStr ";ctxt=", ppCat (map (ppr PprShowAll) ctxt),
    		ppStr ";ty=", ppr PprShowAll ty]) $
    -}
    getSrcLocRn 			`thenRn` \ src_loc ->
    mkTyVarNamesEnv src_loc tyvars	`thenRn` \ (tv_env1, new_tyvars) ->
    let
	tv_env2 = catTyVarNamesEnvs tv_env1 tv_env
    in
    rnContext tv_env2 src_loc ctxt	`thenRn` \ new_ctxt ->
    rnMonoType tv_env2 ty		`thenRn` \ new_ty ->
    returnRn (HsForAllTy new_tyvars new_ctxt new_ty)
\end{code}

\begin{code}
rnMonoType :: TyVarNamesEnv
	   -> RdrNameMonoType
	   -> RnM_Fixes s RenamedMonoType

rnMonoType tv_env (MonoTyVar tyvar)
  = lookupTyVarName tv_env tyvar 	`thenRn` \ tyvar' ->
    returnRn (MonoTyVar tyvar')

rnMonoType tv_env (MonoListTy ty)
  = rnMonoType tv_env ty	`thenRn` \ ty' ->
    returnRn (MonoListTy ty')

rnMonoType tv_env (MonoFunTy ty1 ty2)
  = andRn MonoFunTy (rnMonoType tv_env ty1)
		    (rnMonoType tv_env ty2)

rnMonoType  tv_env (MonoTupleTy tys)
  = mapRn (rnMonoType tv_env) tys `thenRn` \ tys' ->
    returnRn (MonoTupleTy tys')

rnMonoType tv_env (MonoTyApp name tys)
  = let
	lookup_fn = if isLexVarId (getLocalName name) 
		    then lookupTyVarName tv_env
  	            else lookupTyCon
    in
    lookup_fn name			`thenRn` \ name' ->
    mapRn (rnMonoType tv_env) tys	`thenRn` \ tys' ->
    returnRn (MonoTyApp name' tys')
\end{code}

\begin{code}
rnContext :: TyVarNamesEnv -> SrcLoc -> RdrNameContext -> RnM_Fixes s RenamedContext

rnContext tv_env locn ctxt
  = mapRn rn_ctxt ctxt	`thenRn` \ result ->
    let
	(_, dup_asserts) = removeDups cmp_assert result
    in
    -- If this isn't an error, then it ought to be:
    mapRn (addWarnRn . dupClassAssertWarn result locn) dup_asserts `thenRn_`
    returnRn result
  where
    rn_ctxt (clas, tyvar)
      = lookupClass clas	     `thenRn` \ clas_name ->
	lookupTyVarName tv_env tyvar `thenRn` \ tyvar_name ->
	returnRn (clas_name, tyvar_name)

    cmp_assert (c1,tv1) (c2,tv2)
      = (c1 `cmp` c2) `thenCmp` (tv1 `cmp` tv2)
\end{code}


\begin{code}
dupNameExportWarn locn names@((n,_):_)
  = addShortWarnLocLine locn $ \ sty ->
    ppCat [pprNonSym sty n, ppStr "exported", ppInt (length names), ppStr "times"]

dupLocalsExportErr locn locals@((str,_):_)
  = addErrLoc locn "exported names have same local name" $ \ sty ->
    ppInterleave ppSP (map (pprNonSym sty . snd) locals)

classOpExportErr op locn
  = addShortErrLocLine locn $ \ sty ->
    ppBesides [ppStr "class operation `", ppr sty op, ppStr "' can only be exported with its class"]

fieldExportErr op locn
  = addShortErrLocLine locn $ \ sty ->
    ppBesides [ppStr "field name `", ppr sty op, ppStr "' can only be exported with its data type"]

synAllExportErr is_error syn locn
  = (if is_error then addShortErrLocLine else addShortWarnLocLine) locn $ \ sty ->
    ppBesides [ppStr "type synonym `", ppr sty syn, ppStr "' should be exported abstractly"]

withExportErr str rn has rns locn
  = addErrLoc locn "" $ \ sty ->
    ppAboves [ ppBesides [ppStr "inconsistent list of ", ppStr str, ppStr " in export list for `", ppr sty rn, ppStr "'"],
	       ppCat [ppStr "    expected:", ppInterleave ppComma (map (ppr sty) has)],
	       ppCat [ppStr "    found:   ", ppInterleave ppComma (map (ppr sty) rns)] ]

importAllErr rn locn
  = addShortErrLocLine locn $ \ sty ->
    ppBesides [ ppStr "`", pprNonSym sty rn, ppStr "' has been exported with (..), but is only imported abstractly"]

badModExportErr mod locn
  = addShortErrLocLine locn $ \ sty ->
    ppCat [ ppStr "unknown module in export list: module", ppPStr mod]

emptyModExportWarn locn mod
  = addShortWarnLocLine locn $ \ sty ->
    ppCat [ppStr "module", ppPStr mod, ppStr "has no unqualified imports to export"]

dupModExportWarn locn mods@(mod:_)
  = addShortWarnLocLine locn $ \ sty ->
    ppCat [ppStr "module", ppPStr mod, ppStr "appears", ppInt (length mods), ppStr "times in export list"]

derivingNonStdClassErr clas locn
  = addShortErrLocLine locn $ \ sty ->
    ppCat [ppStr "non-standard class in deriving:", ppr sty clas]

dupDefaultDeclErr (DefaultDecl _ locn1 : dup_things) sty
  = ppAboves (item1 : map dup_item dup_things)
  where
    item1
      = addShortErrLocLine locn1 (\ sty ->
	ppStr "multiple default declarations") sty

    dup_item (DefaultDecl _ locn)
      = addShortErrLocLine locn (\ sty ->
	ppStr "here was another default declaration") sty

undefinedFixityDeclErr locn decl
  = addErrLoc locn "fixity declaration for unknown operator" $ \ sty ->
    ppr sty decl

dupFixityDeclErr locn dups
  = addErrLoc locn "multiple fixity declarations for same operator" $ \ sty ->
    ppAboves (map (ppr sty) dups)

classTyVarNotInOpTyErr clas_tyvar sig locn
  = addShortErrLocLine locn $ \ sty ->
    ppHang (ppBesides [ppStr "Class type variable `", ppr sty clas_tyvar, ppStr "' does not appear in method signature:"])
	 4 (ppr sty sig)

classTyVarInOpCtxtErr clas_tyvar sig locn
  = addShortErrLocLine locn $ \ sty ->
    ppHang (ppBesides [ppStr "Class type variable `", ppr sty clas_tyvar, ppStr "' present in method's local overloading context:"])
	 4 (ppr sty sig)

dupClassAssertWarn ctxt locn dups
  = addShortWarnLocLine locn $ \ sty ->
    ppHang (ppBesides [ppStr "Duplicate class assertion `", ppr sty dups, ppStr "' in context:"])
	 4 (ppr sty ctxt)
\end{code}
