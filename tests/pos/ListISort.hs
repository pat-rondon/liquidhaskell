module ListSort where

import Language.Haskell.Liquid.Prelude -- (liquidAssertB, choose)

{-@ assert inSort :: (Ord a) => xs:[a] -> {v: [a]<{v: a | (v >= fld)}> | len(v) = len(xs)} @-}
inSort        :: (Ord a) => [a] -> [a]
inSort []     = []
inSort (x:xs) = insert x (inSort xs) 

{-@ assert insertSort :: (Ord a) => xs:[a] -> [a]<{v: a | (v >= fld)}>  @-}
-- insertSort :: (Ord a) => [a] -> [a]
insertSort xs                 = foldr insert [] xs

{-@ assert insert      :: (Ord a) => x:a -> xs: [a]<{v: a | (v >= fld)}> -> {v: [a]<{v: a | (v >= fld)}> | len(v) = (1 + len(xs)) } @-}
insert y []                   = [y]
insert y (x : xs) | y <= x    = y : x : xs 
                  | otherwise = x : insert y xs

-- checkSort ::  (Ord a) => [a] -> Bool
checkSort []                  = liquidAssertB True
checkSort [_]                 = liquidAssertB True
checkSort (x1:x2:xs)          = liquidAssertB (x1 <= x2) && checkSort (x2:xs)

-----------------------------------------------------------------------

bar   = insertSort rlist
rlist = map choose [1 .. 10]

bar1  :: [Int]
bar1  = [1, 2, 4, 5]

prop0 = checkSort bar
prop1 = checkSort bar1
-- prop2 = checkSort [3, 1, 2] 
