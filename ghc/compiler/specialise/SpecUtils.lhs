%
% (c) The GRASP/AQUA Project, Glasgow University, 1993-1996
%
\section[Specialise]{Stamping out overloading, and (optionally) polymorphism}

\begin{code}
#include "HsVersions.h"

module SpecUtils (
	specialiseCallTys,
	SYN_IE(ConstraintVector),
	getIdOverloading,
	mkConstraintVector,
	isUnboxedSpecialisation,

	specialiseConstrTys,
	mkSpecialisedCon,

	argTysMatchSpecTys_error,

	pprSpecErrs
    ) where

IMP_Ubiq(){-uitous-}

import Bag		( isEmptyBag, bagToList )
import Class		( classOpString, GenClass{-instance NamedThing-} )
import FiniteMap	( emptyFM, addListToFM_C, plusFM_C, keysFM,
			  lookupWithDefaultFM
			)
import Id		( idType, isDictFunId, isConstMethodId_maybe,
			  isDefaultMethodId_maybe,
			  GenId {-instance NamedThing -}
			)
import Maybes		( maybeToBool, catMaybes, firstJust )
import Name		( origName, isLexVarSym, isLexSpecialSym, pprNonSym )
import PprStyle		( PprStyle(..) )
import PprType		( pprGenType, pprParendGenType, pprMaybeTy,
			  TyCon{-ditto-}, GenType{-ditto-}, GenTyVar
			)
import Pretty		-- plenty of it
import TyCon		( tyConTyVars, TyCon{-instance NamedThing-} )
import Type		( splitSigmaTy, mkTyVarTy, mkForAllTys,
			  getTyVar_maybe, isUnboxedType
			)
import TyVar		( GenTyVar{-instance Eq-} )
import Unique		( Unique{-instance Eq-} )
import Util		( equivClasses, zipWithEqual, cmpPString,
			  assertPanic, panic{-ToDo:rm-}
			)

cmpType = panic "SpecUtils.cmpType (ToDo: get rid of)"
mkSameSpecCon = panic "SpecUtils.mkSameSpecCon (ToDo)"
getInstIdModule = panic "SpecUtils.getInstIdModule (ToDo)"
specialiseTy :: Type -> [Maybe Type] -> Int -> Type
specialiseTy = panic "SpecUtils.specialiseTy (ToDo)"
\end{code}

@specialiseCallTys@ works out which type args don't need to be specialised on,
based on flags, the overloading constraint vector, and the types.

\begin{code}
specialiseCallTys :: Bool 		-- Specialise on all type args
		  -> Bool 		-- Specialise on unboxed type args
		  -> Bool		-- Specialise on overloaded type args
		  -> ConstraintVector	-- Tells which type args are overloaded
		  -> [Type]		-- Type args
		  -> [Maybe Type]	-- Nothings replace non-specialised type args

specialiseCallTys True _ _ cvec tys
  = map Just tys
specialiseCallTys False spec_unboxed spec_overloading cvec tys
  = zipWithEqual "specialiseCallTys" spec_ty_other cvec tys
  where
    spec_ty_other c ty | (spec_unboxed && isUnboxedType ty)
			 || (spec_overloading && c)
			 = Just ty
		       | otherwise
			 = Nothing
\end{code}

@getIdOverloading@ grabs the type of an Id, and returns a
list of its polymorphic variables, and the initial segment of
its ThetaType, in which the classes constrain only type variables.
For example, if the Id's type is

	forall a,b,c. Eq a -> Ord [a] -> tau

we'll return

	([a,b,c], [(Eq,a)])

This seems curious at first.  For a start, the type above looks odd,
because we usually only have dictionary args whose types are of
the form (C a) where a is a type variable.  But this doesn't hold for
the functions arising from instance decls, which sometimes get
arguements with types of form (C (T a)) for some type constructor T.

Should we specialise wrt this compound-type dictionary?  This is
a heuristic judgement, as indeed is the fact that we specialise wrt
only dictionaries.  We choose *not* to specialise wrt compound dictionaries
because at the moment the only place they show up is in instance decls,
where they are simply plugged into a returned dictionary.  So nothing is
gained by specialising wrt them.

\begin{code}
getIdOverloading :: Id
		 -> ([TyVar], [(Class,TyVar)])
getIdOverloading id
  = (tyvars, tyvar_part_of theta)
  where
    (tyvars, theta, _) = splitSigmaTy (idType id)

    tyvar_part_of [] 		 = []
    tyvar_part_of ((c,ty):theta) = case (getTyVar_maybe ty) of
				     Nothing -> []
				     Just tv -> (c, tv) : tyvar_part_of theta
\end{code}

\begin{code}
type ConstraintVector = [Bool]	-- True for constrained tyvar, false otherwise

mkConstraintVector :: Id
		   -> ConstraintVector

mkConstraintVector id
  = [tyvar `elem` constrained_tyvars | tyvar <- tyvars]
  where
    (tyvars, class_tyvar_pairs) = getIdOverloading id
    constrained_tyvars   = map snd class_tyvar_pairs 	-- May contain dups
\end{code}

\begin{code}
isUnboxedSpecialisation :: [Maybe Type] -> Bool
isUnboxedSpecialisation tys
  = any is_unboxed tys
  where
    is_unboxed (Just ty) = isUnboxedType ty
    is_unboxed Nothing   = False
\end{code}

@specialiseConstrTys@ works out which type args don't need to be
specialised on. We only speciailise on unboxed types.

\begin{code}
specialiseConstrTys :: [Type]
		    -> [Maybe Type]

specialiseConstrTys tys
  = map maybe_unboxed_ty tys
  where
    maybe_unboxed_ty ty = case isUnboxedType ty of
			    True  -> Just ty
			    False -> Nothing
\end{code}

\begin{code}
mkSpecialisedCon :: Id -> [Type] -> Id
mkSpecialisedCon con tys
  = if spec_reqd
    then mkSameSpecCon spec_tys con
    else con
  where
    spec_tys  = specialiseConstrTys tys
    spec_reqd = maybeToBool (firstJust spec_tys)
\end{code}

@argTysMatchSpecTys@ checks if a list of argument types is consistent
with a list of specialising types. An error message is returned if not.
\begin{code}
argTysMatchSpecTys_error :: [Maybe Type]
			 -> [Type]
			 -> Maybe Pretty
argTysMatchSpecTys_error spec_tys arg_tys
  = if match spec_tys arg_tys
    then Nothing
    else Just (ppSep [ppStr "Spec and Arg Types Inconsistent:",
		      ppStr "spectys=", ppSep [pprMaybeTy PprDebug ty | ty <- spec_tys],
		      ppStr "argtys=", ppSep [pprParendGenType PprDebug ty | ty <- arg_tys]])
  where
    match (Nothing:spec_tys) (arg:arg_tys)
      = not (isUnboxedType arg) &&
	match spec_tys arg_tys
    match (Just spec:spec_tys) (arg:arg_tys)
      = case (cmpType True{-properly-} spec arg) of
	  EQ_   -> match spec_tys arg_tys
	  other -> False
    match [] [] = True
    match _  _  = False
\end{code}

@pprSpecErrs@ prints error and warning information
about imported specialisations which do not exist.

\begin{code}
pprSpecErrs :: FAST_STRING			-- module name
	    -> (Bag (Id,[Maybe Type]))	-- errors
	    -> (Bag (Id,[Maybe Type]))	-- warnings
	    -> (Bag (TyCon,[Maybe Type]))	-- errors
	    -> Pretty

pprSpecErrs this_mod spec_errs spec_warn spec_tyerrs
  | not any_errs && not any_warn
  = ppNil

  | otherwise
  = ppAboves [
	ppStr "SPECIALISATION MESSAGES:",
	ppAboves (map pp_module_specs use_modules)
	]
  where
    any_errs = not (isEmptyBag spec_errs && isEmptyBag spec_tyerrs)
    any_warn = not (isEmptyBag spec_warn)

    mk_module_fm get_mod_data errs_bag
      = addListToFM_C (++) emptyFM errs_list
      where
	errs_list = map get_mod_data (bagToList errs_bag)

    tyspecs_fm = mk_module_fm get_ty_data spec_tyerrs

    iderrs_fm  = mk_module_fm (get_id_data True) spec_errs
    idwarn_fm  = mk_module_fm (get_id_data False) spec_warn
    idspecs_fm = plusFM_C (++) idwarn_fm iderrs_fm

    get_id_data is_err (id, tys)
      = (mod_name, [(id_name, id, tys, is_err)])
      where
	(mod_name, id_name) = get_id_name id

    get_id_name id
      | maybeToBool (isDefaultMethodId_maybe id)
      = (this_mod, _NIL_)

      | isDictFunId id || maybeToBool (isConstMethodId_maybe id)
      = let get_mod = getInstIdModule id
	    use_mod = get_mod
	in (use_mod, _NIL_)

      | otherwise
      = case (origName "get_id_name" id) of { OrigName m n -> (m, n) }

    get_ty_data (ty, tys)
      = (mod_name, [(ty_name, ty, tys)])
      where
	(OrigName mod_name ty_name) = origName "get_ty_data" ty

    module_names    = concat [keysFM idspecs_fm, keysFM tyspecs_fm]
    mods            = map head (equivClasses _CMP_STRING_ module_names)

    (unks, known)   = if null mods
		      then ([], [])
		      else case _CMP_STRING_ (head mods) _NIL_ of
			    EQ_   -> ([_NIL_], tail mods)
			    other -> ([], mods)

    use_modules     = unks ++ known

    pp_module_specs :: FAST_STRING -> Pretty
    pp_module_specs mod
      | mod == _NIL_
      = ASSERT (null mod_tyspecs)
	ppAboves (map (pp_idspec ty_sty (ppStr "UNKNOWN:")) mod_idspecs)

      | have_specs
      = ppAboves [
	    ppAboves (map (pp_tyspec ty_sty (pp_module mod)) mod_tyspecs),
	    ppAboves (map (pp_idspec ty_sty (pp_module mod)) mod_idspecs)
	    ]

      | otherwise
      = ppNil

      where
	mod_tyspecs = lookupWithDefaultFM tyspecs_fm [] mod
	mod_idspecs = lookupWithDefaultFM idspecs_fm [] mod
	have_specs  = not (null mod_tyspecs && null mod_idspecs)
	ty_sty = PprInterface

pp_module mod
  = ppBesides [ppPStr mod, ppStr ":"]

pp_tyspec :: PprStyle -> Pretty -> (FAST_STRING, TyCon, [Maybe Type]) -> Pretty

pp_tyspec sty pp_mod (_, tycon, tys)
  = ppCat [pp_mod,
	   ppStr "{-# SPECIALIZE", ppStr "data",
	   pprNonSym PprForUser tycon, ppCat (map (pprParendGenType sty) spec_tys),
	   ppStr "#-}", ppStr "{- Essential -}"
	   ]
  where
    tvs = tyConTyVars tycon
    (spec_args, tv_maybes) = unzip (map choose_ty (tvs `zip` tys))
    spec_tys = map (mkForAllTys (catMaybes tv_maybes)) spec_args

    choose_ty (tv, Nothing) = (mkTyVarTy tv, Just tv)
    choose_ty (tv, Just ty) = (ty, Nothing)

pp_idspec :: PprStyle -> Pretty -> (FAST_STRING, Id, [Maybe Type], Bool) -> Pretty

pp_idspec sty pp_mod (_, id, tys, is_err)
  | isDictFunId id
  = ppCat [pp_mod,
	   ppStr "{-# SPECIALIZE",
	   ppStr "instance",
	   pprGenType sty spec_ty,
	   ppStr "#-}", pp_essential ]

  | is_const_method_id
  = let
	Just (cls, clsty, clsop) = const_method_maybe
    	(OrigName _ cls_str) = origName "pp_idspec" cls
	clsop_str    = classOpString clsop
    in
    ppCat [pp_mod,
	   ppStr "{-# SPECIALIZE",
	   pp_clsop clsop_str, ppStr "::",
	   pprGenType sty spec_ty,
	   ppStr "#-} {- IN instance",
	   ppPStr cls_str, pprParendGenType sty clsty,
	   ppStr "-}", pp_essential ]

  | is_default_method_id
  = let
	Just (cls, clsop, _) = default_method_maybe
    	(OrigName _ cls_str) = origName "pp_idspec2" cls
	clsop_str    = classOpString clsop
    in
    ppCat [pp_mod,
	   ppStr "{- instance",
	   ppPStr cls_str,
	   ppStr "EXPLICIT METHOD REQUIRED",
	   pp_clsop clsop_str, ppStr "::",
	   pprGenType sty spec_ty,
	   ppStr "-}", pp_essential ]

  | otherwise
  = ppCat [pp_mod,
	   ppStr "{-# SPECIALIZE",
	   pprNonSym PprForUser id, ppStr "::",
	   pprGenType sty spec_ty,
	   ppStr "#-}", pp_essential ]
  where
    spec_ty = specialiseTy (idType id) tys 100   -- HACK to drop all dicts!!!
    pp_essential = if is_err then ppStr "{- Essential -}" else ppNil

    const_method_maybe = isConstMethodId_maybe id
    is_const_method_id = maybeToBool const_method_maybe

    default_method_maybe = isDefaultMethodId_maybe id
    is_default_method_id = maybeToBool default_method_maybe

    pp_clsop str | isLexVarSym str && not (isLexSpecialSym str)
    	         = ppParens (ppPStr str)
    	         | otherwise
		 = ppPStr str

\end{code}
