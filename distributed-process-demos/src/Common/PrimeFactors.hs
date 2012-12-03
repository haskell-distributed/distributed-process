-- | Prime factorization
--
-- Written by Dan Weston
-- <http://westondan.blogspot.ie/2007/07/simple-prime-factorization-code.html>
module PrimeFactors where

primes :: [Integer]
primes = primes' (2:[3,5..])
  where
    primes' (x:xs) = x : primes' (filter (notDivisorOf x) xs)
    notDivisorOf d n = n `mod` d /= 0

factors :: [Integer] -> Integer -> [Integer]
factors qs@(p:ps) n
    | n <= 1 = []
    | m == 0 = p : factors qs d
    | otherwise = factors ps n
  where
    (d,m) = n `divMod` p

primeFactors :: Integer -> [Integer]
primeFactors = factors primes

numPrimeFactors :: Integer -> Integer
numPrimeFactors = fromIntegral . length . primeFactors
