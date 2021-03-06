module Deptup0 where

import Language.Haskell.Liquid.Prelude

{-@ data Pair a b <p :: x0:a -> x1:b -> Bool> = P (x :: a) (y :: b<p x>) @-} 

data Pair a b = P a b

mkP :: a -> a -> Pair a a 
mkP x y = P x y

incr x = x + 1

baz x  = mkP x (incr x)

chk (P x y) = liquidAssertB (x < y)

prop = chk $ baz n
  where n = choose 100
