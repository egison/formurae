{-# LANGUAGE PatternSynonyms #-}

module Formurae.Index where

import Data.Char (isAlpha, isAlphaNum, isDigit)
import Data.List (find, group, sort, stripPrefix)

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

-- | Parse the identifier and marked indices at the start of a binding
-- target.  Unlike 'parseIndexedIdent', this also returns the unconsumed
-- suffix, so the equation parser can distinguish the left-hand-side indices
-- from the following @=@.  Index names follow Egison identifiers rather than
-- being restricted to one letter.
parseIndexedTargetPrefix :: String -> Maybe (IndexedTarget, String)
parseIndexedTargetPrefix source = do
  (name, rest) <- identifierPrefix source
  (indices, suffix) <- parseMarkedPrefix rest
  Just (IndexedTarget name indices, suffix)

-- | Parse an indexed next-time target such as @X'~i@.  The prime is part of
-- the time-slot syntax, not part of the bound field name.
parsePrimedIndexedTargetPrefix :: String -> Maybe (IndexedTarget, String)
parsePrimedIndexedTargetPrefix source = do
  (name, rest) <- identifierPrefix source
  suffix <- stripPrefix "'" rest
  (indices, trailing) <- parseMarkedPrefix suffix
  Just (IndexedTarget name indices, trailing)

identifierPrefix :: String -> Maybe (String, String)
identifierPrefix source =
  case source of
    c : rest | isAlpha c ->
      let (tailName, suffix) = span isAlphaNum rest
          name = c : tailName
      in if validSurfaceName name then Just (name, suffix) else Nothing
    _ -> Nothing

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

-- | The SBP boundary trace: sbpx_a e is the wall value of a dual-placed
-- expression along the declared sbp axis a, extrapolated by the pair's
-- boundary vector at the first and last primal rows and zero elsewhere.
sbpxOpParts :: String -> Maybe IxPart
sbpxOpParts nm = do
  rest <- stripPrefix "sbpx" nm
  case parseMarkedPrefix rest of
    Just ([part], "") -> Just part
    _ -> Nothing

-- | Recognizer for the retired sbpd spelling: sbpd_x was the first
-- derivative and sbpd2_x the composed second derivative with
-- summation-by-parts closure rows.  The boundary treatment is an axis
-- property now (boundary AXIS : sbp), so the only consumer left is the
-- migration diagnostic.
sbpOpParts :: String -> Maybe (Int, IxPart)
sbpOpParts nm = do
  rest0 <- stripPrefix "sbpd" nm
  let (orderDigits, rest1) = span isDigit rest0
      order = if null orderDigits then 1 else read orderDigits
  case parseMarkedPrefix rest1 of
    Just ([part], "") -> Just (order, part)
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
fieldDeclAcceptsParts fd = indexDeclAcceptsParts (fdIndex fd)

indexDeclAcceptsParts :: Maybe FieldIndex -> [IxPart] -> Bool
indexDeclAcceptsParts indexDecl parts =
  case indexDecl of
    Nothing -> null parts
    Just (FieldIndex (Plain decl)) -> sameVarianceList decl parts
    Just (FieldIndex (Symmetric decl)) ->
      sameVarianceList decl parts || sameVarianceList (reverse decl) parts
    Just (FieldIndex (Antisymmetric decl)) ->
      sameVarianceList decl parts || sameVarianceList (reverse decl) parts

-- | Every indexed declaration a concrete-axis subscript may project: user
-- state fields and materialized step locals share the same index
-- vocabulary, so both admit component projection.
indexedFieldDeclarations :: Model -> [(String, Maybe FieldIndex)]
indexedFieldDeclarations m =
  [(fdName field, fdIndex field) | field <- mFieldDecls m]
  ++ [ (ldName local, ldIndex local)
     | step <- mSteps m
     , Just local <- [sLocalDecl step]
     ]

-- | Concrete-axis subscripts on a declared indexed field or local must
-- project a complete component: every mark names an axis and the sequence
-- matches the declared rank and variance.  Subscripts without any axis
-- name keep their symbolic reading, exactly as for the coordinate
-- derivative.
invalidAxisProjection :: Model -> String -> [IxPart] -> Maybe String
invalidAxisProjection m base parts
  | null parts = Nothing
  | Nothing <- declaration = Nothing
  | not (any isAxis parts) = Nothing
  | not (all isAxis parts) =
      Just ("component projection cannot mix axis and symbolic indices: "
            ++ spelled)
  | Just indexDecl <- declaration
  , not (indexDeclAcceptsParts indexDecl parts) =
      Just ("component projection does not match the declared index"
            ++ " structure of " ++ base ++ ": " ++ spelled)
  | otherwise = Nothing
  where
    declaration = lookup base (indexedFieldDeclarations m)
    isAxis part = ixName part `elem` mAxes m
    spelled = base ++ concatMap ixSuffix parts

-- | Static failures for an Egison-style indexed binding target.  Field
-- declaration index names are placeholders, so compatibility compares rank
-- and variance but deliberately does not require the same spelling (for
-- example @field X~i@ may be updated as @X'~k = ...@).
data IndexedTargetError
  = IndexedTargetNameMismatch String String
  | InvalidTargetIndex String
  | DuplicateTargetIndex String
  | TargetIndexNameConflict String
  | IndexedTargetRankMismatch Int Int
  | IndexedTargetVarianceMismatch Int Variance Variance
  deriving (Eq, Show)

-- | Validate a field update target against the field's declared tensor
-- contract.  An unindexed target remains a valid whole-tensor assignment.
-- Once any LHS index is written, however, its rank and variance must agree
-- with the field declaration; this is the same contract established by an
-- indexed Egison definition.
validateFieldTarget
  :: FieldDecl -> IndexedTarget -> Either IndexedTargetError ()
validateFieldTarget field target
  | fdName field /= indexedTargetName target =
      Left (IndexedTargetNameMismatch
        (fdName field) (indexedTargetName target))
  | Left problem <- validateBindingIndices [] actualParts = Left problem
  | null actualParts = Right ()
  | length expectedVariances /= length actualVariances =
      Left (IndexedTargetRankMismatch
        (length expectedVariances) (length actualVariances))
  | Just (position, expected, actual) <- firstVarianceMismatch =
      Left (IndexedTargetVarianceMismatch position expected actual)
  | otherwise = Right ()
  where
    actualParts = indexedTargetIndices target
    actualVariances = map ixVariance actualParts
    expectedVariances =
      case fieldIndexParts field of
        Just parts -> map ixVariance parts
        Nothing -> replicate (componentRank (fdKind field)) VDown
    firstVarianceMismatch = find mismatch
      (zip3 [1 :: Int ..] expectedVariances actualVariances)
    mismatch (_, expected, actual) = expected /= actual

-- | Field declarations and binding targets both introduce free index names.
-- Repeating one on the same LHS would describe a diagonal/trace rather than
-- a whole tensor binding, which Egison's indexed-definition sugar is not
-- intended to hide.
validateDistinctIndices :: [IxPart] -> Either IndexedTargetError ()
validateDistinctIndices = validateBindingIndices []

-- | Check the names introduced by an indexed-definition LHS.  Names in the
-- forbidden set denote values in the RHS environment (coordinates,
-- generated registries, fields, and so on); allowing one here would make the
-- implicit @withSymbols@ silently shadow that value.
validateBindingIndices
  :: [String] -> [IxPart] -> Either IndexedTargetError ()
validateBindingIndices forbidden parts =
  case [name | name <- names, not (validSurfaceName name)] of
    invalid : _ -> Left (InvalidTargetIndex invalid)
    [] -> case firstDuplicate names of
      Just duplicate -> Left (DuplicateTargetIndex duplicate)
      Nothing -> case find (`elem` forbidden) names of
        Just conflict -> Left (TargetIndexNameConflict conflict)
        Nothing -> Right ()
  where
    names = map ixName parts

{-
  Keep duplicate detection deterministic so diagnostics and focused tests do
  not depend on declaration order.
-}
firstDuplicate :: Ord a => [a] -> Maybe a
firstDuplicate values =
  case [member | members@(member : _) <- group (sort values),
                 length members > 1] of
    duplicate : _ -> Just duplicate
    [] -> Nothing

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
-- A deferred local has no declared rank; the registry carries a rank-zero
-- placeholder and the emitted unit derives the authoritative declaration
-- from the value during normalization.
componentRank TensorAny = 0

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
-- Deferred locals enumerate their component bases during normalization
-- (FEIR.deferredFieldEntries); the static table contributes nothing.
componentIndices _ TensorAny = []

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
