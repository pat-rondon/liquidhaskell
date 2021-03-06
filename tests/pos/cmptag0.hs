module Test where

{-@ type OList a = [a]<{v: a | (v >= fld)}> @-}

{-@ foo :: (Ord a) => z:a -> OList a -> [{v:a | z <= v}] @-}
foo y xs = bar y xs

bar :: (Ord a) => a -> [a] -> [a]
bar y []     = []
bar y (x:xs) = case compare y x of 
                 EQ -> xs
                 GT -> bar y xs
                 LT -> x:xs
