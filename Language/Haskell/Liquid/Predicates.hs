{-# LANGUAGE ScopedTypeVariables, NoMonomorphismRestriction, TypeSynonymInstances, FlexibleInstances, TupleSections, DeriveDataTypeable, BangPatterns #-}
module Language.Haskell.Liquid.Predicates (
  generatePredicates
  ) where


import Type
import Id   (isDataConWorkId)
import Var
import OccName (mkTyVarOcc)
import Name (mkInternalName)
import Unique (initTyVarUnique)
import TypeRep
import Var
import TyCon
import SrcLoc
import CoreSyn
import CoreUtils (exprType) 
import qualified DataCon as TC
import Outputable hiding (empty)
import IdInfo
import TysWiredIn

import Language.Haskell.Liquid.Bare
import Language.Haskell.Liquid.GhcInterface
import Language.Haskell.Liquid.PredType hiding (exprType)
import Language.Haskell.Liquid.GhcMisc (stringTyVar, tickSrcSpan)
import Language.Haskell.Liquid.RefType hiding (generalize) 
import Language.Haskell.Liquid.Misc
import qualified Language.Haskell.Liquid.Fixpoint as F

import Control.Monad.State
import Control.Applicative      ((<$>))
import qualified Data.Map  as M
import qualified Data.List as L
import qualified Data.Set  as S
import Data.Maybe (fromMaybe)
import Data.List (foldl')
import Control.DeepSeq
import Data.Data hiding (TyCon)

----------------------------------------------------------------------
---- Predicate Environments ------------------------------------------
----------------------------------------------------------------------

consAct info = foldM consCB (initEnv info) $ cbs info

generatePredicates ::  GhcInfo -> ([CoreSyn.Bind CoreBndr], F.SEnv PrType)
generatePredicates info = {-trace ("Predicates\n" ++ show γ ++ "PredCBS" ++ show cbs')-} (cbs', nPd)
  where -- WHAT?! All the predicate constraint stuff is DEAD CODE?!!
        -- γ    = fmap removeExtPreds (penv $ evalState act (initPI $ tconsP $ spec info))
        -- act  = consAct info
        cbs' = addPredApp nPd <$> cbs info
        nPd  = getNeedPd $ spec info

-- removeExtPreds (RAllP pv t) = removeExtPreds (substPvar (M.singleton (uPVar pv) top) <$> t) 
-- removeExtPreds t            = t


instance Show CoreBind where
  show = showSDoc . ppr

γ += (x, t) = γ { penv = F.insertSEnv x t (penv γ)}
γ ??= x = F.lookupSEnv x γ


γ ?= x 
  = case (F.lookupSEnv x (penv γ)) of 
      Just t  -> refreshTy t
      Nothing -> error $ "SEnvlookupR: unknown = " ++ showPpr x

data PCGEnv 
  = PCGE { loc   :: !SrcSpan            -- ^ Source position corresponding to environment
         , penv  :: !(F.SEnv PrType)    -- ^ Map from (program) variables to PrType
         }

data PInfo 
  = PInfo { freshIndex :: !Integer
          , pMap       :: !(M.Map UsedPVar Predicate)
          , pvMap      :: !(F.SEnv RPVar)               -- ^ Map from (Used) PVar names to actual definitions, used to generalize
          , hsCsP      :: ![SubC]
          , tyCons     :: !(M.Map TyCon TyConP)
          , symbolsP   :: !(M.Map F.Symbol F.Symbol)
          }

data SubC    
  = SubC { senv :: !PCGEnv
         , lhs  :: !PrType
         , rhs  :: !PrType
         }

addId x y = modify $ \s -> s{symbolsP = M.insert x y (symbolsP s)}

initPI x = PInfo { freshIndex = 1
                 , pMap       = M.empty
                 , pvMap      = F.emptySEnv 
                 , hsCsP      = []
                 , tyCons     = M.fromList x
                 , symbolsP   = M.empty
                 }

type PI = State PInfo

consCB' γ (NonRec x e)
  = do t <- consE γ e
       return $ γ += (varSymbol x, t)

consCB' γ (Rec xes) 
  = do ts       <- mapM (\e -> freshTy $ exprType e) es
       let γ'   = foldl' (+=) γ (zip vs ts)
       zipWithM_ (cconsE γ') es ts
       return $ foldl' (+=) γ (zip vs ts)
    where (xs, es) = unzip xes
          vs       = varSymbol <$> xs

checkOneToOne :: [(Predicate, Predicate)] -> Bool
checkOneToOne xys = and [y1 == y2 | (x1, y1) <- xys, (x2, y2) <- xys, x1 == x2]

tyCheck x Nothing t2
  = False 
tyCheck x (Just t1) t2
  = if b then (checkOneToOne (rmTs ps)) else (error "msg") 
  where (b, (ps, msg)) =  runState (tyC t1 t2) ([], "tyError in " ++ show x ++ show t1 ++ show t2)
        
rmTs = filter rmT        
  where rmT (_, Pr []) = False
        rmT (Pr [], _) = error "tmTs in tyC"
        rmT (_    , _) = True

tyC (RAllP _ t1) t2 
  = tyC (t1 :: PrType) (t2 :: PrType)

tyC t1 (RAllP _ t2) 
  = tyC t1 t2

tyC (RAllT α1 t1) (RAllT (RTV α2) t2) 
  -- = tyC (subsTyVars_meet' [(α1, rVar α2)] t1) t2
  = tyC (subt (α1, (rVar α2 :: RSort)) t1) t2
  
tyC (RVar v1 p1) (RVar v2 p2)
  = do modify $ \(ps, msg) -> ((p2, p1):ps, msg)
       return $ v1 == v2

tyC (RApp c1 ts1 ps1 p1) (RApp c2 ts2 ps2 p2)
  = do modify $ \(ps, msg) -> ((p2, p1):(ps ++ zip (fromRMono "tyC1" <$> ps2) (fromRMono "tyC2" <$> ps1)), msg)
       b <- zipWithM tyC ts1 ts2
       return $ and b && c1 == c2

tyC (RCls c1 _) (RCls c2 _) 
  = return $ c1 == c2

tyC (RFun x t1 t2 p1) (RFun x' t1' t2' p2)
  = do modify $ \(ps, msg) -> ((p2, p1):ps, msg)
       b1 <- tyC t1 t1'
       b2 <- tyC (substParg (x, x') t2) t2'
       return $ b1 && b2

tyC t1 t2 
  = error $ "\n " ++ show t1 ++ "\n" ++ show t2

consCB γ (NonRec x e)
  = do t <- consE γ e
       tg <- generalizeS t
       let ch = tyCheck x ((penv γ) ??= (varSymbol x)) tg
       if (not ch)  then (return $ γ += (varSymbol x, tg)) else (return γ)

consCB γ (Rec xes) 
  = do ts       <- mapM (\e -> freshTy $ exprType e) es
       let γ'   = foldl' (+=) γ (zip vs ts)
       zipWithM_ (cconsE γ') es ts
       tsg      <- forM ts generalizeS
       return $ foldl' (+=) γ (zip vs tsg)
    where (xs, es) = unzip xes
          vs       = varSymbol <$> xs

consE γ (Var x)
  = do t<- γ ?= (varSymbol x)
       return t
consE _ e@(Lit c) 
  = do t <- freshTy τ
       return t
   where τ = exprType e

consE γ (App e (Type τ)) 
  = do RAllT α te <- liftM (checkAll ("Non-all TyApp with expr", e)) $ consE γ e
       return $ subt (α, ofType τ :: RSort) te 
       -- return $ subsTyVars_meet' [(α, ofType τ)]  te

consE γ (App e a)               
  = do RFun x tx t _ <- liftM (checkFun ("PNon-fun App with caller", e)) $ consE γ e 
       cconsE γ a tx 
       case argExpr a of 
         Just e  -> return $ {-traceShow "App" $-} (x, e) `substParg` t
         Nothing -> error $ "consE: App crashes on" ++ showPpr a 

consE γ (Lam α e) | isTyVar α 
  = liftM (RAllT (rTyVar α)) (consE γ e) 

consE γ  e@(Lam x e1) 
  = do tx     <- freshTy τx 
       t1     <- consE (γ += (varSymbol x, tx)) e1
       return $ rFun (varSymbol x) tx t1
    where FunTy τx _ = exprType e 

consE γ e@(Let _ _)       
  = cconsFreshE γ e

consE γ e@(Case _ _ _ _) 
  = cconsFreshE γ e

consE γ (Tick tt e)      
  = consE (γ `putLoc` tickSrcSpan tt) e

consE γ (Cast e _)      
  = consE γ e 

consE _ e	    
  = error $ "consE cannot handle " ++ showPpr e

cconsFreshE γ e
  = do t   <- freshTy $ exprType e
       cconsE γ e t
       return t

argExpr (Var vy)         = Just $ varSymbol vy
argExpr (Lit c)          = Just $ stringSymbol "?"
argExpr (Tick _ e)		 = argExpr e
argExpr e                = error $ "argExpr: " ++ (showPpr e)


cconsE γ (Let b e) t    
  = do γ'  <- consCB' γ b
       cconsE γ' e t 

cconsE γ (Case e x τ cases) t 
  = do γ'  <- consCB' γ $ NonRec x e
       forM_ cases $ cconsCase γ' x t

cconsE γ (Lam α e) (RAllT _ t) | isTyVar α
  = cconsE γ e t

cconsE γ (Lam x e) (RFun y ty t _) 
  | not (isTyVar x) 
  = do cconsE (γ += (varSymbol x, ty)) e te 
       addId y (varSymbol x)
    where te = (y, varSymbol x) `substParg` t

cconsE γ (Tick tt e) t     
  = cconsE (γ `putLoc` tickSrcSpan tt) e t

cconsE γ (Cast e _) t     
  = cconsE γ e t 

cconsE γ e t 
  = do te <- consE γ e
       addC $ SubC γ te t

cconsCase γ _ t (DEFAULT, _, ce)
--  = cconsE γ ce t
  = return ()

cconsCase γ x t (DataAlt c, ys, ce)
  = do tx <- γ ?= varSymbol x
       tc <- γ ?= (varSymbol (TC.dataConWorkId c))
       let (yts, xtt) = unfold tc tx ce
       addC $ SubC γ xtt tx
--       addC $ SubC γ xtt tx
       let cbs = zip (varSymbol <$> ys) yts
       let cγ = foldl' (+=) γ cbs
       cconsE cγ ce t

-- subsTyVars_meet' αts = subsTyVars_meet [(α, toType t, t) | (α, t) <- αts]

unfold tc (RApp _ ts _ _) _ =  (x,  y)
  where (_ , x , y)  = bkArrow tc''
        -- tc''      = subsTyVars_meet' (zip vs ts) tc' 
        tc''         = subts (zip vs (toRSort <$> ts)) tc'
        (vs, _, tc') = bkUniv tc
unfold tc t              x  = error $ "unfold" ++ {-(showSDoc (ppr x)) ++-} " : " ++ show t

-- unfold tc (RApp _ ts _ _) _ =  splitArgsRes tc''
--   where (vs, _, tc') = bkUniv tc
--         tc''         = subsTyVars_meet' (zip vs ts) tc' 
-- unfold tc t              x  = error $ "unfold" ++ {-(showSDoc (ppr x)) ++-} " : " ++ show t

splitC (SubC γ (RAllT _ t1) (RAllT _ t2))
  = splitC (SubC γ t1 t2)

splitC (SubC γ (RAllP _ t1) (RAllP _ t2))
  = splitC (SubC γ t1 t2)

splitC (SubC γ (RFun x1 t11 t12 p1) (RFun x2 t21 t22 p2))
  = [splitBC p1 p2] ++ splitC (SubC γ t21 t11) ++ splitC (SubC γ' t12' t22)
    where t12' = (x1, x2) `substParg` t12
          γ'   = γ += (x2, t21)

splitC (SubC γ (RVar a p1) (RVar a2 p2))        -- UNIFY: Check a == a2?
  = [splitBC p1 p2]

splitC (SubC γ (RApp c1 ts1 ps1 p1) (RApp c2 ts2 ps2 p2)) -- UNIFY: Check c1 == c2?
  = (concatMap splitC (zipWith (SubC γ) ts1 ts2)) 
    ++ [splitBC x y | (RMono x, RMono y) <- zip ps1 ps2] 
    ++ [splitBC p1 p2]

splitC t@(SubC _ t1 t2)
  = {-traceShow ("WARNING : SubC" ++ show t1 ++ show t2) $-} []

-- UNIFYHERE1: Make output [(PVar t, Predicate t)]
splitBC (Pr []) (Pr []) = []
splitBC (Pr []) p2      = [(p2, top)] 
splitBC p1      p2      = [(p1, p2)]

addC c@(SubC _ t1 t2) = modify $ \s -> s {hsCsP = c : (hsCsP s)}

addPredApp γ (NonRec b e) = NonRec b $ thrd $ pExpr γ e
addPredApp γ (Rec ls)     = Rec $ zip xs es'
  where es' = (thrd. pExpr γ) <$> es
        (xs, es) = unzip ls

thrd (_, _, x) = x

pExpr γ e 
  = if (a == 0 && p /= 0) 
     then (0, 0, foldl App e' ps) 
     else (0, p, e')
 where  (a, p, e') = pExprN γ e
        ps = (\n -> stringArg ("p" ++ show n)) <$> [1 .. p]

pExprN γ (App e1 e2) = 
  let (a2, p2, e2') = pExprN γ e2 in 
  if (a1 == 0)
   then (0, 0, (App (foldl App e1' ps) e2'))
   else (a1-1, p1, (App e1' e2'))
 where ps = (\n -> stringArg ("p" ++ show n)) <$> [1 .. p1]
       (a1, p1, e1') = pExprN γ e1

pExprN γ (Lam x e) = (0, 0, Lam x e')
  where (_, _, e') = pExpr γ e

pExprN γ (Var v) | isSpecialId γ v
  = (a, p, (Var v))
    where (a, p) = varPredArgs γ v

pExprN γ (Var v) = (0, 0, Var v)

pExprN γ (Let (NonRec x1 e1) e) = (0, 0, Let (NonRec x1 e1') e')
 where (_, _, e') = pExpr γ e
       (_, _, e1') = pExpr γ e1

pExprN γ (Let bds e) = (0, 0, Let bds' e')
 where (_, _, e') = pExpr γ e
       bds' = addPredApp γ bds
pExprN γ (Case e b t es) = (0, 0, Case e' b t (map (pExprNAlt γ ) es))
  where e' = thrd $ pExpr γ e

pExprN γ (Tick n e) = (a, p, Tick n e')
 where (a, p, e') = pExprN γ e

pExprN γ e@(Type _) = (0, 0, e)
pExprN γ e@(Lit _) = (0, 0, e)
pExprN γ e = (0, 0, e)

pExprNAlt γ (x, y, e) = (x, y, e')
 where e' = thrd $ pExpr γ e

stringArg s = Var $ mkGlobalVar idDet name predType idInfo
  where  idDet = coVarDetails
         name  = mkInternalName initTyVarUnique occ noSrcSpan
         occ = mkTyVarOcc s 
         idInfo = vanillaIdInfo

isSpecialId γ x = pl /= 0
  where (_, pl) = varPredArgs γ x
varPredArgs γ x = varPredArgs_ (γ ??= (varSymbol x))
varPredArgs_ Nothing = (0, 0)
varPredArgs_ (Just t) = (length vs, length ps)
  where (vs, ps, _) = bkUniv t

generalizeS t 
  = do hsCs  <- getRemoveHsCons
       _     <- addToMap ((concat (concatMap splitC hsCs)))
       su    <- pMap  <$> get
       pvm   <- pvMap <$> get
       return $ generalize pvm $ substPvar su <$> t

-- splitCons :: PI () 
-- splitCons = getRemoveHsCons >>= (addToMap . concat . concatMap splitC)
--           = do hsCs <- getRemoveHsCons
--                addToMap ((concat (concatMap splitC hsCs)))

getRemoveHsCons 
  = do s <- get
       let cs = hsCsP s
       put s { hsCsP = [] }
       return cs

-- UNIFYHERE2: normalize m to make sure RHS does not contain LHS Var,
addToMap substs 
  = do s  <- get
       put $ s { pMap = foldl' updateSubst (pMap s) substs}

addToPVMap pv 
  = do s <- get
       put $ s { pvMap = F.insertSEnv (pname pv) pv (pvMap s) }

updateSubst :: M.Map UsedPVar Predicate -> (Predicate, Predicate) -> M.Map UsedPVar Predicate 
updateSubst m (p, p') = foldr (uncurry M.insert) m binds -- PREDARGS: what if it is already in the Map?!!!
  where binds = unifiers $ unifyVars (substPvar m p) (substPvar m p')

unifyVars (Pr v1s) (Pr v2s) = (v1s L.\\ vs, v2s L.\\ vs) 
  where vs  = L.intersect v1s v2s

unifiers ([], vs') = [(v', top)     | v' <- vs']
unifiers (vs, vs') = [(v , Pr vs')  | v  <- vs ]

initEnv info = PCGE { loc = noSrcSpan , penv = F.fromListSEnv bs }
  where dflts  = [(x, ofType $ varType x) | x <- freeVs ]
        dcs    = [(x, dconTy $ varType x) | x <- dcons  ]
        sdcs   = [(TC.dataConWorkId x, dataConPtoPredTy y) | (x, y) <- dconsP (spec info)]
        assms  = passm $ tySigs $ spec info
        bs     = mapFst varSymbol <$> (dflts ++ dcs ++ assms ++ sdcs)
        freeVs = [v | v<-importVars $ cbs info]
        dcons  = filter isDataConWorkId freeVs

getNeedPd spec 
  = F.fromListSEnv bs
    where  dcs   = [(TC.dataConWorkId x, dataConPtoPredTy y) | (x, y) <- dconsP spec]
           assms = passm $ tySigs spec 
           bs    = mapFst varSymbol <$> (dcs ++ assms)

passm = fmap (mapSnd (mapReft ur_pred)) 

-- PREDARGS: why are we even generalizing here?
dconTy t = generalize F.emptySEnv $ dataConTy vps t
  where vs  = tyVars t
        ps  = truePr <$> vs 
        vps = M.fromList $ zipWith (\v p -> (RTV v, RVar (RTV v) p)) vs ps

tyVars (ForAllTy v t) = v : (tyVars t)
tyVars t              = []

---------------------------------- Freshness -------------------------------------

freshInt = do pi <- get 
              let n = freshIndex pi
              put $ pi {freshIndex = n+1} 
              return n

stringSymbol  = F.S
freshSymbol s = stringSymbol . (s++) . show <$> freshInt
truePr _      = top

-- freshPr a     = (\n -> PV n a [])     <$> freshSymbol "p"
-- freshPrAs p   = (\n -> p {pname = n}) <$> freshSymbol "p"

freshPr a     = mkFreshPr (\n -> PV n a [])
freshPrAs pv  = mkFreshPr (\n -> pv { pname = n })

mkFreshPr f   = do pv    <- f <$> freshSymbol "p"
                   addToPVMap pv 
                   return $ pdVar pv


refreshTy t 
  = do fps <- mapM freshPrAs ps
       return $ substPvar (M.fromList (zip ups fps)) <$> t''
   where ups          = uPVar <$> ps
         (vs, ps, t') = bkUniv t
         t''          = mkUnivs vs [] t' 

freshTy t 
  | isPredTy t
  = return $ freshPredTree $ (classifyPredType t)
freshTy t@(TyVarTy v) 
  = liftM (RVar (RTV v)) (freshPr (ofType t :: RSort))
freshTy (FunTy t1 t2) 
  = liftM3 rFun (freshSymbol "s") (freshTy t1) (freshTy t2)
freshTy t@(TyConApp c τs) 
  | TyCon.isSynTyCon c
  = freshTy $ substTyWith αs τs τ
  where (αs, τ) = TyCon.synTyConDefn c
freshTy t@(TyConApp c τs) 
  = liftM3 (rApp c) (mapM freshTy τs) (freshTyConPreds c τs) (return (truePr t)) 
freshTy (ForAllTy v t) 
  = liftM (RAllT (rTyVar v)) (freshTy t) 
freshTy t
  = error "freshTy"

freshPredTree (ClassPred c ts)
  = RCls c (ofType <$> ts)

-- PREDARGS : this function is /super/ ugly to read.

freshTyConPreds c τs
 = do s <- get
      case (M.lookup c (tyCons s)) of 
        Just x  -> liftM (RMono <$>) $ mapM freshPrAs 
                      ((\t -> foldr subt t (zip (freeTyVarsTy x) ts)) <$> freePredTy x)
        Nothing -> return ([] :: [Ref Predicate PrType])
   where ts = (ofType <$> τs) :: [RSort] 
   
checkFun _ t@(RFun _ _ _ _) = t
checkFun x t                = error $ showPpr x ++ "type: " ++ showPpr t

checkAll _ t@(RAllT _ _)    = t
checkAll x t                = error $ showPpr x ++ "type: " ++ showPpr t

γ `putLoc` src
  | isGoodSrcSpan src = γ { loc = src } 
  | otherwise = γ


-- | Generalize free predicates: used on Rec Definitions? 
-- Requires an environment of predicate definitions.

generalize pvm        = generalize_ pvm freePreds
-- generalizeArgs        = generalize_ freeArgPreds

generalize_ pvm f t   = mkUnivs vs ps t' 
  where (vs, ps', t') = bkUniv t
        ps            = gps ++ ps'
        gps           = defPVar pvm <$> S.toList (f t)

defPVar pvm pv        = fromMaybe err $ F.lookupSEnv (pname pv) pvm 
  where err           = errorstar $ "Predicate.generalize: No definition for PVar" ++ showPpr pv

freeArgPreds (RFun _ t1 t2 _) = freePreds t1 -- RJ: UNIFY What about t2?
freeArgPreds (RAllT _ t)      = freeArgPreds t
freeArgPreds (RAllP _ t)      = freeArgPreds t
freeArgPreds t                = freePreds t

-- freePreds :: PrType -> S.Set (Predicate)
freePreds (RVar _ p)       = S.fromList $ pvars p
freePreds (RAllT _ t)      = freePreds t 
freePreds (RAllP p t)      = S.delete (uPVar p) $ freePreds t 
freePreds (RCls _ ts)      = foldl' (\z t -> S.union z (freePreds t)) S.empty ts
freePreds (RFun _ t1 t2 _) = S.union (freePreds t1) (freePreds t2)
freePreds (RApp _ ts ps p) = unions ((S.fromList (concatMap pvars (p:((fromRMono "freePreds") <$> ps)))) : (freePreds <$> ts))


-- substPvar :: M.Map RPVar Predicate -> Predicate -> Predicate 
substPvar s = (\(Pr πs) -> pdAnd (lookupP s <$> πs))

lookupP s pv 
  = case M.lookup pv s of 
      Nothing -> pdVar pv
      Just p' -> subvPredicate (\pv' -> pv' { pargs = pargs pv }) p'
 
-- lookupP ::  M.Map (PVar a) Predicate -> PVar b -> Predicate
-- lookupP s p@(PV _ _ s')
--   = case M.lookup p s of 
--       Nothing  -> Pr [p]
--       Just q   -> subvPredicate (\pv -> pv { pargs = s'}) q

   

