{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE BangPatterns #-}
module Bio.Motif
    ( PWM(..)
    , size
    , subPWM
    , rcPWM
    , gcContentPWM
    , Motif(..)
    , Bkgd(..)
    , toPWM
    , ic
    , scores
    , scores'
    , score
    , optimalScore
    , CDF
    , cdf
    , cdf'
    , scoreCDF
    , pValueToScore
    , pValueToScoreExact
    , toIUPAC
    , readMEME
    , toMEME
    , fromMEME
    , writeMEME
    , writeFasta

    -- * References
    -- $references
    ) where

import Prelude hiding (sum)
import Control.Arrow ((&&&))
import Control.Monad.State.Lazy
import qualified Data.ByteString.Char8 as B
import Data.Conduit
import Data.Double.Conversion.ByteString (toShortest)
import Data.Default.Class
import Data.List (sortBy, foldl')
import Data.Maybe (fromJust, isNothing)
import Data.Ord (comparing)
import qualified Data.Vector as V
import qualified Data.Vector.Mutable as VM
import qualified Data.Vector.Unboxed as U
import qualified Data.Vector.Algorithms.Intro as I
import qualified Data.Matrix.Unboxed as M
import Text.Printf (printf)

import Bio.Seq
import Bio.Utils.Misc (readDouble, readInt)
import Bio.Utils.Functions (binarySearchBy)

-- | k x 4 position weight matrix for motifs
data PWM = PWM
    { _nSites :: !(Maybe Int)  -- ^ number of sites used to generate this matrix
    , _mat :: !(M.Matrix Double)
    } deriving (Show)

size :: PWM -> Int
size (PWM _ mat) = M.rows mat

-- | information content of a poistion in pwm
ic :: PWM -> Int -> Double
ic = undefined

-- | extract sub-PWM given starting position and length, zero indexed
subPWM :: Int -> Int -> PWM -> PWM
subPWM i l (PWM n mat) = PWM n $ M.subMatrix (i,0) (i+l,3) mat
{-# INLINE subPWM #-}

-- | reverse complementary of PWM
rcPWM :: PWM -> PWM
rcPWM (PWM n mat) = PWM n . M.fromVector d . U.reverse . M.flatten $ mat
  where
    d = M.dim mat
{-# INLINE rcPWM #-}

-- | GC content of PWM
gcContentPWM :: PWM -> Double
gcContentPWM (PWM _ mat) = loop 0 0 / fromIntegral m
  where
    m = M.rows mat
    loop !acc !i | i >= m = acc
                 | otherwise =
                     let acc' = acc + M.unsafeIndex mat (i,1) + M.unsafeIndex mat (i,2)
                     in loop acc' (i+1)

data Motif = Motif
    { _name :: !B.ByteString
    , _pwm :: !PWM
    } deriving (Show)

-- | background model which consists of single nucletide frequencies, and di-nucletide
-- frequencies
newtype Bkgd = BG (Double, Double, Double, Double)

instance Default Bkgd where
    def = BG (0.25, 0.25, 0.25, 0.25)

-- | convert pwm to consensus sequence, see D. R. Cavener (1987).
toIUPAC :: PWM -> DNA IUPAC
toIUPAC (PWM _ pwm) = fromBS . B.pack . map f $ M.toRows pwm
  where
    f v | snd a > 0.5 && snd a > 2 * snd b = fst a
        | snd a + snd b > 0.75             = iupac (fst a, fst b)
        | otherwise                        = 'N'
      where
        [a, b, _, _] = sortBy (flip (comparing snd)) $ zip "ACGT" $ U.toList v
    iupac x = case sort' x of
        ('A', 'C') -> 'M'
        ('G', 'T') -> 'K'
        ('A', 'T') -> 'W'
        ('C', 'G') -> 'S'
        ('C', 'T') -> 'Y'
        ('A', 'G') -> 'R'
        _ -> undefined
    sort' (x, y) | x > y = (y, x)
                 | otherwise = (x, y)

-- | get scores of a long sequences at each position
scores :: Bkgd -> PWM -> DNA a -> [Double]
scores bg p@(PWM _ pwm) dna = go $! toBS dna
  where
    go s | B.length s >= len = scoreHelp bg p (B.take len s) : go (B.tail s)
         | otherwise = []
    len = M.rows pwm
{-# INLINE scores #-}

-- | a streaming version of scores
scores' :: Monad m => Bkgd -> PWM -> DNA a -> Source m Double
scores' bg p@(PWM _ pwm) dna = go 0
  where
    go i | i < n - len + 1 = do yield $ scoreHelp bg p $ B.take len $ B.drop i s
                                go (i+1)
         | otherwise = return ()
    s = toBS dna
    n = B.length s
    len = M.rows pwm
{-# INLINE scores' #-}

score :: Bkgd -> PWM -> DNA a -> Double
score bg p dna = scoreHelp bg p $! toBS dna
{-# INLINE score #-}

-- | the best possible score for a pwm
optimalScore :: Bkgd -> PWM -> Double
optimalScore (BG (a, c, g, t)) (PWM _ pwm) = foldl' (+) 0 . map f . M.toRows $ pwm
  where f xs = let (i, s) = U.maximumBy (comparing snd) .
                                U.zip (U.fromList ([0..3] :: [Int])) $ xs
               in case i of
                   0 -> log $ s / a
                   1 -> log $ s / c
                   2 -> log $ s / g
                   3 -> log $ s / t
                   _ -> undefined
{-# INLINE optimalScore #-}

scoreHelp :: Bkgd -> PWM -> B.ByteString -> Double
scoreHelp (BG (a, c, g, t)) (PWM _ pwm) dna = fst . B.foldl f (0,0) $ dna
  where
    f (!acc,!i) x = (acc + sc, i+1)
      where
        sc = case x of
              'A' -> log $! matchA / a
              'C' -> log $! matchC / c
              'G' -> log $! matchG / g
              'T' -> log $! matchT / t
              'N' -> 0
              'V' -> log $! (matchA + matchC + matchG) / (a + c + g)
              'H' -> log $! (matchA + matchC + matchT) / (a + c + t)
              'D' -> log $! (matchA + matchG + matchT) / (a + g + t)
              'B' -> log $! (matchC + matchG + matchT) / (c + g + t)
              'M' -> log $! (matchA + matchC) / (a + c)
              'K' -> log $! (matchG + matchT) / (g + t)
              'W' -> log $! (matchA + matchT) / (a + t)
              'S' -> log $! (matchC + matchG) / (c + g)
              'Y' -> log $! (matchC + matchT) / (c + t)
              'R' -> log $! (matchA + matchG) / (a + g)
              _   -> error "Bio.Motif.score: invalid nucleotide"
        matchA = addSome $ M.unsafeIndex pwm (i,0)
        matchC = addSome $ M.unsafeIndex pwm (i,1)
        matchG = addSome $ M.unsafeIndex pwm (i,2)
        matchT = addSome $ M.unsafeIndex pwm (i,3)
        addSome !y | y == 0 = pseudoCount
                   | otherwise = y
        pseudoCount = 0.0001
{-# INLINE scoreHelp #-}

-- | the probability that a kmer is generated by background (0-orderd model)
pBkgd :: Bkgd -> B.ByteString -> Double
pBkgd (BG (a, c, g, t)) = B.foldl' f 1
  where
    f acc x = acc * sc
      where
        sc = case x of
              'A' -> a
              'C' -> c
              'G' -> g
              'T' -> t
              _ -> undefined
{-# INLINE pBkgd #-}


-- | unlike pValueToScore, this version compute the exact score but much slower
-- and is inpractical for long motifs
pValueToScoreExact :: Double -- ^ desirable p-Value
              -> Bkgd
              -> PWM
              -> Double
pValueToScoreExact p bg pwm = go 0 0 . sort' . map ((scoreHelp bg pwm &&& pBkgd bg) . B.pack) . replicateM l $ "ACGT"
  where
    sort' xs = U.create $ do v <- U.unsafeThaw . U.fromList $ xs
                             I.sortBy (flip (comparing fst)) v
                             return v
    go !acc !i vec | acc > p = fst $ vec U.! (i - 1)
                   | otherwise = go (acc + snd (vec U.! i)) (i+1) vec
    l = size pwm

-- | calculate the minimum motif mathching score that would produce a kmer with
-- p-Value less than the given number. This score would then be used to search
-- for motif occurrences with significant p-Value
pValueToScore :: Double -> Bkgd -> PWM -> Double
pValueToScore p bg pwm = cdf' (scoreCDF bg pwm) $ 1 - p

newtype CDF = CDF (V.Vector (Double, Double))

-- P(X <= x)
cdf :: CDF -> Double -> Double
cdf (CDF v) x = let i = binarySearchBy cmp v x
                in case () of
                    _ | i >= n -> snd $ V.last v
                      | i == 0 -> if x == fst (V.head v) then snd (V.head v) else 0.0
                      | otherwise -> let (a, a') = v V.! (i-1)
                                         (b, b') = v V.! i
                                         α = (b - x) / (b - a)
                                         β = (x - a) / (b - a)
                                     in α * a' + β * b'
  where
    cmp (a,_) = compare a
    n = V.length v
{-# INLINE cdf #-}

-- the inverse of cdf
cdf' :: CDF -> Double -> Double
cdf' (CDF v) p
    | p > 1 || p < 0 = error "p must be in [0,1]"
    | otherwise = let i = binarySearchBy cmp v p
                  in case () of
                      _ | i >= n -> 1/0
                        | i == 0 -> if p == snd (V.head v) then fst (V.head v) else undefined
                        | otherwise -> let (a, a') = v V.! (i-1)
                                           (b, b') = v V.! i
                                           α = (b' - p) / (b' - a')
                                           β = (p - a') / (b' - a')
                                       in α * a + β * b
  where
    cmp (_,a) = compare a
    n = V.length v
{-# INLINE cdf' #-}

-- approximate the cdf of motif matching scores
scoreCDF :: Bkgd -> PWM -> CDF
scoreCDF (BG (a,c,g,t)) pwm = toCDF $ loop (V.singleton 1, const 0) 0
  where
    loop (prev,scFn) i
        | i < n =
            let (lo,hi) = minMax (1/0,-1/0) 0
                nBin' = min 100000 $ ceiling $ (hi - lo) / precision
                step = (hi - lo) / fromIntegral nBin'
                idx x = let j = truncate $ (x - lo) / step
                        in if j >= nBin' then nBin' - 1 else j
                v = V.create $ do
                    new <- VM.replicate nBin' 0
                    V.sequence_ $ flip V.imap prev $ \x p ->
                        when (p /= 0) $ do
                            let idx_a = idx $ sc + log' (M.unsafeIndex (_mat pwm) (i,0)) - log a
                                idx_c = idx $ sc + log' (M.unsafeIndex (_mat pwm) (i,1)) - log c
                                idx_g = idx $ sc + log' (M.unsafeIndex (_mat pwm) (i,2)) - log g
                                idx_t = idx $ sc + log' (M.unsafeIndex (_mat pwm) (i,3)) - log t
                                sc = scFn x
                            new `VM.read` idx_a >>= VM.write new idx_a . (a * p + )
                            new `VM.read` idx_c >>= VM.write new idx_c . (c * p + )
                            new `VM.read` idx_g >>= VM.write new idx_g . (g * p + )
                            new `VM.read` idx_t >>= VM.write new idx_t . (t * p + )
                    return new
            in loop (v, \x -> (fromIntegral x + 0.5) * step + lo) (i+1)
        | otherwise = (prev, scFn)
      where
        minMax (l,h) x
            | x >= V.length prev = (l,h)
            | prev V.! x /= 0 =
                let sc = scFn x
                    s1 = sc + log' (M.unsafeIndex (_mat pwm) (i,0)) - log a
                    s2 = sc + log' (M.unsafeIndex (_mat pwm) (i,1)) - log c
                    s3 = sc + log' (M.unsafeIndex (_mat pwm) (i,2)) - log g
                    s4 = sc + log' (M.unsafeIndex (_mat pwm) (i,3)) - log t
                 in minMax (foldr min l [s1,s2,s3,s4],foldr max h [s1,s2,s3,s4]) (x+1)
            | otherwise = minMax (l,h) (x+1)
    toCDF (v, scFn) = CDF $ V.imap (\i x -> (scFn i, x)) $ V.scanl1 (+) v
    precision = 0.002
    n = size pwm
    log' x | x == 0 = log 0.001
           | otherwise = log x
{-# INLINE scoreCDF #-}

-- | get pwm from a matrix
toPWM :: [B.ByteString] -> PWM
toPWM x = PWM Nothing . M.fromLists . map (map readDouble.B.words) $ x

-- | pwm to bytestring
fromPWM :: PWM -> B.ByteString
fromPWM = B.unlines . map (B.unwords . map toShortest) . M.toLists . _mat

writeFasta :: FilePath -> [Motif] -> IO ()
writeFasta fl motifs = B.writeFile fl contents
  where
    contents = B.unlines . concatMap f $ motifs
    f x = [">" `B.append` _name x, fromPWM $ _pwm x]

readMEME :: FilePath -> IO [Motif]
readMEME = liftM fromMEME . B.readFile

writeMEME :: FilePath -> [Motif] -> Bkgd -> IO ()
writeMEME fl xs bg = B.writeFile fl $ toMEME xs bg

toMEME :: [Motif] -> Bkgd -> B.ByteString
toMEME xs (BG (a,c,g,t)) = B.intercalate "" $ header : map f xs
  where
    header = B.pack $ printf "MEME version 4\n\nALPHABET= ACGT\n\nstrands: + -\n\nBackground letter frequencies\nA %f C %f G %f T %f\n\n" a c g t
    f (Motif nm pwm) =
        let x = "MOTIF " `B.append` nm
            y = B.pack $ printf "letter-probability matrix: alength= 4 w= %d nsites= %d E= 0" (size pwm) sites
            z = B.unlines . map (B.unwords . ("":) . map toShortest) . M.toLists . _mat $ pwm
            sites | isNothing (_nSites pwm) = 0
                  | otherwise = fromJust $ _nSites pwm
        in B.unlines [x,y,z]
{-# INLINE toMEME #-}

fromMEME :: B.ByteString -> [Motif]
fromMEME meme = evalState (go $ B.lines meme) (0, [])
  where
    go :: [B.ByteString] -> State (Int, [B.ByteString]) [Motif]
    go (x:xs)
      | "MOTIF" `B.isPrefixOf` x = put (1, [B.drop 6 x]) >> go xs
      | otherwise = do
          (st, str) <- get
          case st of
              1 -> do when (startOfPwm x) $ put (2, str ++ [B.words x !! 7])
                      go xs
              2 -> let x' = B.dropWhile (== ' ') x
                   in if B.null x'
                         then do put (0, [])
                                 r <- go xs
                                 return (toMotif str : r)
                         else put (2, str ++ [x']) >> go xs
              _ -> go xs
    go [] = do (st, str) <- get
               return [toMotif str | st == 2]
    startOfPwm = B.isPrefixOf "letter-probability matrix:"
    toMotif (name:n:xs) = Motif name pwm
      where
        pwm = PWM (Just $ readInt n) $ M.fromLists . map (map readDouble.B.words) $ xs
    toMotif _ = error "error"
{-# INLINE fromMEME #-}

-- $references
--
-- * Douglas R. Cavener. (1987) Comparison of the consensus sequence flanking
-- translational start sites in Drosophila and vertebrates.
-- /Nucleic Acids Research/ 15 (4): 1353–1361.
-- <doi:10.1093/nar/15.4.1353 http://nar.oxfordjournals.org/content/15/4/1353>
