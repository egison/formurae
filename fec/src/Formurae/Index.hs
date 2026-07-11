{-# LANGUAGE PatternSynonyms #-}

module Formurae.Index where

import Data.Char (isAlpha, isAlphaNum, isDigit)
import Data.List (stripPrefix)

import Formurae.Common (fatal, validSurfaceName)
import Formurae.Syntax

-- Keep the source column on each token.  Most of the tensor parser was
-- written against the small II/IC token algebra, so expose those names as
-- bidirectional patterns while the lexer uses the offset-bearing
-- representation underneath.  Tokens synthesized by transformations have
-- column 0; parsed source tokens always use one-based columns.
data ITok = ITokAt Int ITokValue deriving (Eq, Show)

data ITokValue = IIdent String | IChar Char deriving (Eq, Show)

pattern II :: String -> ITok
pattern II word <- ITokAt _ (IIdent word)
  where II word = ITokAt 0 (IIdent word)

pattern IC :: Char -> ITok
pattern IC char <- ITokAt _ (IChar char)
  where IC char = ITokAt 0 (IChar char)

{-# COMPLETE II, IC #-}

itokOffset :: ITok -> Int
itokOffset (ITokAt offset _) = offset

itokWidth :: ITok -> Int
itokWidth (II word) = length word
itokWidth (IC _) = 1

itok :: String -> [ITok]
itok = go 1
  where
    go _ [] = []
    go column (c:cs)
      | isAlpha c =
          let (a, b) = span (\ch -> isAlphaNum ch || ch == '_' || ch == '~' || ch == '\'') cs
              word = c : a
          in ITokAt column (IIdent word) : go (column + length word) b
      | otherwise = ITokAt column (IChar c) : go (column + 1) cs

ixName :: IxPart -> String
ixName (IxPart _ nm) = nm

parseIndexedIdent :: String -> (String, [IxPart])
parseIndexedIdent w =
  let (base, rest) = break (`elem` "_~") w
  in (base, marks rest)
  where
    marks [] = []
    marks (m:c:rest)
      | m == '~', isAlphaNum c =
          let (nm, rest') = span isAlphaNum (c : rest)
          in IxPart VUp nm : marks rest'
      | m == '_', isAlphaNum c =
          let (nm, rest') = span isAlphaNum (c : rest)
          in IxPart VDown nm : marks rest'
    marks rest = [IxPart VDown rest]

parseMarkedSeq :: String -> Maybe [IxPart]
parseMarkedSeq [] = Just []
parseMarkedSeq (m:c:rest)
  | m == '~', isAlphaNum c =
      let (nm, rest') = span isAlphaNum (c : rest)
      in fmap (IxPart VUp nm :) (parseMarkedSeq rest')
  | m == '_', isAlphaNum c =
      let (nm, rest') = span isAlphaNum (c : rest)
      in fmap (IxPart VDown nm :) (parseMarkedSeq rest')
parseMarkedSeq _ = Nothing

parseMarkedPrefix :: String -> Maybe ([IxPart], String)
parseMarkedPrefix = go []
  where
    go acc (m:c:rest)
      | m == '~', isAlphaNum c =
          let (nm, rest') = span isAlphaNum (c : rest)
          in go (acc ++ [IxPart VUp nm]) rest'
      | m == '_', isAlphaNum c =
          let (nm, rest') = span isAlphaNum (c : rest)
          in go (acc ++ [IxPart VDown nm]) rest'
    go acc rest = Just (acc, rest)

ixSuffix :: IxPart -> String
ixSuffix (IxPart VUp nm) = "~" ++ nm
ixSuffix (IxPart VDown nm) = "_" ++ nm

derivativeOpParts :: String -> Maybe (Int, Int, IxPart)
derivativeOpParts nm = do
  rest0 <- stripPrefix "pd" nm
  let (mDigits, rest1) = span isDigit rest0
  if null mDigits then Nothing else do
    rest2 <- stripPrefix "r" rest1
    let (rDigits, rest3) = span isDigit rest2
    case parseMarkedPrefix rest3 of
      Just ([part], "") | not (null rDigits) ->
        Just (read mDigits, read rDigits, part)
      _ -> Nothing

showIxParts :: [IxPart] -> String
showIxParts = concatMap ixSuffix

isSingleAlphaIx :: IxPart -> Bool
isSingleAlphaIx (IxPart _ [c]) = isAlpha c
isSingleAlphaIx _ = False

sameVarianceParts :: [IxPart] -> Bool
sameVarianceParts [] = True
sameVarianceParts (IxPart v _ : xs) = all (\(IxPart v' _) -> v' == v) xs

sameVarianceList :: [IxPart] -> [IxPart] -> Bool
sameVarianceList xs ys =
  length xs == length ys
  && and [vx == vy | (IxPart vx _, IxPart vy _) <- zip xs ys]

fieldDeclAcceptsParts :: FieldDecl -> [IxPart] -> Bool
fieldDeclAcceptsParts fd parts =
  case fdIndex fd of
    Nothing -> null parts
    Just (FieldIndex (Plain decl)) -> sameVarianceList decl parts
    Just (FieldIndex (Symmetric decl)) ->
      sameVarianceList decl parts || sameVarianceList (reverse decl) parts
    Just (FieldIndex (Antisymmetric decl)) ->
      sameVarianceList decl parts || sameVarianceList (reverse decl) parts

fieldDeclIndexSuffix :: FieldDecl -> String
fieldDeclIndexSuffix fd =
  case fdIndex fd of
    Just (FieldIndex (Plain parts)) -> showIxParts parts
    Just (FieldIndex (Symmetric parts)) -> showIxParts parts
    Just (FieldIndex (Antisymmetric parts)) -> showIxParts parts
    _ -> ""

parseFieldSpec :: String -> Maybe (String, Maybe FieldIndex)
parseFieldSpec spec = do
  let (nm, rest) = span isAlphaNum spec
  if not (validSurfaceName nm) then Nothing else
    case rest of
      "" -> Just (nm, Nothing)
      c:_ | c == '~' || c == '_' -> do
        parts <- parseMarkedSeq rest
        Just (nm, Just (FieldIndex (Plain parts)))
      '{':body | not (null body), last body == '}' -> do
        parts <- parseMarkedSeq (init body)
        Just (nm, Just (FieldIndex (Symmetric parts)))
      '[':body | not (null body), last body == ']' ->
        do parts <- parseMarkedSeq (init body)
           Just (nm, Just (FieldIndex (Antisymmetric parts)))
      _ -> Nothing

inferFieldKind :: Int -> String -> Maybe FieldIndex -> IO Kind
inferFieldKind _ _ Nothing = return Scalar
inferFieldKind ln spec (Just (FieldIndex (Plain parts)))
  | length parts == 1 = return Vector
  | length parts == 2 = return Tensor2
  | otherwise = fatal ("unsupported field rank in " ++ spec ++ " (line " ++ show ln ++ ")")
inferFieldKind ln spec (Just (FieldIndex (Symmetric parts)))
  | length parts == 2 && sameVarianceParts parts = return SymM
  | length parts == 2 = fatal ("symmetric field needs same-variance indices: " ++ spec ++ " (line " ++ show ln ++ ")")
  | otherwise = fatal ("symmetric field must have rank 2: " ++ spec ++ " (line " ++ show ln ++ ")")
inferFieldKind ln spec (Just (FieldIndex (Antisymmetric parts)))
  | length parts == 2 && sameVarianceParts parts = return AntiM
  | length parts == 2 = fatal ("antisymmetric field needs same-variance indices: " ++ spec ++ " (line " ++ show ln ++ ")")
  | otherwise = fatal ("antisymmetric field must have rank 2: " ++ spec ++ " (line " ++ show ln ++ ")")
axisRange :: Model -> [Int]
axisRange m = [1 .. mDim m]

fieldBaseOf :: String -> (String, Int)
fieldBaseOf w = (takeWhile (/= '\'') w, length (filter (== '\'') w))

ixVariance :: IxPart -> Variance
ixVariance (IxPart v _) = v

fieldIndexParts :: FieldDecl -> Maybe [IxPart]
fieldIndexParts fd =
  case fdIndex fd of
    Just (FieldIndex (Plain parts)) -> Just parts
    Just (FieldIndex (Symmetric parts)) -> Just parts
    Just (FieldIndex (Antisymmetric parts)) -> Just parts
    _ -> Nothing

componentRank :: Kind -> Int
componentRank Scalar = 0
componentRank Vector = 1
componentRank (Form k) = k
componentRank SymM = 2
componentRank AntiM = 2
componentRank Tensor2 = 2

choose :: Int -> [a] -> [[a]]
choose 0 _ = [[]]
choose _ [] = []
choose k (x:xs)
  | k < 0 = []
  | otherwise = map (x :) (choose (k - 1) xs) ++ choose k xs

symComponentIndices :: Int -> [[Int]]
symComponentIndices dim =
  [[a, a] | a <- [1 .. dim]] ++ [[a, b] | a <- [1 .. dim], b <- [a + 1 .. dim]]

antiComponentIndices :: Int -> [[Int]]
antiComponentIndices dim =
  [[a, b] | a <- [1 .. dim], b <- [a + 1 .. dim]]

componentIndices :: Int -> Kind -> [[Int]]
componentIndices _ Scalar = [[]]
componentIndices dim Vector = [[a] | a <- [1 .. dim]]
componentIndices dim (Form k) = choose k [1 .. dim]
componentIndices dim SymM = symComponentIndices dim
componentIndices dim AntiM = antiComponentIndices dim
componentIndices dim Tensor2 = [[a, b] | a <- [1 .. dim], b <- [1 .. dim]]

rank2Pairs :: [[Int]] -> [(Int, Int)]
rank2Pairs = map pairOf
  where
    pairOf [a, b] = (a, b)
    pairOf xs = error ("internal rank-2 component shape: " ++ show xs)

internalCoordNames :: Model -> [String]
internalCoordNames m = take (mDim m) ["x", "y", "z"]

isIndexKind :: Maybe Kind -> Bool
isIndexKind (Just Vector) = True
isIndexKind (Just SymM) = True
isIndexKind (Just AntiM) = True
isIndexKind (Just Tensor2) = True
isIndexKind _ = False
