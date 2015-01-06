module Coercion where

import {-# SOURCE #-} TyCoRep
import {-# SOURCE #-} CoAxiom
import {-# SOURCE #-} TyCon
import Var
import Outputable
import VarEnv
import Pair
import FastString

mkReflCo :: Role -> Type -> Coercion
mkTyConAppCo :: Role -> TyCon -> [CoercionArg] -> Coercion
mkAppCo :: Coercion -> CoercionArg -> Coercion
mkForAllCo :: ForAllCoBndr -> Coercion -> Coercion
mkCoVarCo :: CoVar -> Coercion
mkAxiomInstCo :: CoAxiom Branched -> BranchIndex -> [CoercionArg] -> Coercion
mkPhantomCo :: Coercion -> Type -> Type -> Coercion
mkUnsafeCo :: FastString -> Role -> Type -> Type -> Coercion
mkSymCo :: Coercion -> Coercion
mkTransCo :: Coercion -> Coercion -> Coercion
mkNthCo :: Int -> Coercion -> Coercion
mkLRCo :: LeftOrRight -> Coercion -> Coercion
mkInstCo :: Coercion -> CoercionArg -> Coercion
mkCoherenceCo :: Coercion -> Coercion -> Coercion
mkKindCo :: Coercion -> Coercion
mkSubCo :: Coercion -> Coercion
bulletCo :: Coercion

isReflCo :: Coercion -> Bool
mkAppCos :: Coercion -> [CoercionArg] -> Coercion
coVarKindsTypesRole :: CoVar -> (Kind, Kind, Type, Type, Role)
coVarRole :: CoVar -> Role

mkHomoCoBndr :: TyCoVar -> ForAllCoBndr
mkTyHeteroCoBndr :: Coercion -> TyVar -> TyVar -> CoVar -> ForAllCoBndr
mkCoHeteroCoBndr :: Coercion -> CoVar -> CoVar -> ForAllCoBndr
getHomoVar_maybe :: ForAllCoBndr -> Maybe TyCoVar
splitHeteroCoBndr_maybe :: ForAllCoBndr -> Maybe (Coercion, TyCoVar, TyCoVar)

mkCoercionType :: Role -> Type -> Type -> Type

data LiftingContext
liftCoSubst :: Role -> LiftingContext -> Type -> Coercion
coercionSize :: Coercion -> Int
seqCo :: Coercion -> ()

cmpCoercionX :: RnEnv2 -> Coercion -> Coercion -> Ordering
coercionKind :: Coercion -> Pair Type
coercionType :: Coercion -> Type

pprCo :: Coercion -> SDoc
pprCoBndr :: ForAllCoBndr -> SDoc
pprCoArg :: CoercionArg -> SDoc


