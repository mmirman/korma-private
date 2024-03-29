{-# LANGUAGE
 DeriveFunctor,
 ViewPatterns,
 FlexibleContexts
 #-}

module RangeUnification where

import Data.Functor ((<$>))
import Data.Monoid
import Control.Monad.RWS.Lazy


data LatticeVar a = LatticeRange a a
                  | LatticeVar Int
                  deriving (Eq, Read, Ord, Show)
                           
substVar :: Eq a => LatticeVar a -> LatticeVar a -> LatticeVar a -> LatticeVar a
substVar s b a | a == s = b
substVar _ _ a = a

substVal :: (RangeUnifiable a, Eq a) => LatticeVar a -> a -> LatticeVar a -> a
substVal s b a | a == s = b
substVal _ _ a = vToE a
                 
                 
class Lattice a where
  top :: a
  bot :: a
  glb :: a -> a -> (a, LatticeVar a ->  LatticeVar a)
  lub :: a -> a -> (a, LatticeVar a ->  LatticeVar a)
  
class RangeUnifiable a where
  topVariable :: a -> Maybe (LatticeVar a)
  reduce :: a -> a -> [RangeInequality a]
  replaceVars :: LatticeVar a -> a -> a -> a
  vToE :: LatticeVar a -> a
  occurs :: LatticeVar a -> a -> Bool


data RangeInequality a = RIneq a a
                       deriving (Show, Eq, Ord, Functor)

instance Monoid Bool where
  mempty = False
  mappend = (||)



getLVar :: (RangeUnifiable a, Monad m, MonadState Int m) => m a
getLVar = do
  i <- get
  put (i+1)
  return $ vToE $ LatticeVar i
  
  
-- | 'refineUnifiedMap' builds a new map out of the original map which contains
-- as few variable-variable references as possible.  It is worthwhile noting that
-- this is incredibly inneficient, as the new map will need to be calculated every
-- time we call the function.  It is however a very short definition.
refineUnifiedMap :: (Eq a, RangeUnifiable a, Ord a) => (LatticeVar a -> a) -> LatticeVar a -> a
refineUnifiedMap mp = rum mempty . mp
  where rum remembered v@(topVariable -> Just var) = case var of
            _ | remembered var -> v
            LatticeRange a b | a == b -> rum (mappend (== var) remembered) a
            _ -> rum (mappend (== var) remembered) (mp var)
        rum _ v = v

-- TODO: add error handling
-- does not currently support non nominal recursive types.
-- however, these can be implemented nominally. 
rangeUnify :: (Show a, Eq a, Lattice a, RangeUnifiable a) => [RangeInequality a] -> LatticeVar a -> a
rangeUnify [] = vToE
rangeUnify (RIneq a b:l) | a == b = rangeUnify l
rangeUnify (RIneq a b:l) = case (topVariable a, topVariable b) of
  (Nothing, Nothing) -> rangeUnify $ (reduce a b)++l
  (Just s, Just t) -> case (s,t) of
    (LatticeRange _ _, LatticeVar _) -> replv t s
    (LatticeVar _, _) -> replv s t    
    
    (LatticeRange sL sU, LatticeRange tL tU) -> case (sU == top, tL == bot) of 
      (True , True  ) -> rangeUnify $ (RIneq sL tU):l      
      (True , False ) -> replr s (sL,tL)
      (False, True  ) -> replr t (sU,tU)
      (False, False ) -> rangeUnify (fmap (repS . repT) <$> (RIneq sU' tL':l)) . replS . replT . subS . subT
        where (tL', subT) = lub tL sU
              (sU', subS) = glb sU tL
              
              (replS, repS) = getRepl s $ LatticeRange sL sU'
              (replT, repT) = getRepl t $ LatticeRange tL' tU
              
  (Just s@(LatticeRange aL aU), _) ->  replr s (aL, aU') . sub
    where (aU', sub) = glb aU b
  (Just s@(LatticeVar _), _) -> case occurs s b of
    True  -> error $ "Occurs check: " ++ show s ++" occurs in " ++ show b
    False -> replr s (bot,b)
            
  (_, Just t@(LatticeRange bL bU)) -> replr t (bL', bU) . sub
    where (bL', sub) = lub a bL
  
  (_, Just t@(LatticeVar _)) -> case occurs t a of
    True  -> error $ "Occurs check: " ++ show t ++" occurs in " ++ show a
    False -> replr t (a,top)

  where replr f (a,b) = replv f $ LatticeRange a b
        replv f v = rangeUnify (fmap (replaceVars f $ vToE v) <$> l) . repl
          where repl s | s == f = v
                repl s | otherwise = s
                
        getRepl s s' = (\r -> if r==s then s' else r, replaceVars s $ vToE s')