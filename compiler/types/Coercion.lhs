%
% (c) The University of Glasgow 2006
%

\begin{code}
{-# LANGUAGE RankNTypes #-}
{-# OPTIONS -fno-warn-tabs #-}
-- The above warning supression flag is a temporary kludge.
-- While working on this module you are encouraged to remove it and
-- detab the module (please do the detabbing in a separate patch). See
--     http://hackage.haskell.org/trac/ghc/wiki/Commentary/CodingStyle#TabsvsSpaces
-- for details

-- | Module for (a) type kinds and (b) type coercions, 
-- as used in System FC. See 'CoreSyn.Expr' for
-- more on System FC and how coercions fit into it.
--
module Coercion (
        -- * CoAxioms
        mkCoAxBranch, mkBranchedCoAxiom, mkSingleCoAxiom,

        -- * Main data type
        Coercion, CoercionArg, ForAllCoBndr, LeftOrRight(..),
        Var, CoVar, TyCoVar, mkFreshCoVar,

        -- ** Functions over coercions
        coVarTypes, coVarKind, coVarTypesKinds,
        coercionType, coercionKind, coercionKinds,
        mkCoercionType, coercionArgKind,

	-- ** Constructing coercions
        mkReflCo, mkCoVarCo, 
        mkAxInstCo, mkUnbranchedAxInstCo, mkAxInstRHS,
        mkUnbranchedAxInstRHS,
        mkPiCo, mkPiCos, mkCoCast,
        mkSymCo, mkTransCo, mkNthCo, mkLRCo,
	mkInstCo, mkAppCo, mkTyConAppCo, mkFunCo,
        mkForAllCo, mkForAllCo_TyHomo, mkForAllCo_CoHomo,
        mkForAllCo_Ty, mkForAllCo_Co,
        mkUnsafeCo, mkNewTypeCo, mkAppCos, mkAxiomInstCo,
        mkCoherenceCo, mkCoherenceRightCo, mkCoherenceLeftCo,
        mkKindCo, castCoercionKind,

        mkTyHeteroCoBndr, mkCoHeteroCoBndr, mkHomoCoBndr,
        mkHeteroCoercionType,

        mkTyCoArg, mkCoCoArg, mkCoArgForVar,

        -- ** Decomposition
        splitNewTypeRepCo_maybe, instNewTyCon_maybe, 
        topNormaliseNewType, topNormaliseNewTypeX,

        decomposeCo, getCoVar_maybe,
        splitTyConAppCo_maybe,
        splitAppCo_maybe,
        splitForAllCo_maybe,
        splitForAllCo_Ty_maybe, splitForAllCo_Co_maybe,

        pickLR,

        getHomoVar_maybe, splitHeteroCoBndr_maybe,

        stripTyCoArg, splitCoCoArg_maybe,

        isReflCo, isReflCo_maybe, isReflLike, isReflLike_maybe,

	-- ** Coercion variables
	mkCoVar, isCoVar, coVarName, setCoVarName, setCoVarUnique,

        -- ** Free variables
        tyCoVarsOfCo, tyCoVarsOfCos, coVarsOfCo, coercionSize,
        tyCoVarsOfCoArg, tyCoVarsOfCoArgs,
	
        -- ** Substitution
        CvSubstEnv,
 	lookupCoVar,
	substCo, substCos, substCoVar, substCoVars,
        substCoVarBndr, substCoWithIS, substForAllCoBndr,
        extendTCvSubstAndInScope,

	-- ** Lifting
	liftCoSubst, liftCoSubstTyVar, liftCoSubstWith, liftCoSubstWithEx,
        emptyLiftingContext, liftCoSubstTyCoVar, liftSimply,
        liftCoSubstVarBndrCallback,

        LiftCoEnv, LiftingContext(..), liftEnvSubstLeft, liftEnvSubstRight,
        substRightCo, substLeftCo,

        -- ** Comparison
        eqCoercion, eqCoercionX, cmpCoercionX, eqCoercionArg,

        -- ** Forcing evaluation of coercions
        seqCo,
        
        -- * Pretty-printing
        pprCo, pprParendCo, pprCoArg, pprCoBndr,
        pprCoAxiom, pprCoAxBranch, pprCoAxBranchHdr, 

        -- * Tidying
        tidyCo, tidyCos,

        -- * Other
        applyCo, promoteCoercion
       ) where 

#include "HsVersions.h"

import TyCoRep
import Type 
import TyCon
import CoAxiom
import Var
import VarEnv
import VarSet
import Name hiding ( varName )
import NameSet
import Util
import BasicTypes
import Outputable
import Unique
import Pair
import SrcLoc
import PrelNames	( funTyConKey, eqPrimTyConKey, wildCardName )
import Control.Applicative
import Data.Traversable (traverse, sequenceA)
import Control.Arrow (second)
import Control.Monad (foldM)
import Data.Maybe (isJust)
import FastString
\end{code}


%************************************************************************
%*                                                                      *
           Constructing axioms
    These functions are here because tidyType etc 
    are not available in CoAxiom
%*                                                                      *
%************************************************************************

Note [Tidy axioms when we build them]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
We print out axioms and don't want to print stuff like
    F k k a b = ...
Instead we must tidy those kind variables.  See Trac #7524.


\begin{code}
mkCoAxBranch :: [TyVar] -- original, possibly stale, tyvars
             -> [Type]  -- LHS patterns
             -> Type    -- RHS
             -> SrcSpan
             -> CoAxBranch
mkCoAxBranch tvs lhs rhs loc
  = CoAxBranch { cab_tvs = tvs1
               , cab_lhs = tidyTypes env lhs
               , cab_rhs = tidyType  env rhs
               , cab_loc = loc }
  where
    (env, tvs1) = tidyTyCoVarBndrs emptyTidyEnv tvs
    -- See Note [Tidy axioms when we build them]
  

mkBranchedCoAxiom :: Name -> TyCon -> [CoAxBranch] -> CoAxiom Branched
mkBranchedCoAxiom ax_name fam_tc branches
  = CoAxiom { co_ax_unique   = nameUnique ax_name
            , co_ax_name     = ax_name
            , co_ax_tc       = fam_tc
            , co_ax_implicit = False
            , co_ax_branches = toBranchList branches }

mkSingleCoAxiom :: Name -> [TyVar] -> TyCon -> [Type] -> Type -> CoAxiom Unbranched
mkSingleCoAxiom ax_name tvs fam_tc lhs_tys rhs_ty
  = CoAxiom { co_ax_unique   = nameUnique ax_name
            , co_ax_name     = ax_name
            , co_ax_tc       = fam_tc
            , co_ax_implicit = False
            , co_ax_branches = FirstBranch branch }
  where
    branch = mkCoAxBranch tvs lhs_tys rhs_ty (getSrcSpan ax_name)
\end{code}


%************************************************************************
%*									*
     -- The coercion arguments always *precisely* saturate 
     -- arity of (that branch of) the CoAxiom.  If there are
     -- any left over, we use AppCo.  See 
     -- See [Coercion axioms applied to coercions]

\subsection{Coercion variables}
%*									*
%************************************************************************

\begin{code}
coVarName :: CoVar -> Name
coVarName = varName

setCoVarUnique :: CoVar -> Unique -> CoVar
setCoVarUnique = setVarUnique

setCoVarName :: CoVar -> Name -> CoVar
setCoVarName   = setVarName

coercionSize :: Coercion -> Int
coercionSize (Refl ty)           = typeSize ty
coercionSize (TyConAppCo _ args) = 1 + sum (map coercionArgSize args)
coercionSize (AppCo co arg)      = coercionSize co + coercionArgSize arg
coercionSize (ForAllCo _ co)     = 1 + coercionSize co
coercionSize (CoVarCo _)         = 1
coercionSize (AxiomInstCo _ _ args) = 1 + sum (map coercionArgSize args)
coercionSize (UnsafeCo ty1 ty2)  = typeSize ty1 + typeSize ty2
coercionSize (SymCo co)          = 1 + coercionSize co
coercionSize (TransCo co1 co2)   = 1 + coercionSize co1 + coercionSize co2
coercionSize (NthCo _ co)        = 1 + coercionSize co
coercionSize (LRCo  _ co)        = 1 + coercionSize co
coercionSize (InstCo co arg)     = 1 + coercionSize co + coercionArgSize arg
coercionSize (CoherenceCo c1 c2) = 1 + coercionSize c1 + coercionSize c2
coercionSize (KindCo co)         = 1 + coercionSize co

coercionArgSize :: CoercionArg -> Int
coercionArgSize (TyCoArg co)     = coercionSize co
coercionArgSize (CoCoArg c1 c2)  = coercionSize c1 + coercionSize c2
\end{code}

%************************************************************************
%*									*
                   Pretty-printing coercions
%*                                                                      *
%************************************************************************

@pprCo@ is the standard @Coercion@ printer; the overloaded @ppr@
function is defined to use this.  @pprParendCo@ is the same, except it
puts parens around the type, except for the atomic cases.
@pprParendCo@ works just by setting the initial context precedence
very high.

\begin{code}
-- Outputable instances are in TyCoRep, to avoid orphans

pprCo, pprParendCo :: Coercion -> SDoc
pprCo       co = ppr_co TopPrec   co
pprParendCo co = ppr_co TyConPrec co

pprCoArg :: CoercionArg -> SDoc
pprCoArg = ppr_arg TopPrec

ppr_co :: Prec -> Coercion -> SDoc
ppr_co _ (Refl ty) = angleBrackets (ppr ty)

ppr_co p co@(TyConAppCo tc [_,_])
  | tc `hasKey` funTyConKey = ppr_fun_co p co

ppr_co p (TyConAppCo tc args)  = pprTcApp   p ppr_arg tc args
ppr_co p (AppCo co arg)        = maybeParen p TyConPrec $
                                 pprCo co <+> ppr_arg TyConPrec arg
ppr_co p co@(ForAllCo {})      = ppr_forall_co p co
ppr_co _ (CoVarCo cv)          = parenSymOcc (getOccName cv) (ppr cv)
ppr_co p (AxiomInstCo con index args)
  = angleBrackets (pprPrefixApp p 
                    (ppr (getName con) <> brackets (ppr index))
                    (map (ppr_arg TyConPrec) args))

ppr_co p co@(TransCo {}) = maybeParen p FunPrec $
                           case trans_co_list co [] of
                             [] -> panic "ppr_co"
                             (co:cos) -> sep ( ppr_co FunPrec co
                                             : [ char ';' <+> ppr_co FunPrec co | co <- cos])
ppr_co p (InstCo co arg) = maybeParen p TyConPrec $
                           pprParendCo co <> ptext (sLit "@") <> ppr_arg TopPrec arg

ppr_co p (UnsafeCo ty1 ty2)  = pprPrefixApp p (ptext (sLit "UnsafeCo")) 
                                           [pprParendType ty1, pprParendType ty2]
ppr_co p (SymCo co)          = pprPrefixApp p (ptext (sLit "Sym")) [pprParendCo co]
ppr_co p (NthCo n co)        = pprPrefixApp p (ptext (sLit "Nth:") <> int n) [pprParendCo co]
ppr_co p (LRCo sel co)       = pprPrefixApp p (ppr sel) [pprParendCo co]
ppr_co p (CoherenceCo c1 c2) = maybeParen p TyConPrec $
                               (ppr_co FunPrec c1) <+> (ptext (sLit "|>")) <+>
                               (ppr_co FunPrec c2)
ppr_co p (KindCo co)         = pprPrefixApp p (ptext (sLit "kind")) [pprParendCo co]

ppr_arg :: Prec -> CoercionArg -> SDoc
ppr_arg p (TyCoArg co) = ppr_co p co
ppr_arg _ (CoCoArg co1 co2) = parens (pprCo co1 <> comma <+> pprCo co2)

trans_co_list :: Coercion -> [Coercion] -> [Coercion]
trans_co_list (TransCo co1 co2) cos = trans_co_list co1 (trans_co_list co2 cos)
trans_co_list co                cos = co : cos

ppr_fun_co :: Prec -> Coercion -> SDoc
ppr_fun_co p co = pprArrowChain p (split co)
  where
    split :: Coercion -> [SDoc]
    split (TyConAppCo f [TyCoArg arg, TyCoArg res])
      | f `hasKey` funTyConKey
      = ppr_co FunPrec arg : split res
    split co = [ppr_co TopPrec co]

ppr_forall_co :: Prec -> Coercion -> SDoc
ppr_forall_co p (ForAllCo cobndr co)
  = maybeParen p FunPrec $
    sep [pprCoBndr cobndr, ppr_co TopPrec co]
ppr_forall_co _ _ = panic "ppr_forall_co"

pprCoBndr :: ForAllCoBndr -> SDoc
pprCoBndr cobndr = pprForAll (coBndrVars cobndr)
\end{code}

\begin{code}
pprCoAxiom :: CoAxiom br -> SDoc
pprCoAxiom ax@(CoAxiom { co_ax_tc = tc, co_ax_branches = branches })
  = hang (ptext (sLit "axiom") <+> ppr ax <+> dcolon)
       2 (vcat (map (pprCoAxBranch tc) $ fromBranchList branches))

pprCoAxBranch :: TyCon -> CoAxBranch -> SDoc
pprCoAxBranch fam_tc (CoAxBranch { cab_tvs = tvs
                                 , cab_lhs = lhs
                                 , cab_rhs = rhs })
  = hang (ifPprDebug (pprForAll tvs))
       2 (hang (pprTypeApp fam_tc lhs) 2 (equals <+> (ppr rhs)))

pprCoAxBranchHdr :: CoAxiom br -> BranchIndex -> SDoc
pprCoAxBranchHdr ax@(CoAxiom { co_ax_tc = fam_tc, co_ax_name = name }) index
  | CoAxBranch { cab_lhs = tys, cab_loc = loc } <- coAxiomNthBranch ax index
  = hang (pprTypeApp fam_tc tys)
       2 (ptext (sLit "-- Defined") <+> ppr_loc loc)
  where
        ppr_loc loc
          | isGoodSrcSpan loc
          = ptext (sLit "at") <+> ppr (srcSpanStart loc)
    
          | otherwise
          = ptext (sLit "in") <+>
              quotes (ppr (nameModule name))
\end{code}

%************************************************************************
%*									*
	Destructing coercions		
%*									*
%************************************************************************

\begin{code}
-- | This breaks a 'Coercion' with type @T A B C ~ T D E F@ into
-- a list of 'Coercion's of kinds @A ~ D@, @B ~ E@ and @E ~ F@. Hence:
--
-- > decomposeCo 3 c = [nth 0 c, nth 1 c, nth 2 c]
decomposeCo :: Arity -> Coercion -> [CoercionArg]
decomposeCo arity co 
  = [mkNthCoArg n co | n <- [0..(arity-1)] ]
           -- Remember, Nth is zero-indexed

-- | Attempts to obtain the type variable underlying a 'Coercion'
getCoVar_maybe :: Coercion -> Maybe CoVar
getCoVar_maybe (CoVarCo cv) = Just cv  
getCoVar_maybe _            = Nothing

-- | Attempts to tease a coercion apart into a type constructor and the application
-- of a number of coercion arguments to that constructor
splitTyConAppCo_maybe :: Coercion -> Maybe (TyCon, [CoercionArg])
splitTyConAppCo_maybe (Refl ty)           = (fmap . second . map) liftSimply (splitTyConApp_maybe ty)
splitTyConAppCo_maybe (TyConAppCo tc cos) = Just (tc, cos)
splitTyConAppCo_maybe _                   = Nothing

splitAppCo_maybe :: Coercion -> Maybe (Coercion, CoercionArg)
-- ^ Attempt to take a coercion application apart.
splitAppCo_maybe (AppCo co arg) = Just (co, arg)
splitAppCo_maybe (TyConAppCo tc args)
  | isDecomposableTyCon tc || args `lengthExceeds` tyConArity tc 
  , Just (args', arg') <- snocView args
  = Just (mkTyConAppCo tc args', arg')    -- Never create unsaturated type family apps!
       -- Use mkTyConAppCo to preserve the invariant
       --  that identity coercions are always represented by Refl
splitAppCo_maybe (Refl ty) 
  | Just (ty1, ty2) <- splitAppTy_maybe ty 
  = Just (mkReflCo ty1, liftSimply ty2)
splitAppCo_maybe _ = Nothing

splitForAllCo_maybe :: Coercion -> Maybe (ForAllCoBndr, Coercion)
splitForAllCo_maybe (ForAllCo cobndr co) = Just (cobndr, co)
splitForAllCo_maybe _                    = Nothing

-- returns the two type variables abstracted over
splitForAllCo_Ty_maybe :: Coercion -> Maybe (TyVar, TyVar, CoVar, Coercion)
splitForAllCo_Ty_maybe (ForAllCo (TyHomo tv) co)
  = let k  = tyVarKind tv
        cv = mkCoVar wildCardName (mkCoercionType k k) in
    Just (tv, tv, cv, co) -- cv won't occur in co anyway
splitForAllCo_Ty_maybe (ForAllCo (TyHetero _ tv1 tv2 cv) co)
  = Just (tv1, tv2, cv, co)
splitForAllCo_Ty_maybe _
  = Nothing

-- returns the two coercion variables abstracted over
splitForAllCo_Co_maybe :: Coercion -> Maybe (CoVar, CoVar, Coercion)
splitForAllCo_Co_maybe (ForAllCo (CoHomo cv) co)          = Just (cv, cv, co)
splitForAllCo_Co_maybe (ForAllCo (CoHetero _ cv1 cv2) co) = Just (cv1, cv2, co)
splitForAllCo_Co_maybe _                                  = Nothing

-------------------------------------------------------
-- and some coercion kind stuff

coVarTypes :: CoVar -> (Type,Type)
coVarTypes cv
  | (_, _, ty1, ty2) <- coVarTypesKinds cv
  = (ty1, ty2)

coVarTypesKinds :: CoVar -> (Kind,Kind,Type,Type)
coVarTypesKinds cv
 | Just (tc, [k1,k2,ty1,ty2]) <- splitTyConApp_maybe (varType cv)
 = ASSERT (tc `hasKey` eqPrimTyConKey)
   (k1,k2,ty1,ty2)
 | otherwise = panic "coVarTypes, non coercion variable"

coVarKind :: CoVar -> Type
coVarKind cv
  = ASSERT( isCoVar cv )
    varType cv

-- | Makes a coercion type from two types: the types whose equality 
-- is proven by the relevant 'Coercion'
mkCoercionType :: Type -> Type -> Type
mkCoercionType = mkPrimEqPred

mkHeteroCoercionType :: Kind -> Kind -> Type -> Type -> Type
mkHeteroCoercionType = mkHeteroPrimEqPred

isReflCo :: Coercion -> Bool
isReflCo (Refl {}) = True
isReflCo _         = False

isReflCo_maybe :: Coercion -> Maybe Type
isReflCo_maybe (Refl ty) = Just ty
isReflCo_maybe _         = Nothing

-- | Returns the Refl'd type if the CoercionArg is "Refl-like".
-- A TyCoArg (Refl ...) is Refl-like.
-- A CoCoArg co1 co2 is Refl-like if co1 and co2 have the same type.
-- The Type returned in the second case is the first coercion in the CoCoArg.
isReflLike_maybe :: CoercionArg -> Maybe Type
isReflLike_maybe (TyCoArg (Refl ty)) = Just ty
isReflLike_maybe (CoCoArg co1 co2)
  | coercionType co1 `eqType` coercionType co2
  = Just $ CoercionTy co1

isReflLike_maybe _ = Nothing

isReflLike :: CoercionArg -> Bool
isReflLike = isJust . isReflLike_maybe
\end{code}

%************************************************************************
%*									*
            Building coercions
%*									*
%************************************************************************

These "smart constructors" maintain the invariants listed in the definition
of Coercion, and they perform very basic optimizations. Note that if you
add a new optimization here, you will have to update the code in Unify
to account for it. These smart constructors are used in substitution, so
to preserve the semantics of matching and unification, those algorithms must
be aware of any optimizations done here.

See also Note [Coercion optimizations and match_co] in Unify.

Note [Don't optimize mkTransCo]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
One would expect to implement the following two optimizations in mkTransCo:
  mkTransCo co1 (Refl ...) --> co1
  mkTransCo (Refl ...) co1 --> co1

However, doing this would make unification require backtracking search. Say
we had these optimizations and we are trying to match (co1 ; co2 ; co3) with
(co1' ; co2') (where ; means `TransCo`) One of the coercions disappeared, but
which one? Yuck. So, instead of putting this optimization here, we just have
it in OptCoercion.

Note [Don't optimize mkCoherenceCo]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
One would expect to use an easy optimization in mkCoherenceCo: we would want
  (CoherenceCo (CoherenceCo co1 co2) co3)
to become
  (CoherenceCo co1 (mkTransCo co2 co3))

This would be completely sound, and in fact it is done in OptCoercion. But
we *can't* do it here. This is because these smart constructors must be
invertible, in some sense. In the matching algorithm, we must consider all
optimizations that can happen during substitution. Because mkCoherenceCo
is used in substitution, if we did this optimization, the match function
would need to look for substitutions that yield this optimization. The
problem is that these substitutions are hard to find, because the mkTransCo
itself might be optimized. The basic problem is that it is hard to figure
out what co2 could possibly be from the optimized version. So, we don't
do the optimization.

Note [Optimizing mkSymCo is OK]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Given the previous two notes, the implementation of mkSymCo seems fishy.
Why is it OK to optimize this one? Because the optimizations don't require
backtracking search to invert, essentially. Say we are matching (SymCo co1)
with co2. If co2 is (SymCo co2'), then we just match co1 with co2'. If
co2 is (UnsafeCo ty1 ty2), then we match co1 with (UnsafeCo ty2 ty1). Otherwise,
we match co1 with (SymCo co2) -- the only way to get a coercion headed by
something other than SymCo or UnsafeCo is the SymCo (SymCo ..) optimization.
Also, critically, it is impossible to get a coercion headed by SymCo or
UnsafeCo by this optimization. (Contrast to the missing optimization in
mkTransCo, which could produce a TransCo.) So, we can keep these here. Phew.

\begin{code}
mkReflCo :: Type -> Coercion
mkReflCo ty
  = ASSERT( not $ isCoercionTy ty )
    Refl ty

-- | Apply a type constructor to a list of coercions.
mkTyConAppCo :: TyCon -> [CoercionArg] -> Coercion
mkTyConAppCo tc cos
	       -- Expand type synonyms
  | Just (tv_co_prs, rhs_ty, leftover_cos) <- tcExpandTyCon_maybe tc cos
  = mkAppCos (liftCoSubst tv_co_prs rhs_ty) leftover_cos

  | Just tys <- traverse isReflLike_maybe cos 
  = Refl (mkTyConApp tc tys)	-- See Note [Refl invariant]

  | otherwise = TyConAppCo tc cos

-- | Make a function 'Coercion' between two other 'Coercion's
mkFunCo :: Coercion -> Coercion -> Coercion
mkFunCo co1 co2 = mkTyConAppCo funTyCon [TyCoArg co1, TyCoArg co2]

-- | Apply a 'Coercion' to another 'CoercionArg'.
mkAppCo :: Coercion -> CoercionArg -> Coercion
mkAppCo (Refl ty1) arg
  | Just ty2 <- isReflLike_maybe arg
  = Refl (mkAppTy ty1 ty2)
mkAppCo (Refl (TyConApp tc tys)) co = TyConAppCo tc (map liftSimply tys ++ [co])
mkAppCo (TyConAppCo tc cos) co      = TyConAppCo tc (cos ++ [co])
mkAppCo co1 co2                     = AppCo co1 co2
-- Note, mkAppCo is careful to maintain invariants regarding
-- where Refl constructors appear; see the comments in the definition
-- of Coercion and the Note [Refl invariant] in types/TyCoRep.lhs.

-- | Applies multiple 'Coercion's to another 'CoercionArg', from left to right.
-- See also 'mkAppCo'
mkAppCos :: Coercion -> [CoercionArg] -> Coercion
mkAppCos co1 tys = foldl mkAppCo co1 tys

-- | Make a Coercion from a ForAllCoBndr and Coercion
mkForAllCo :: ForAllCoBndr -> Coercion -> Coercion
mkForAllCo cobndr co
  | Refl ty <- co
  = Refl (mkForAllTy (getHomoVar cobndr) ty)
  | otherwise
  = ASSERT( isHomoCoBndr cobndr || (not $ isReflCo $ getHeteroKindCo cobndr) )
    ForAllCo cobndr co

-- | Make a Coercion quantified over a type variable; the variable has
-- the same type in both types of the coercion
mkForAllCo_TyHomo :: TyVar -> Coercion -> Coercion
mkForAllCo_TyHomo tv (Refl ty) = ASSERT( isTyVar tv ) Refl (mkForAllTy tv ty)
mkForAllCo_TyHomo tv co        = ASSERT( isTyVar tv ) ForAllCo (TyHomo tv) co

-- | Make a Coercion quantified over type variables, potentially of
-- different kinds.
mkForAllCo_Ty :: Coercion -> TyVar -> TyVar -> CoVar -> Coercion -> Coercion
mkForAllCo_Ty _ tv _ _ (Refl ty) = ASSERT( isTyVar tv ) Refl (mkForAllTy tv ty)
mkForAllCo_Ty h tv1 tv2 cv co
  | tyVarKind tv1 `eqType` tyVarKind tv2
  = ASSERT( isReflCo h )
    let co' = substCoWith [tv2,               cv]
                          [mkOnlyTyVarTy tv1, mkCoercionTy $ mkReflCo (tyVarKind tv1)] co in
    ASSERT( isTyVar tv1 )
    ForAllCo (TyHomo tv1) co'
  | otherwise
  = ASSERT( isTyVar tv1 && isTyVar tv2 && isCoVar cv )
    ForAllCo (TyHetero h tv1 tv2 cv) co

-- | Make a Coercion quantified over a coercion variable; the variable has
-- the same type in both types of the coercion
mkForAllCo_CoHomo :: CoVar -> Coercion -> Coercion
mkForAllCo_CoHomo cv (Refl ty) = ASSERT( isCoVar cv ) Refl (mkForAllTy cv ty)
mkForAllCo_CoHomo cv co        = ASSERT( isCoVar cv ) ForAllCo (CoHomo cv) co

-- | Make a Coercion quantified over two coercion variables, possibly of
-- different kinds
mkForAllCo_Co :: Coercion -> CoVar -> CoVar -> Coercion -> Coercion
mkForAllCo_Co _ cv _ (Refl ty) = ASSERT( isCoVar cv ) Refl (mkForAllTy cv ty)
mkForAllCo_Co h cv1 cv2 co
  | coVarKind cv1 `eqType` coVarKind cv2
  = ASSERT( isReflCo h )
    let co' = substCoWith [cv2] [mkTyCoVarTy cv1] co in
    ASSERT( isCoVar cv1 )
    ForAllCo (CoHomo cv1) co'
  | otherwise
  = ASSERT( isCoVar cv1 && isCoVar cv2 )
    ForAllCo (CoHetero h cv1 cv2) co

mkCoVarCo :: CoVar -> Coercion
-- cv :: s ~# t
mkCoVarCo cv
  | ty1 `eqType` ty2 = Refl ty1
  | otherwise        = CoVarCo cv
  where
    (ty1, ty2) = coVarTypes cv

mkFreshCoVar :: InScopeSet -> Type -> Type -> CoVar
mkFreshCoVar in_scope ty1 ty2
  = let cv_uniq = mkCoVarUnique 31 -- arbitrary number
        cv_name = mkSystemVarName cv_uniq (mkFastString "c") in
    uniqAway in_scope $ mkCoVar cv_name (mkCoercionType ty1 ty2)

mkAxInstCo :: CoAxiom br -> BranchIndex -> [Type] -> Coercion
-- mkAxInstCo can legitimately be called over-staturated; 
-- i.e. with more type arguments than the coercion requires
mkAxInstCo ax index tys
  | arity == n_tys = mkAxiomInstCo ax_br index rtys
  | otherwise      = ASSERT( arity < n_tys )
                     foldl mkAppCo (mkAxiomInstCo ax_br index (take arity rtys))
                                   (drop arity rtys)
  where
    n_tys = length tys
    arity = coAxiomArity ax index
    rtys  = map liftSimply tys
    ax_br = toBranchedAxiom ax

-- worker function; just checks to see if it should produce Refl
mkAxiomInstCo :: CoAxiom Branched -> BranchIndex -> [CoercionArg] -> Coercion
mkAxiomInstCo ax index args
  = ASSERT( coAxiomArity ax index == length args )
    let co           = AxiomInstCo ax index args
        Pair ty1 ty2 = coercionKind co in
    if ty1 `eqType` ty2
    then Refl ty1
    else co

-- to be used only with unbranched axioms
mkUnbranchedAxInstCo :: CoAxiom Unbranched -> [Type] -> Coercion
mkUnbranchedAxInstCo ax tys
  = mkAxInstCo ax 0 tys

mkAxInstRHS :: CoAxiom br -> BranchIndex -> [Type] -> Type
-- Instantiate the axiom with specified types,
-- returning the instantiated RHS
-- A companion to mkAxInstCo: 
--    mkAxInstRhs ax index tys = snd (coercionKind (mkAxInstCo ax index tys))
mkAxInstRHS ax index tys
  = ASSERT( tvs `equalLength` tys1 ) 
    mkAppTys rhs' tys2
  where
    branch       = coAxiomNthBranch ax index
    tvs          = coAxBranchTyCoVars branch
    (tys1, tys2) = splitAtList tvs tys
    rhs'         = substTyWith tvs tys1 (coAxBranchRHS branch)

mkUnbranchedAxInstRHS :: CoAxiom Unbranched -> [Type] -> Type
mkUnbranchedAxInstRHS ax = mkAxInstRHS ax 0

-- | Manufacture a coercion from thin air. Needless to say, this is
--   not usually safe, but it is used when we know we are dealing with
-- where Refl constructors appear; see the comments in the definition
--   bottom, which is one case in which it is safe.  This is also used
--   to implement the @unsafeCoerce#@ primitive.  Optimise by pushing
--   down through type constructors.
mkUnsafeCo :: Type -> Type -> Coercion
mkUnsafeCo ty1 ty2 | ty1 `eqType` ty2 = Refl ty1
mkUnsafeCo (TyConApp tc1 tys1) (TyConApp tc2 tys2)
  | tc1 == tc2
  = mkTyConAppCo tc1 (zipWith mkUnsafeCoArg tys1 tys2)

mkUnsafeCo (FunTy a1 r1) (FunTy a2 r2)
  = mkFunCo (mkUnsafeCo a1 a2) (mkUnsafeCo r1 r2)
mkUnsafeCo ty1 ty2 = UnsafeCo ty1 ty2

mkUnsafeCoArg :: Type -> Type -> CoercionArg
mkUnsafeCoArg (CoercionTy co1) (CoercionTy co2) = CoCoArg co1 co2
mkUnsafeCoArg ty1 ty2
  = ASSERT( not (isCoercionTy ty1) && not (isCoercionTy ty2) )
    TyCoArg $ UnsafeCo ty1 ty2

-- | Create a symmetric version of the given 'Coercion' that asserts
--   equality between the same types but in the other "direction", so
--   a kind of @t1 ~ t2@ becomes the kind @t2 ~ t1@.
mkSymCo :: Coercion -> Coercion

-- Do a few simple optimizations, but don't bother pushing occurrences
-- of symmetry to the leaves; the optimizer will take care of that.
-- See Note [Optimizing mkSymCo is OK]
mkSymCo co@(Refl {})              = co
mkSymCo    (UnsafeCo ty1 ty2)    = UnsafeCo ty2 ty1
mkSymCo    (SymCo co)            = co
mkSymCo co                       = SymCo co

-- | Create a new 'Coercion' by composing the two given 'Coercion's transitively.
mkTransCo :: Coercion -> Coercion -> Coercion
-- See Note [Don't optimize mkTransCo]
mkTransCo co1 co2
  | Pair s1 _s2 <- coercionKind co1
  , Pair _t1 t2 <- coercionKind co2
  , s1 `eqType` t2
  = ASSERT( _s2 `eqType` _t1 )
    Refl s1
mkTransCo co1 co2     = TransCo co1 co2

mkNthCo :: Int -> Coercion -> Coercion
mkNthCo n co
  | TyCoArg co' <- mkNthCoArg n co
  = co'
  | otherwise
  = pprPanic "mkNthCo" (ppr co)

mkNthCoArg :: Int -> Coercion -> CoercionArg
mkNthCoArg n (Refl ty) = ASSERT( ok_tc_app ty n )
                         liftSimply $ tyConAppArgN n ty
mkNthCoArg n co
  | Just (tv1, _) <- splitForAllTy_maybe ty1
  , Just (tv2, _) <- splitForAllTy_maybe ty2
  , tyVarKind tv1 `eqType` tyVarKind tv2
  , n == 0
  = liftSimply (tyVarKind tv1)

  | Just (_tc1, tys1) <- splitTyConApp_maybe ty1
  , Just (_tc2, tys2) <- splitTyConApp_maybe ty2
  , ASSERT( n < length tys1 && n < length tys2 )
    (tys1 !! n) `eqType` (tys2 !! n)
  = liftSimply (tys1 !! n)

  | otherwise
  = TyCoArg $ NthCo n co
  where
    Pair ty1 ty2 = coercionKind co

ok_tc_app :: Type -> Int -> Bool
ok_tc_app ty n
  | Just (_, tys) <- splitTyConApp_maybe ty
  = tys `lengthExceeds` n
  | isForAllTy ty  -- nth:0 pulls out a kind coercion from a hetero forall
  = n == 0
  | otherwise
  = False

mkLRCo :: LeftOrRight -> Coercion -> Coercion
mkLRCo lr (Refl ty) = Refl (pickLR lr (splitAppTy ty))
mkLRCo lr co    
  | ty1 `eqType` ty2
  = Refl ty1
  | otherwise
  = LRCo lr co
  where Pair ty1 ty2 = (pickLR lr . splitAppTy) <$> coercionKind co

-- | Instantiates a 'Coercion'.
mkInstCo :: Coercion -> CoercionArg -> Coercion
mkInstCo co arg = let result = InstCo co arg
                      Pair ty1 ty2 = coercionKind result in
                  if ty1 `eqType` ty2
                  then Refl ty1
                  else result

-- See Note [Don't optimize mkCoherenceCo]
mkCoherenceCo :: Coercion -> Coercion -> Coercion
mkCoherenceCo co1 co2     = let result = CoherenceCo co1 co2
                                Pair ty1 ty2 = coercionKind result in
                            if ty1 `eqType` ty2
                            then Refl ty1
                            else result

-- | A CoherenceCo c1 c2 applies the coercion c2 to the left-hand type
-- in the kind of c1. This function uses sym to get the coercion on the 
-- right-hand type of c1. Thus, if c1 :: s ~ t, then mkCoherenceRightCo c1 c2
-- has the kind (s ~ (t |> c2))
--   down through type constructors.
mkCoherenceRightCo :: Coercion -> Coercion -> Coercion
mkCoherenceRightCo c1 c2 = mkSymCo (mkCoherenceCo (mkSymCo c1) c2)

-- | An explictly directed synonym of mkCoherenceCo
mkCoherenceLeftCo :: Coercion -> Coercion -> Coercion
mkCoherenceLeftCo = mkCoherenceCo

infixl 5 `mkCoherenceCo` 
infixl 5 `mkCoherenceRightCo`
infixl 5 `mkCoherenceLeftCo`

mkKindCo :: Coercion -> Coercion
mkKindCo (Refl ty) = Refl (typeKind ty)
mkKindCo co
  | Pair ty1 ty2 <- coercionKind co
  , typeKind ty1 `eqType` typeKind ty2
  = Refl (typeKind ty1)
  | otherwise
  = KindCo co
\end{code}

%************************************************************************
%*                                                                      *
   ForAllCoBndr
%*                                                                      *
%************************************************************************

\begin{code}

-- | Makes homogeneous ForAllCoBndr, choosing between TyHomo and CoHomo
-- based on the nature of the TyCoVar
mkHomoCoBndr :: TyCoVar -> ForAllCoBndr
mkHomoCoBndr v
  | isTyVar v = TyHomo v
  | otherwise = CoHomo v

getHomoVar :: ForAllCoBndr -> TyCoVar
getHomoVar cobndr
  | Just v <- getHomoVar_maybe cobndr = v
  | otherwise                          = pprPanic "getHomoVar" (ppr cobndr)

getHomoVar_maybe :: ForAllCoBndr -> Maybe TyCoVar
getHomoVar_maybe (TyHomo tv) = Just tv
getHomoVar_maybe (CoHomo cv) = Just cv
getHomoVar_maybe _           = Nothing

splitHeteroCoBndr_maybe :: ForAllCoBndr -> Maybe (Coercion, TyCoVar, TyCoVar)
splitHeteroCoBndr_maybe (TyHetero eta tv1 tv2 _) = Just (eta, tv1, tv2)
splitHeteroCoBndr_maybe (CoHetero eta cv1 cv2)   = Just (eta, cv1, cv2)
splitHeteroCoBndr_maybe _                        = Nothing

isHomoCoBndr :: ForAllCoBndr -> Bool
isHomoCoBndr (TyHomo {}) = True
isHomoCoBndr (CoHomo {}) = True
isHomoCoBndr _           = False

getHeteroKindCo :: ForAllCoBndr -> Coercion
getHeteroKindCo (TyHetero eta _ _ _) = eta
getHeteroKindCo (CoHetero eta _ _) = eta
getHeteroKindCo cobndr = pprPanic "getHeteroKindCo" (ppr cobndr)

mkTyHeteroCoBndr :: Coercion -> TyVar -> TyVar -> CoVar -> ForAllCoBndr
mkTyHeteroCoBndr h tv1 tv2 cv
  = ASSERT( _hty1 `eqType` (tyVarKind tv1) )
    ASSERT( _hty2 `eqType` (tyVarKind tv2) )
    ASSERT( coVarKind cv `eqType` (mkCoercionType (mkOnlyTyVarTy tv1) (mkOnlyTyVarTy tv2)) )
    TyHetero h tv1 tv2 cv
    where Pair _hty1 _hty2 = coercionKind h

mkCoHeteroCoBndr :: Coercion -> CoVar -> CoVar -> ForAllCoBndr
mkCoHeteroCoBndr h cv1 cv2
  = ASSERT( _hty1 `eqType` (coVarKind cv1) )
    ASSERT( _hty2 `eqType` (coVarKind cv2) )
    CoHetero h cv1 cv2
    where Pair _hty1 _hty2 = coercionKind h

-------------------------------

-- like mkKindCo, but aggressively & recursively optimizes to avoid using
-- a KindCo constructor.
promoteCoercion :: Coercion -> Coercion

-- First cases handles anything that should yield refl. The ASSERT( False )s throughout
-- are these cases explicitly, but they should never fire.
promoteCoercion co
  | Pair ty1 ty2 <- coercionKind co
  , (typeKind ty1) `eqType` (typeKind ty2)
  = mkReflCo (typeKind ty1)

-- These should never return refl.
promoteCoercion (Refl ty) = ASSERT( False ) mkReflCo (typeKind ty)
promoteCoercion g@(TyConAppCo tc args)
  | Just co' <- instCoercions (mkReflCo (tyConKind tc)) args
  = co'
  | otherwise
  = mkKindCo g
promoteCoercion g@(AppCo co arg)
  | Just co' <- instCoercion (promoteCoercion co) arg
  = co'
  | otherwise
  = mkKindCo g
promoteCoercion (ForAllCo _ _)     = ASSERT( False ) mkReflCo liftedTypeKind
promoteCoercion g@(CoVarCo {})     = mkKindCo g
promoteCoercion g@(AxiomInstCo {}) = mkKindCo g
promoteCoercion g@(UnsafeCo {})    = mkKindCo g
promoteCoercion (SymCo co)         = mkSymCo (promoteCoercion co)
promoteCoercion (TransCo co1 co2)  = mkTransCo (promoteCoercion co1)
                                               (promoteCoercion co2)
promoteCoercion g@(NthCo n co)
  | Just (_, args) <- splitTyConAppCo_maybe co
  , n < length args
  = case args !! n of
      TyCoArg co1 -> promoteCoercion co1
      CoCoArg _ _ -> pprPanic "promoteCoercion" (ppr g)
  | Just _ <- splitForAllCo_maybe co
  , n == 0
  = ASSERT( False ) mkReflCo liftedTypeKind
  | otherwise
  = mkKindCo g
promoteCoercion g@(LRCo lr co)
  | Just (lco, rarg) <- splitAppCo_maybe co
  = case lr of
      CLeft  -> promoteCoercion lco
      CRight -> case rarg of
        TyCoArg co1 -> promoteCoercion co1
        CoCoArg _ _ -> pprPanic "promoteCoercion" (ppr g)
  | otherwise
  = mkKindCo g
promoteCoercion (InstCo _ _)      = ASSERT( False ) mkReflCo liftedTypeKind
promoteCoercion (CoherenceCo g h) = (mkSymCo h) `mkTransCo` promoteCoercion g
promoteCoercion (KindCo _)        = ASSERT( False ) mkReflCo liftedTypeKind

-- say g = promoteCoercion h. Then, instCoercion g w yields Just g',
-- where g' = promoteCoercion (h w)
-- fails if this is not possible, if g coerces between a forall and an ->
instCoercion :: Coercion -> CoercionArg -> Maybe Coercion
instCoercion g w
  | isForAllTy ty1 && isForAllTy ty2
  = Just $ mkInstCo g w
  | isFunTy ty1 && isFunTy ty2
  = Just $ mkNthCo 1 g -- extract result type, which is the 2nd argument to (->)
  | otherwise -- one forall, one funty...
  = Nothing
  where
    Pair ty1 ty2 = coercionKind g

instCoercions :: Coercion -> [CoercionArg] -> Maybe Coercion
instCoercions = foldM instCoercion

-- | Creates a new coercion with both of its types casted by different casts
-- castCoercionKind g h1 h2, where g :: t1 ~ t2, has type (t1 |> h1) ~ (t2 |> h2)
castCoercionKind :: Coercion -> Coercion -> Coercion -> Coercion
castCoercionKind g h1 h2 = g `mkCoherenceLeftCo` h1 `mkCoherenceRightCo` h2

-- See note [Newtype coercions] in TyCon

-- | Create a coercion constructor (axiom) suitable for the given
--   newtype 'TyCon'. The 'Name' should be that of a new coercion
--   'CoAxiom', the 'TyVar's the arguments expected by the @newtype@ and
--   the type the appropriate right hand side of the @newtype@, with
--   the free variables a subset of those 'TyVar's.
mkNewTypeCo :: Name -> TyCon -> [TyVar] -> Type -> CoAxiom Unbranched
mkNewTypeCo name tycon tvs rhs_ty
  = CoAxiom { co_ax_unique   = nameUnique name
            , co_ax_name     = name
            , co_ax_implicit = True  -- See Note [Implicit axioms] in TyCon
            , co_ax_tc       = tycon
            , co_ax_branches = FirstBranch branch }
  where branch = CoAxBranch { cab_loc = getSrcSpan name
                            , cab_tvs = tvs
                            , cab_lhs = mkTyCoVarTys tvs
                            , cab_rhs = rhs_ty }

mkPiCos :: [Var] -> Coercion -> Coercion
mkPiCos vs co = foldr mkPiCo co vs

mkPiCo  :: Var -> Coercion -> Coercion
mkPiCo v co | isTyVar v = mkForAllCo_TyHomo v co
            | isCoVar v = mkForAllCo_CoHomo v co
            | otherwise = mkFunCo (mkReflCo (varType v)) co

-- mkCoCast (c :: s1 ~# t1) (g :: (s1 ~# s2) ~# (t1 ~# t2)) :: t2 ~# t2
mkCoCast :: Coercion -> Coercion -> Coercion
-- (mkCoCast (c :: s1 ~# t1) (g :: (s1 ~# t1) ~# (s2 ~# t2)
mkCoCast c g
  = mkSymCo g1 `mkTransCo` c `mkTransCo` g2
  where
       -- g  :: (s1 ~# s2) ~# (t1 ~#  t2)
       -- g1 :: s1 ~# t1
       -- g2 :: s2 ~# t2
    [_reflk1, _reflk2, TyCoArg g1, TyCoArg g2] = decomposeCo 4 g
            -- Remember, (~#) :: forall k1 k2. k1 -> k2 -> *
            -- so it takes *four* arguments, not two
\end{code}

%************************************************************************
%*                                                                      *
   CoercionArgs
%*                                                                      *
%************************************************************************

\begin{code}
mkTyCoArg :: Coercion -> CoercionArg
mkTyCoArg = TyCoArg

mkCoCoArg :: Coercion -> Coercion -> CoercionArg
mkCoCoArg = CoCoArg

isTyCoArg :: CoercionArg -> Bool
isTyCoArg (TyCoArg _) = True
isTyCoArg _           = False

stripTyCoArg :: CoercionArg -> Coercion
stripTyCoArg (TyCoArg co) = co
stripTyCoArg arg          = pprPanic "stripTyCoArg" (ppr arg)

stripCoCoArg :: CoercionArg -> Pair Coercion
stripCoCoArg (CoCoArg co1 co2) = Pair co1 co2
stripCoCoArg arg               = pprPanic "stripCoCoArg" (ppr arg)

splitCoCoArg_maybe :: CoercionArg -> Maybe (Coercion, Coercion)
splitCoCoArg_maybe (TyCoArg _)     = Nothing
splitCoCoArg_maybe (CoCoArg c1 c2) = Just (c1, c2)

-- | Makes a suitable CoercionArg representing the passed-in variable
-- during a lifting-like substitution
mkCoArgForVar :: TyCoVar -> CoercionArg
mkCoArgForVar v
  | isTyVar v = TyCoArg $ mkReflCo $ mkOnlyTyVarTy v
  | otherwise = CoCoArg (mkCoVarCo v) (mkCoVarCo v)
\end{code}

%************************************************************************
%*									*
            Newtypes
%*									*
%************************************************************************

\begin{code}
instNewTyCon_maybe :: TyCon -> [Type] -> Maybe (Type, Coercion)
-- ^ If @co :: T ts ~ rep_ty@ then:
--
-- > instNewTyCon_maybe T ts = Just (rep_ty, co)
-- Checks for a newtype, and for being saturated
instNewTyCon_maybe tc tys
  | Just (tvs, ty, co_tc) <- unwrapNewTyCon_maybe tc  -- Check for newtype
  , tys `lengthIs` tyConArity tc                      -- Check saturated
  = Just (substTyWith tvs tys ty, mkUnbranchedAxInstCo co_tc tys)
  | otherwise
  = Nothing

splitNewTypeRepCo_maybe :: Type -> Maybe (Type, Coercion)  
-- ^ Sometimes we want to look through a @newtype@ and get its associated coercion.
-- This function only strips *one layer* of @newtype@ off, so the caller will usually call
-- itself recursively. If
--
-- > splitNewTypeRepCo_maybe ty = Just (ty', co)
--
-- then  @co : ty ~ ty'@.  The function returns @Nothing@ for non-@newtypes@, 
-- or unsaturated applications
splitNewTypeRepCo_maybe ty 
  | Just ty' <- coreView ty 
  = splitNewTypeRepCo_maybe ty'
splitNewTypeRepCo_maybe (TyConApp tc tys)
  = instNewTyCon_maybe tc tys
splitNewTypeRepCo_maybe _
  = Nothing

topNormaliseNewType :: Type -> Maybe (Type, Coercion)
topNormaliseNewType ty
  = case topNormaliseNewTypeX emptyNameSet ty of
      Just (_, co, ty) -> Just (ty, co)
      Nothing          -> Nothing

topNormaliseNewTypeX :: NameSet -> Type -> Maybe (NameSet, Coercion, Type)
topNormaliseNewTypeX rec_nts ty
  | Just ty' <- coreView ty         -- Expand predicates and synonyms
  = topNormaliseNewTypeX rec_nts ty'

topNormaliseNewTypeX rec_nts (TyConApp tc tys)
  | Just (rep_ty, co) <- instNewTyCon_maybe tc tys
  , not (tc_name `elemNameSet` rec_nts)  -- See Note [Expanding newtypes] in Type
  = case topNormaliseNewTypeX rec_nts' rep_ty of
       Nothing                       -> Just (rec_nts', co,                 rep_ty)
       Just (rec_nts', co', rep_ty') -> Just (rec_nts', co `mkTransCo` co', rep_ty')
  where
    tc_name = tyConName tc
    rec_nts' | isRecursiveTyCon tc = addOneToNameSet rec_nts tc_name
             | otherwise	   = rec_nts

topNormaliseNewTypeX _ _ = Nothing
\end{code}
%************************************************************************
%*									*
                   Comparison of coercions
%*                                                                      *
%************************************************************************

\begin{code}

-- | Syntactic equality of coercions
eqCoercion :: Coercion -> Coercion -> Bool
eqCoercion c1 c2 = isEqual $ cmpCoercion c1 c2
  
-- | Compare two 'Coercion's, with respect to an RnEnv2
eqCoercionX :: RnEnv2 -> Coercion -> Coercion -> Bool
eqCoercionX env c1 c2 = isEqual $ cmpCoercionX env c1 c2

-- | Substitute within several 'Coercion's
cmpCoercion :: Coercion -> Coercion -> Ordering
cmpCoercion c1 c2 = cmpCoercionX rn_env c1 c2
  where rn_env = mkRnEnv2 (mkInScopeSet (tyCoVarsOfCo c1 `unionVarSet` tyCoVarsOfCo c2))

cmpCoercionX :: RnEnv2 -> Coercion -> Coercion -> Ordering
cmpCoercionX env (Refl ty1)                   (Refl ty2) = cmpTypeX env ty1 ty2
cmpCoercionX env (TyConAppCo tc1 args1)       (TyConAppCo tc2 args2)
  = (tc1 `cmpTc` tc2) `thenCmp` cmpCoercionArgsX env args1 args2
cmpCoercionX env (AppCo co1 arg1)             (AppCo co2 arg2)
  = cmpCoercionX env co1 co2 `thenCmp` cmpCoercionArgX env arg1 arg2
cmpCoercionX env (ForAllCo cobndr1 co1)       (ForAllCo cobndr2 co2)
  = cmpCoBndrX env cobndr1 cobndr2 `thenCmp`
    cmpCoercionX (rnCoBndr2 env cobndr1 cobndr2) co1 co2
cmpCoercionX env (CoVarCo cv1)                (CoVarCo cv2)
  = rnOccL env cv1 `compare` rnOccR env cv2
cmpCoercionX env (AxiomInstCo ax1 ind1 args1) (AxiomInstCo ax2 ind2 args2)
  = (ax1 `cmpCoAx` ax2) `thenCmp`
    (ind1 `compare` ind2) `thenCmp`
    cmpCoercionArgsX env args1 args2
cmpCoercionX env (UnsafeCo tyl1 tyr1)         (UnsafeCo tyl2 tyr2)
  = cmpTypeX env tyl1 tyl2 `thenCmp` cmpTypeX env tyr1 tyr2
cmpCoercionX env (SymCo co1)                  (SymCo co2)
  = cmpCoercionX env co1 co2
cmpCoercionX env (TransCo col1 cor1)          (TransCo col2 cor2)
  = cmpCoercionX env col1 col2 `thenCmp` cmpCoercionX env cor1 cor2
cmpCoercionX env (NthCo n1 co1)               (NthCo n2 co2)
  = (n1 `compare` n2) `thenCmp` cmpCoercionX env co1 co2
cmpCoercionX env (InstCo co1 arg1)            (InstCo co2 arg2)
  = cmpCoercionX env co1 co2 `thenCmp` cmpCoercionArgX env arg1 arg2
cmpCoercionX env (CoherenceCo col1 cor1)      (CoherenceCo col2 cor2)
  = cmpCoercionX env col1 col2 `thenCmp` cmpCoercionX env cor1 cor2
cmpCoercionX env (KindCo co1)                 (KindCo co2)
  = cmpCoercionX env co1 co2

-- Deal with the rest, in constructor order
-- Refl < TyConAppCo < AppCo < ForAllCo < CoVarCo < AxiomInstCo <
--  UnsafeCo < SymCo < TransCo < NthCo < LRCo < InstCo < CoherenceCo < KindCo
cmpCoercionX _ co1 co2
  = (get_rank co1) `compare` (get_rank co2)
  where get_rank :: Coercion -> Int
        get_rank (Refl {})        = 0
        get_rank (TyConAppCo {})  = 1
        get_rank (AppCo {})       = 2
        get_rank (ForAllCo {})    = 3
        get_rank (CoVarCo {})     = 4
        get_rank (AxiomInstCo {}) = 5
        get_rank (UnsafeCo {})    = 6
        get_rank (SymCo {})       = 7
        get_rank (TransCo {})     = 8
        get_rank (NthCo {})       = 9
        get_rank (LRCo {})        = 10
        get_rank (InstCo {})      = 11
        get_rank (CoherenceCo {}) = 12
        get_rank (KindCo {})      = 13

eqCoercionArg :: CoercionArg -> CoercionArg -> Bool
eqCoercionArg arg1 arg2 = isEqual $ cmpCoercionArgX rn_env arg1 arg2
  where
    rn_env = mkRnEnv2 (mkInScopeSet (tyCoVarsOfCoArg arg1 `unionVarSet`
                                     tyCoVarsOfCoArg arg2))


cmpCoercionArgX :: RnEnv2 -> CoercionArg -> CoercionArg -> Ordering
cmpCoercionArgX env (TyCoArg co1)       (TyCoArg co2)
  = cmpCoercionX env co1 co2
cmpCoercionArgX env (CoCoArg col1 cor1) (CoCoArg col2 cor2)
  = cmpCoercionX env col1 col2 `thenCmp` cmpCoercionX env cor1 cor2
cmpCoercionArgX _ (TyCoArg {}) (CoCoArg {}) = LT
cmpCoercionArgX _ (CoCoArg {}) (TyCoArg {}) = GT

cmpCoercionArgsX :: RnEnv2 -> [CoercionArg] -> [CoercionArg] -> Ordering
cmpCoercionArgsX _ [] [] = EQ
cmpCoercionArgsX env (arg1:args1) (arg2:args2)
  = cmpCoercionArgX env arg1 arg2 `thenCmp` cmpCoercionArgsX env args1 args2
cmpCoercionArgsX _ [] _  = LT
cmpCoercionArgsX _ _  [] = GT

cmpCoAx :: CoAxiom a -> CoAxiom b -> Ordering
cmpCoAx ax1 ax2 = (coAxiomUnique ax1) `compare` (coAxiomUnique ax2)

cmpCoBndrX :: RnEnv2 -> ForAllCoBndr -> ForAllCoBndr -> Ordering
cmpCoBndrX env (TyHomo tv1) (TyHomo tv2)
  = cmpTypeX env (tyVarKind tv1) (tyVarKind tv2)
cmpCoBndrX env (TyHetero co1 tvl1 tvr1 cv1) (TyHetero co2 tvl2 tvr2 cv2)
  = cmpCoercionX env co1 co2 `thenCmp`
    cmpTypeX env (tyVarKind tvl1) (tyVarKind tvl2) `thenCmp`
    cmpTypeX env (tyVarKind tvr1) (tyVarKind tvr2) `thenCmp`
    cmpTypeX env (coVarKind cv1)  (coVarKind cv2)
cmpCoBndrX env (CoHomo cv1) (CoHomo cv2)
  = cmpTypeX env (coVarKind cv1) (coVarKind cv2)
cmpCoBndrX env (CoHetero co1 cvl1 cvr1) (CoHetero co2 cvl2 cvr2)
  = cmpCoercionX env co1 co2 `thenCmp`
    cmpTypeX env (coVarKind cvl1) (coVarKind cvl2) `thenCmp`
    cmpTypeX env (coVarKind cvr1) (coVarKind cvr2)
cmpCoBndrX _ cobndr1 cobndr2
  = (get_rank cobndr1) `compare` (get_rank cobndr2)
  where get_rank :: ForAllCoBndr -> Int
        get_rank (TyHomo {})   = 0
        get_rank (TyHetero {}) = 1
        get_rank (CoHomo {})   = 2
        get_rank (CoHetero {}) = 3

rnCoBndr2 :: RnEnv2 -> ForAllCoBndr -> ForAllCoBndr -> RnEnv2
rnCoBndr2 env cobndr1 cobndr2
  = foldl2 rnBndr2 env (coBndrVars cobndr1) (coBndrVars cobndr2)
\end{code}

%************************************************************************
%*									*
                   "Lifting" substitution
	   [(TyCoVar,CoercionArg)] -> Type -> Coercion
%*                                                                      *
%************************************************************************

Note [Lifting Contexts]
~~~~~~~~~~~~~~~~~~~~~~~
Say we have an expression like this, where K is a constructor of the type
T:

case (K a b |> co) of ...

The scrutinee is not an application of a constructor -- it is a cast. Thus,
we want to be able to push the coercion inside the arguments to K (a and b,
in this case) so that the top-level structure of the scrutinee is a
constructor application. In the presence of kind coercions, this is a bit
of a hairy operation. So, we refer you to the paper introducing kind coercions,
available at www.cis.upenn.edu/~sweirich/papers/nokinds-extended.pdf

\begin{code}
data LiftingContext = LC InScopeSet LiftCoEnv

type LiftCoEnv = VarEnv CoercionArg
     -- Maps *type variables* to *coercions* (TyCoArg) and coercion variables
     -- to pairs of coercions (CoCoArg). That's the whole point of this function!

-- See Note [Lifting Contexts]
liftCoSubstWithEx :: [TyCoVar]  -- universally quantified tycovars
                  -> [CoercionArg] -- coercions to substitute for those
                  -> [TyCoVar]  -- existentially quantified tycovars
                  -> [Type] -- types and coercions to be bound to ex vars
                  -> (Type -> Coercion) -- lifting function
liftCoSubstWithEx univs omegas exs rhos
  = let theta = mkLiftingContext (zipEqual "liftCoSubstWithExU" univs omegas)
        psi   = extendLiftingContext theta (zipEqual "liftCoSubstWithExX" exs rhos)
    in ty_co_subst psi

liftCoSubstWith :: [TyCoVar] -> [CoercionArg] -> Type -> Coercion
liftCoSubstWith tvs cos ty
  = liftCoSubst (zipEqual "liftCoSubstWith" tvs cos) ty

liftCoSubst :: [(TyCoVar,CoercionArg)] -> Type -> Coercion
liftCoSubst prs ty
 | null prs  = Refl ty
 | otherwise = ty_co_subst (mkLiftingContext prs) ty

emptyLiftingContext :: InScopeSet -> LiftingContext
emptyLiftingContext in_scope = LC in_scope emptyVarEnv

mkLiftingContext :: [(TyCoVar,CoercionArg)] -> LiftingContext
mkLiftingContext prs = LC (mkInScopeSet (tyCoVarsOfCoArgs (map snd prs)))
                          (mkVarEnv prs)

-- See Note [Lifting Contexts]
extendLiftingContext :: LiftingContext -> [(TyCoVar,Type)] -> LiftingContext
extendLiftingContext lc [] = lc
extendLiftingContext lc@(LC in_scope env) ((v,ty):rest)
  | isTyVar v
  = let lc' = LC (in_scope `extendInScopeSetSet` tyCoVarsOfType ty)
                 (extendVarEnv env v (TyCoArg $ mkSymCo $ mkCoherenceCo
                                         (mkReflCo ty)
                                         (ty_co_subst lc (tyVarKind v))))
    in extendLiftingContext lc' rest
  | CoercionTy co <- ty
  = let (s1, s2) = coVarTypes v
        lc' = LC (in_scope `extendInScopeSetSet` tyCoVarsOfCo co)
                 (extendVarEnv env v (CoCoArg co $
                                         (mkSymCo (ty_co_subst lc s1)) `mkTransCo`
                                         co `mkTransCo`
                                         (ty_co_subst lc s2)))
    in extendLiftingContext lc' rest
  | otherwise
  = pprPanic "extendLiftingContext" (ppr v <+> ptext (sLit "|->") <+> ppr ty)

-- | The \"lifting\" operation which substitutes coercions for type
--   variables in a type to produce a coercion.
--
--   For the inverse operation, see 'liftCoMatch' 
ty_co_subst :: LiftingContext -> Type -> Coercion
ty_co_subst lc@(LC _ env) ty
  = go ty
  where
    go :: Type -> Coercion
    go ty | tyCoVarsOfType ty `isNotInDomainOf` env = mkReflCo ty
    go (TyVarTy tv)      = liftCoSubstTyVar lc tv
    go (AppTy ty1 ty2)   = mkAppCo (go ty1) (go_arg ty2)
    go (TyConApp tc tys) = mkTyConAppCo tc (map go_arg tys)
    go (FunTy ty1 ty2)   = mkFunCo (go ty1) (go ty2)
    go (ForAllTy v ty)   = let (lc', cobndr) = liftCoSubstVarBndr lc v in
                           mkForAllCo cobndr $! ty_co_subst lc' ty
    go ty@(LitTy {})     = mkReflCo ty
    go (CastTy ty co)    = castCoercionKind (go ty) (substLeftCo lc co)
                                                    (substRightCo lc co)
    go (CoercionTy co)   = pprPanic "ty_co_subst" (ppr co)

    go_arg :: Type -> CoercionArg
    go_arg (CoercionTy co) = CoCoArg (substLeftCo lc co) (substRightCo lc co)
    go_arg ty              = TyCoArg (go ty)

    isNotInDomainOf :: VarSet -> VarEnv a -> Bool
    isNotInDomainOf set env
      = noneSet (\v -> elemVarEnv v env) set

    noneSet :: (Var -> Bool) -> VarSet -> Bool
    noneSet f = foldVarSet (\v rest -> rest && (not $ f v)) True

liftCoSubstTyVar :: LiftingContext -> TyVar -> Coercion
liftCoSubstTyVar (LC _ cenv) tv
  | TyCoArg co <- lookupVarEnv_NF cenv tv
  = co
  | otherwise
  = pprPanic "liftCoSubstTyVar" (ppr tv <+> (ptext (sLit "|->")) <+>
                                 ppr (lookupVarEnv_NF cenv tv))

liftCoSubstTyCoVar :: LiftingContext -> TyCoVar -> Maybe CoercionArg
liftCoSubstTyCoVar (LC _ env) v
  = lookupVarEnv env v

liftCoSubstVarBndr :: LiftingContext -> TyCoVar
                     -> (LiftingContext, ForAllCoBndr)
liftCoSubstVarBndr = liftCoSubstVarBndrCallback ty_co_subst False

liftCoSubstVarBndrCallback :: (LiftingContext -> Type -> Coercion)
                           -> Bool -- True <=> homogenize TyHetero substs
                                   -- see Note [Normalising types] in FamInstEnv
                           -> LiftingContext -> TyCoVar
                           -> (LiftingContext, ForAllCoBndr)
liftCoSubstVarBndrCallback fun homo lc@(LC in_scope cenv) old_var
  = (LC (in_scope `extendInScopeSetList` coBndrVars cobndr) new_cenv, cobndr)
  where
    eta = fun lc (tyVarKind old_var)
    Pair k1 k2 = coercionKind eta
    new_var = uniqAway in_scope (setVarType old_var k1)

    (new_cenv, cobndr)
      | new_var == old_var
      , k1 `eqType` k2
      = (delVarEnv cenv old_var, mkHomoCoBndr old_var)

      | k1 `eqType` k2
      = (extendVarEnv cenv old_var (mkCoArgForVar new_var), mkHomoCoBndr new_var)

      | isTyVar old_var
      = let a1 = new_var
            in_scope1 = in_scope `extendInScopeSet` a1
            a2 = uniqAway in_scope1 $ setVarType new_var k2
            in_scope2 = in_scope1 `extendInScopeSet` a2
            c  = mkFreshCoVar in_scope2 (mkOnlyTyVarTy a1) (mkOnlyTyVarTy a2) 
            lifted = if homo
                     then mkCoVarCo c `mkCoherenceRightCo` mkSymCo eta
                     else mkCoVarCo c
        in
        ( extendVarEnv cenv old_var (TyCoArg lifted)
        , mkTyHeteroCoBndr eta a1 a2 c )

      | otherwise
      = let cv1 = new_var
            in_scope1 = in_scope `extendInScopeSet` cv1
            cv2 = uniqAway in_scope1 $ setVarType new_var k2
            lifted_r = if homo
                       then mkNthCo 2 eta
                            `mkTransCo` (mkCoVarCo cv2)
                            `mkTransCo` mkNthCo 3 (mkSymCo eta)
                       else mkCoVarCo cv2
        in
        ( extendVarEnv cenv old_var (CoCoArg (mkCoVarCo cv1) lifted_r)
        , mkCoHeteroCoBndr eta cv1 cv2 )

-- If [a |-> g] is in the substitution and g :: t1 ~ t2, substitute a for t1
-- If [a |-> (g1, g2)] is in the substitution, substitute a for g1
substLeftCo :: LiftingContext -> Coercion -> Coercion
substLeftCo lc co
  = substCo (lcSubstLeft lc) co

-- Ditto, but for t2 and g2
substRightCo :: LiftingContext -> Coercion -> Coercion
substRightCo lc co
  = substCo (lcSubstRight lc) co

lcSubstLeft :: LiftingContext -> TCvSubst
lcSubstLeft (LC in_scope lc_env) = liftEnvSubstLeft in_scope lc_env

lcSubstRight :: LiftingContext -> TCvSubst
lcSubstRight (LC in_scope lc_env) = liftEnvSubstRight in_scope lc_env

liftEnvSubstLeft :: InScopeSet -> LiftCoEnv -> TCvSubst
liftEnvSubstLeft = liftEnvSubst pFst

liftEnvSubstRight :: InScopeSet -> LiftCoEnv -> TCvSubst
liftEnvSubstRight = liftEnvSubst pSnd

liftEnvSubst :: (forall a. Pair a -> a) -> InScopeSet -> LiftCoEnv -> TCvSubst
liftEnvSubst fn in_scope lc_env
  = mkTCvSubst in_scope tenv cenv
  where
    (tenv0, cenv0) = partitionVarEnv isTyCoArg lc_env
    tenv           = mapVarEnv (fn . coercionKind . stripTyCoArg) tenv0
    cenv           = mapVarEnv (fn . stripCoCoArg) cenv0

-- | all types that are not coercions get lifted into TyCoArg (Refl ty)
-- a coercion (g :: t1 ~ t2) becomes (CoCoArg (Refl t1) (Refl t2)).
-- If you need to convert a Type to a CoercionArg and you are tempted to
-- use (map Refl), then you want this.
liftSimply :: Type -> CoercionArg
liftSimply (CoercionTy co)
  = let Pair t1 t2 = coercionKind co in
    CoCoArg (mkReflCo t1) (mkReflCo t2)
liftSimply ty = TyCoArg $ mkReflCo ty

\end{code}

%************************************************************************
%*									*
            Sequencing on coercions
%*									*
%************************************************************************

\begin{code}
seqCo :: Coercion -> ()
seqCo (Refl ty)             = seqType ty
seqCo (TyConAppCo tc cos)   = tc `seq` seqCoArgs cos
seqCo (AppCo co1 co2)       = seqCo co1 `seq` seqCoArg co2
seqCo (ForAllCo cobndr co)  = seqCoBndr cobndr `seq` seqCo co
seqCo (CoVarCo cv)          = cv `seq` ()
seqCo (AxiomInstCo con ind cos) = con `seq` ind `seq` seqCoArgs cos
seqCo (UnsafeCo ty1 ty2)    = seqType ty1 `seq` seqType ty2
seqCo (SymCo co)            = seqCo co
seqCo (TransCo co1 co2)     = seqCo co1 `seq` seqCo co2
seqCo (NthCo _ co)          = seqCo co
seqCo (LRCo _ co)           = seqCo co
seqCo (InstCo co arg)       = seqCo co `seq` seqCoArg arg
seqCo (CoherenceCo co1 co2) = seqCo co1 `seq` seqCo co2
seqCo (KindCo co)           = seqCo co

seqCoArg :: CoercionArg -> ()
seqCoArg (TyCoArg co)      = seqCo co
seqCoArg (CoCoArg co1 co2) = seqCo co1 `seq` seqCo co2

seqCoArgs :: [CoercionArg] -> ()
seqCoArgs []         = ()
seqCoArgs (arg:args) = seqCoArg arg `seq` seqCoArgs args

seqCoBndr :: ForAllCoBndr -> ()
seqCoBndr (TyHomo tv) = tv `seq` ()
seqCoBndr (TyHetero h tv1 tv2 cv) = seqCo h `seq` tv1 `seq` tv2 `seq` cv `seq` ()
seqCoBndr (CoHomo cv) = cv `seq` ()
seqCoBndr (CoHetero h cv1 cv2) = seqCo h `seq` cv1 `seq` cv2 `seq` ()
\end{code}


%************************************************************************
%*									*
	     The kind of a type, and of a coercion
%*									*
%************************************************************************

\begin{code}
coercionType :: Coercion -> Type
coercionType co = mkCoercionType ty1 ty2
  where Pair ty1 ty2 = coercionKind co

------------------
-- | If it is the case that
--
-- > c :: (t1 ~ t2)
--
-- i.e. the kind of @c@ relates @t1@ and @t2@, then @coercionKind c = Pair t1 t2@.

coercionKind :: Coercion -> Pair Type 
coercionKind co = go co
  where 
    go (Refl ty)            = Pair ty ty
    go (TyConAppCo tc cos)  = mkTyConApp tc <$> (sequenceA $ map coercionArgKind cos)
    go (AppCo co1 co2)      = mkAppTy <$> go co1 <*> coercionArgKind co2
    go (ForAllCo (TyHomo tv) co)            = mkForAllTy tv <$> go co
    go (ForAllCo (TyHetero _ tv1 tv2 _) co) = mkForAllTy <$> Pair tv1 tv2 <*> go co
    go (ForAllCo (CoHomo tv) co)            = mkForAllTy tv <$> go co
    go (ForAllCo (CoHetero _ cv1 cv2) co)   = mkForAllTy <$> Pair cv1 cv2 <*> go co
    go (CoVarCo cv)         = toPair $ coVarTypes cv
    go (AxiomInstCo ax ind cos)
      | CoAxBranch { cab_tvs = tvs, cab_lhs = lhs, cab_rhs = rhs } <- coAxiomNthBranch ax ind
      , Pair tys1 tys2 <- sequenceA (map coercionArgKind cos)
      = ASSERT( cos `equalLength` tvs )  -- Invariant of AxiomInstCo: cos should 
                                         -- exactly saturate the axiom branch
        Pair (substTyWith tvs tys1 (mkTyConApp (coAxiomTyCon ax) lhs))
             (substTyWith tvs tys2 rhs)
    go (UnsafeCo ty1 ty2)   = Pair ty1 ty2
    go (SymCo co)           = swap $ go co
    go (TransCo co1 co2)    = Pair (pFst $ go co1) (pSnd $ go co2)
    go g@(NthCo d co)
      | Just args1 <- tyConAppArgs_maybe ty1
      , Just args2 <- tyConAppArgs_maybe ty2
      = (!! d) <$> Pair args1 args2
     
      | d == 0
      , Just (tv1, _) <- splitForAllTy_maybe ty1
      , Just (tv2, _) <- splitForAllTy_maybe ty2
      = tyVarKind <$> Pair tv1 tv2

      | otherwise
      = pprPanic "coercionKind" (ppr g)
      where
        Pair ty1 ty2 = coercionKind co
    go (LRCo lr co)         = (pickLR lr . splitAppTy) <$> go co
    go (InstCo aco arg)     = go_app aco [arg]
    go (CoherenceCo g h)    = let Pair ty1 ty2 = go g in
                              Pair (mkCastTy ty1 h) ty2
    go (KindCo co)          = typeKind <$> go co

    go_app :: Coercion -> [CoercionArg] -> Pair Type
    -- Collect up all the arguments and apply all at once
    -- See Note [Nested InstCos]
    go_app (InstCo co arg) args = go_app co (arg:args)
    go_app co              args = applyTys <$> go co <*> (sequenceA $ map coercionArgKind args)

coercionArgKind :: CoercionArg -> Pair Type
coercionArgKind (TyCoArg co)      = coercionKind co
coercionArgKind (CoCoArg co1 co2) = Pair (CoercionTy co1) (CoercionTy co2)

-- | Apply 'coercionKind' to multiple 'Coercion's
coercionKinds :: [Coercion] -> Pair [Type]
coercionKinds tys = sequenceA $ map coercionKind tys
\end{code}

Note [Nested InstCos]
~~~~~~~~~~~~~~~~~~~~~
In Trac #5631 we found that 70% of the entire compilation time was
being spent in coercionKind!  The reason was that we had
   (g @ ty1 @ ty2 .. @ ty100)    -- The "@s" are InstCos
where 
   g :: forall a1 a2 .. a100. phi
If we deal with the InstCos one at a time, we'll do this:
   1.  Find the kind of (g @ ty1 .. @ ty99) : forall a100. phi'
   2.  Substitute phi'[ ty100/a100 ], a single tyvar->type subst
But this is a *quadratic* algorithm, and the blew up Trac #5631.
So it's very important to do the substitution simultaneously.

cf Type.applyTys (which in fact we call here)


\begin{code}
applyCo :: Type -> Coercion -> Type
-- Gives the type of (e co) where e :: (a~b) => ty
applyCo ty co | Just ty' <- coreView ty = applyCo ty' co
applyCo (FunTy _ ty) _ = ty
applyCo _            _ = panic "applyCo"
\end{code}

Utility function, needed in DsBinds:

\begin{code}
extendTCvSubstAndInScope :: TCvSubst -> CoVar -> Coercion -> TCvSubst
-- Also extends the in-scope set
extendTCvSubstAndInScope (TCvSubst in_scope tenv cenv) cv co
  = TCvSubst (in_scope `extendInScopeSetSet` tyCoVarsOfCo co)
             tenv
             (extendVarEnv cenv cv co)
\end{code}