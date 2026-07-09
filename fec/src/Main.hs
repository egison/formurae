-- fec -- the Formurae compiler.
--
-- Formurae (.fe) is the mathematical surface language of this repo,
-- named after Muranushi's Formura (its Latin-looking plural, and a pun
-- on "formulae").  fec translates it into the embedded DSL form: an
-- Egison program that carries its own coordinate context, mathematical
-- operators, and .fmr printer, while using lib/fmrgen.egi only for
-- small coordinate-free helpers.  Tensor index notation, differential
-- forms, CAS expansion, and printing are still expressed as generated
-- Egison code; this is a thin, line-oriented translator.  Base library
-- only; build and run with
--
--   cabal run -v0 fec -- model.fe > model.egi
--   egison -l lib/fmrgen.egi model.egi > model.fmr
--
-- Formurae grammar (v1):
--   -- comment                      (kept out of the output)
--   dimension 1|2|3                 (REQUIRED; Formura grid dimension)
--   axes x[, y[, z]]                (REQUIRED; fixes the coordinate frame
--                                    the operators refer to.  The names map
--                                    to the internal coordinates x,y,z as
--                                    needed, so axes r, theta, phi works
--                                    in CAS exprs)
--   metric scale [h1, ...]          Lame scale factors of an orthogonal
--                                   metric, written in the axis names.
--   metric NAME                     declare NAME as the metric tensor
--                                   surface name; NAME~i~j, NAME~i_j,
--                                   NAME_i~j, NAME_i_j lower to generated
--                                   metric tensors by variance.
--   embedding [X1, X2, ..., Xm]     coordinate map into R^m: the metric
--                                   g_ab = dX/dx_a . dX/dx_b is DERIVED
--                                   by the CAS (orthogonality is checked
--                                   symbolically and gates generation);
--                                   scale factors h_a = sqrt(g_aa).
--                                   Backquotes keep factors compact
--                                   (`(2 + cos theta)), and expandAll
--                                   removes them before the half-cell
--                                   substitution.
--                                   Enables lb (Laplace-Beltrami): the
--                                   hodge factors sqrt(g)/h_a^2 become
--                                   coefficient FIELDS evaluated by the
--                                   CAS at the half-cell placements.
--   use MODULE { NAME, ... }         coordinate-context mathematical operators
--                                    made available to this file; v1 starts
--                                    with exterior-calculus { Δ } and
--                                    vector-calculus { curl, divg }.
--                                    Δ injects def Δ u = 0 - delta (d u);
--                                    vector operators are generated under
--                                    the current coordinate context.
--   def NAME ARG(~i|_i)* = EXPR     user-defined operator, expanded at use
--                                    sites (file scope; a body may use only
--                                    operators defined before it).  A use
--                                    definition may be redefined.
--   param NAME = RAW                Formura parameter (double :: NAME = RAW)
--   extern NAME                     extern function :: NAME
--                                   (core scalar intrinsics such as sin,
--                                    cos, exp, sqrt, ... are also emitted
--                                    automatically when they are used)
--   raw LINE                        verbatim Formura helper line
--   field NAME : scalar             one grid field
--   field NAME : vector             dimension components (NAME_1,NAME_2,...)
--   field NAME : k-form              DEC differential forms (0 <= k <= dimension)
--   init:
--     COMP = RAW                    raw Formura initializer (component)
--     NAME = [| e1, e2, e3 |]       legacy vector/form initializer
--     NAME~i = [| e1,e2,e3 |]~i     indexed vector/form initializer
--     NAME~i~j = [| [| xx,... |],   indexed tensor initializer; RHS suffix
--                  ... |]~i~j       must match the LHS suffix
--                                    may span lines until brackets balance
--     NAME~i~j := EXPR              indexed CAS initializer; components are
--                                    expanded and evaluated at their layout
--                                    placement
--     NAME := EXPR                  scalar CAS initializer (printed via fmrInit)
--   step:
--     let N_i = EXPR                named tensor expression (inlined)
--     let N = EXPR                  named scalar expression (inlined)
--     local N = EXPR                intermediate grid field (emitted line)
--     N' = EXPR                     scalar / vector / k-form update
--                                   (form operators: d, delta (or codiff);
--                                    with metric scale: lb NAME)
--     N'_i = EXPR                   vector update (explicit index equation)
--   assert-dd-zero NAME'            gate generation on d(d NAME') == 0
--
-- Unicode: Greek letters transliterate to their ASCII names (theta,
-- phi, ...); coordinate derivatives are written only as ∂x, ∂theta,
-- ... while ∂_i remains the indexed derivative.  The small delta is the
-- codifferential, the minus sign
-- is '-'.  The capital delta becomes the model's geometric Laplacian
-- when enabled by `use exterior-calculus { Δ }`; the derived 4th-order
-- Laplacian is spelled with the capital delta followed by 4 (lap4 is an
-- accepted alias).  Writing d twice fuses to the
-- compact second difference (there is no d2 operator), and delta (d u) on
-- a scalar lowers to -(Laplacian), so the heat equation reads
-- u' = u - dt * delta (d u) with basic operators only; all of these
-- generate byte-identical code to their named-operator forms.
-- Nabla combinations work too: nabla-cross is curl, nabla-dot is divg,
-- and nabla^2 (or with the superscript two) is the Laplacian.
-- In index equations superscripts (~i) and subscripts (_i) are kept
-- distinct.  Kronecker's delta is the mixed identity (delta~i_j, or
-- with the small delta sign), while the metric tensor name declared by
-- `metric NAME` lowers to generated tensors according to variance:
-- NAME~i~j, NAME~i_j, NAME_i~j, NAME_i_j.  The fused delta_ij is rejected.
--
-- A vector update may be written without indices (E' = E + dt * curl B);
-- bare vector names combine elementwise and curl applies to the whole
-- field.  X' in a RHS refers to the updated field (Formura's primed
-- array), so B' = B - dt * curl E' is the symplectic pair.

import Data.Char (isAlpha, isAlphaNum, isDigit, isSpace)
import Data.List (dropWhileEnd, intercalate, isPrefixOf, permutations, sort, nub, stripPrefix)
import System.Environment (getArgs)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

vecOps, vecRet, deltaOps :: [String]
vecOps = ["d", "delta", "codiff", "\948", "curl", "divg", "dGrad"]
vecRet = ["curl"]
deltaOps = ["delta", "codiff", "\948"]

-- Scalar functions supported as Formura/C extern functions.  In Egison's
-- tensor notation these are scalar functions that can be lifted over tensors;
-- fec uses the list to make the Formura extern surface explicit.
scalarIntrinsics :: [String]
scalarIntrinsics =
  [ "sin", "cos", "tan"
  , "asin", "acos", "atan", "atan2"
  , "sinh", "cosh", "tanh"
  , "exp", "log", "sqrt", "pow", "fabs"
  ]

fatal :: String -> IO a
fatal msg = hPutStrLn stderr ("fec: error: " ++ msg) >> exitFailure

-- ---------------------------------------------------------------- model

data Kind = Scalar | Vector Bool | Form Int | SymM | AntiM | Tensor2 Bool deriving (Eq, Show)

data FieldLayout =
    ScalarLayout
  | Rank1Layout
  | SymRank2Layout
  | AntiRank2Layout
  | FullRank2Layout
  deriving (Eq, Show)

data IndexGroup =
    Plain [IxPart]
  | Symmetric [IxPart]
  | Antisymmetric [IxPart]
  deriving (Eq, Show)

data FieldIndex = FieldIndex { fiGroups :: [IndexGroup] } deriving (Eq, Show)

data FieldDecl = FieldDecl
  { fdName      :: String
  , fdIndex     :: Maybe FieldIndex
  , fdLayout    :: FieldLayout
  , fdStaggered :: Bool
  , fdKind      :: Kind
  } deriving (Eq, Show)

data Init = IRaw String String | IVec String [String]
          | ISym String [String]   -- xx, yy, zz, xy, xz, yz
          | IAnti String [String]  -- xy, xz, yz
          | ITensor2 String [String] -- xx, xy, xz, yx, yy, yz, zx, zy, zz
          | ICas String String
          | ICasIndex String [IxPart] String

data SK = KLet | KLocal | KEq deriving Eq

data Step = Step { sk :: SK, sNm :: String, sIdx :: [IxPart], sEx :: String }

data Model = Model
  { mName   :: String
  , mDim    :: Int
  , mAxes   :: [String]
  , mMetricName :: Maybe String
  , mUses   :: [(String, [String])]
  , mParams :: [(String, String)]
  , mHelp   :: [String]
  , mFlds   :: [(String, Kind)]
  , mFieldDecls :: [FieldDecl]
  , mInits  :: [Init]
  , mSteps  :: [Step]
  , mDd     :: Maybe String
  , mMetric :: Maybe [String]
  , mEmbed  :: Maybe [String]
  , mDefs   :: [(String, (String, String))]  -- name -> (param, body); latest first
  }

kindOf :: Model -> String -> Maybe Kind
kindOf m nm = lookup nm (mFlds m)

fieldDeclOf :: Model -> String -> Maybe FieldDecl
fieldDeclOf m nm =
  case [fd | fd <- mFieldDecls m, fdName fd == nm] of
    (fd:_) -> Just fd
    [] -> Nothing

declaredExterns :: [String] -> [String]
declaredExterns = foldr collect []
  where
    collect h acc =
      case stripPrefix "extern function :: " (strip h) of
        Just nm | not (null (strip nm)) -> strip nm : acc
        _ -> acc

autoScalarExterns :: Model -> [String] -> [String]
autoScalarExterns m helps =
  [ "extern function :: " ++ nm
  | nm <- scalarIntrinsics
  , nm `notElem` declared
  , any (usesFunctionName nm) (modelExprTexts m)
  ]
  where
    declared = declaredExterns helps

modelExprTexts :: Model -> [String]
modelExprTexts m =
  map snd (mParams m)
  ++ helperExprs (mHelp m)
  ++ concatMap initExpr (mInits m)
  ++ map sEx (mSteps m)
  ++ maybe [] id (mMetric m)
  ++ map (snd . snd) (mDefs m)
  where
    helperExprs = filter isExprHelper
    isExprHelper h =
      let s = strip h
      in not (null s)
         && take 1 s /= "#"
         && stripPrefix "extern function :: " s == Nothing
    initExpr it = case it of
      IRaw _ rhs -> [rhs]
      IVec _ es -> es
      ISym _ es -> es
      IAnti _ es -> es
      ITensor2 _ es -> es
      ICas _ ex -> [ex]
      ICasIndex _ _ ex -> [ex]

usesFunctionName :: String -> String -> Bool
usesFunctionName nm = go . tokenize
  where
    go [] = False
    go (TId w False : ts)
      | w == nm =
          case dropWhile isSpTok ts of
            TC '(' : _ -> True
            TId _ _ : _ -> True
            _ -> go ts
    go (_ : ts) = go ts

-- ------------------------------------------------------------- utilities

strip, rstrip :: String -> String
rstrip = dropWhileEnd isSpace
strip = dropWhile isSpace . rstrip

isW :: Char -> Bool
isW c = isAlphaNum c || c == '_'

stripComment :: String -> String
stripComment ('-':'-':_) = []
stripComment (c:cs) = c : stripComment cs
stripComment [] = []

reservedInternalPrefix :: String
reservedInternalPrefix = "FormuraeInternal"

isReservedInternalName :: String -> Bool
isReservedInternalName = isPrefixOf reservedInternalPrefix

rejectReservedName :: Int -> String -> IO ()
rejectReservedName ln nm =
  if isReservedInternalName nm
    then fatal ("identifier is reserved for generated code: " ++ nm
                ++ " (line " ++ show ln ++ ")")
    else return ()

validSurfaceName :: String -> Bool
validSurfaceName (c:cs) = isAlpha c && all isAlphaNum cs
validSurfaceName [] = False

metricNameConflicts :: Model -> [String]
metricNameConflicts m =
  map fst (mParams m)
  ++ map fst (mFlds m)

egiStringList :: [String] -> String
egiStringList xs = "[" ++ intercalate ", " (map show xs) ++ "]"

egiMathList :: [String] -> String
egiMathList xs = "[" ++ intercalate ", " xs ++ "]"

egiIntList :: [Int] -> String
egiIntList xs = "[" ++ intercalate ", " (map show xs) ++ "]"

egiIntLists :: [[Int]] -> String
egiIntLists xs = "[" ++ intercalate ", " (map egiIntList xs) ++ "]"

permSign :: [Int] -> Int
permSign xs =
  if even (length [(a, b) | (i, a) <- zip [0 :: Int ..] xs
                          , (j, b) <- zip [0 :: Int ..] xs
                          , i < j, a > b])
    then 1
    else -1

validateMetricName :: Model -> IO ()
validateMetricName m =
  case mMetricName m of
    Nothing -> return ()
    Just nm ->
      case [x | x <- metricNameConflicts m, x == nm] of
        _:_ -> fatal ("metric name conflicts with a param or field declaration: " ++ nm)
        [] -> return ()

kindFromFieldDecl :: FieldDecl -> Kind
kindFromFieldDecl = fdKind

parseFieldDecl :: Int -> String -> IO FieldDecl
parseFieldDecl ln r =
  case break (== ':') r of
    (nm0, ':':k0) -> legacy (strip nm0) (strip k0)
    _ -> indexed
  where
    legacy nm k =
      if not (validSurfaceName nm)
        then fatal ("bad field name: " ++ nm ++ " (line " ++ show ln ++ ")")
        else do
          rejectReservedName ln nm
          case k of
            "scalar" -> return (FieldDecl nm Nothing ScalarLayout False Scalar)
            "vector" -> return (FieldDecl nm Nothing Rank1Layout False (Vector False))
            "vector @ staggered" -> return (FieldDecl nm Nothing Rank1Layout True (Vector True))
            "symmetric @ staggered" -> return (FieldDecl nm Nothing SymRank2Layout True SymM)
            _ | Just deg <- formKind k ->
                  return (FieldDecl nm Nothing Rank1Layout False (Form deg))
            _ -> fatal ("bad field kind: " ++ k ++ " (line " ++ show ln ++ ")")
    indexed =
      case words (strip r) of
        [spec] -> fromSpec spec False
        [spec, "@", "staggered"] -> fromSpec spec True
        _ -> fatal ("bad field decl: field " ++ r ++ " (line " ++ show ln ++ ")")
    fromSpec spec staggered =
      case parseFieldSpec spec of
        Nothing -> fatal ("bad field spec: " ++ spec ++ " (line " ++ show ln ++ ")")
        Just (nm, mix) -> do
          rejectReservedName ln nm
          layout <- inferFieldLayout ln spec mix staggered
          return (FieldDecl nm mix layout staggered (kindFor layout staggered))

    kindFor ScalarLayout _ = Scalar
    kindFor Rank1Layout staggered = Vector staggered
    kindFor SymRank2Layout _ = SymM
    kindFor AntiRank2Layout _ = AntiM
    kindFor FullRank2Layout staggered = Tensor2 staggered
    formKind t =
      case fmap reverse (stripPrefix (reverse "-form") (reverse t)) of
        Just ds | all isDigit ds && not (null ds) -> Just (read ds)
        _ -> Nothing

parseFieldSpec :: String -> Maybe (String, Maybe FieldIndex)
parseFieldSpec spec = do
  let (nm, rest) = span isAlphaNum spec
  if not (validSurfaceName nm) then Nothing else
    case rest of
      "" -> Just (nm, Nothing)
      c:_ | c == '~' || c == '_' -> do
        parts <- parseMarkedSeq rest
        Just (nm, Just (FieldIndex [Plain parts]))
      '{':body | not (null body), last body == '}' -> do
        parts <- parseMarkedSeq (init body)
        Just (nm, Just (FieldIndex [Symmetric parts]))
      '[':body | not (null body), last body == ']' ->
        do parts <- parseMarkedSeq (init body)
           Just (nm, Just (FieldIndex [Antisymmetric parts]))
      _ -> Nothing

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

showIxParts :: [IxPart] -> String
showIxParts = concatMap ixSuffix

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
    Just (FieldIndex [Plain decl]) -> sameVarianceList decl parts
    Just (FieldIndex [Symmetric decl]) ->
      sameVarianceList decl parts || sameVarianceList (reverse decl) parts
    Just (FieldIndex [Antisymmetric decl]) ->
      sameVarianceList decl parts || sameVarianceList (reverse decl) parts
    _ -> False

fieldDeclIndexSuffix :: FieldDecl -> String
fieldDeclIndexSuffix fd =
  case fdIndex fd of
    Just (FieldIndex [Plain parts]) -> showIxParts parts
    Just (FieldIndex [Symmetric parts]) -> showIxParts parts
    Just (FieldIndex [Antisymmetric parts]) -> showIxParts parts
    _ -> ""

inferFieldLayout :: Int -> String -> Maybe FieldIndex -> Bool -> IO FieldLayout
inferFieldLayout ln spec Nothing staggered
  | staggered = fatal ("scalar field cannot be staggered: " ++ spec ++ " (line " ++ show ln ++ ")")
  | otherwise = return ScalarLayout
inferFieldLayout ln spec (Just (FieldIndex [Plain parts])) _
  | length parts == 1 = return Rank1Layout
  | length parts == 2 = return FullRank2Layout
  | otherwise = fatal ("unsupported field rank in " ++ spec ++ " (line " ++ show ln ++ ")")
inferFieldLayout ln spec (Just (FieldIndex [Symmetric parts])) _
  | length parts == 2 && sameVarianceParts parts = return SymRank2Layout
  | length parts == 2 = fatal ("symmetric field needs same-variance indices: " ++ spec ++ " (line " ++ show ln ++ ")")
  | otherwise = fatal ("symmetric field must have rank 2: " ++ spec ++ " (line " ++ show ln ++ ")")
inferFieldLayout ln spec (Just (FieldIndex [Antisymmetric parts])) _
  | length parts == 2 && sameVarianceParts parts = return AntiRank2Layout
  | length parts == 2 = fatal ("antisymmetric field needs same-variance indices: " ++ spec ++ " (line " ++ show ln ++ ")")
  | otherwise = fatal ("antisymmetric field must have rank 2: " ++ spec ++ " (line " ++ show ln ++ ")")
inferFieldLayout ln spec _ _ =
  fatal ("unsupported field spec: " ++ spec ++ " (line " ++ show ln ++ ")")

-- split on a separator at paren/bracket depth 0
splitTop :: Char -> String -> [String]
splitTop sep = go 0 []
  where
    go :: Int -> String -> String -> [String]
    go _ acc [] = [strip (reverse acc)]
    go d acc (c:cs)
      | c `elem` "([" = go (d + 1) (c : acc) cs
      | c `elem` ")]" = go (d - 1) (c : acc) cs
      | c == sep && d == 0 = strip (reverse acc) : go 0 [] cs
      | otherwise = go d (c : acc) cs

-- NAME(~i|_i)? = EXPR   with NAME = [A-Za-z][A-Za-z0-9]*
eqForm :: String -> String -> Maybe (String, [IxPart], String)
eqForm marker s = do
  rest0 <- if null marker then Just s else stripPrefix (marker ++ " ") s
  let rest = dropWhile isSpace rest0
  (nm, r1) <- ident rest
  let (ix, r2) = idxs r1
  r3 <- stripPrefix "=" (dropWhile isSpace r2)
  let ex = strip r3
  if null ex then Nothing else Just (nm, ix, ex)
  where
    ident (c:cs) | isAlpha c = let (a, b) = span isAlphaNum cs in Just (c : a, b)
    ident _ = Nothing
    idxs (mark:c:rest)
      | mark `elem` "_~", isAlpha c, not (isAlphaNum (headDef ' ' rest)) =
          let (more, r) = idxs rest
              v = if mark == '~' then VUp else VDown
          in (IxPart v [c] : more, r)
    idxs r = ([], r)
    headDef d [] = d
    headDef _ (c:_) = c

-- def NAME PARAM(~i|_i)* = BODY
-- The optional index marks after PARAM describe the returned indexed
-- quantity.  The current thin implementation keeps PARAM as the substitution
-- variable and lets the index equation expander interpret BODY's free indices.
defForm :: String -> Maybe (String, String, String)
defForm r = do
  (nm, r1) <- identU (strip r)
  (p, r2) <- identParam (dropWhile isSpace r1)
  r3 <- stripPrefix "=" (dropWhile isSpace (dropIdxSuffix r2))
  let body = strip r3
  if null body then Nothing else Just (nm, p, body)
  where
    identU (c:cs) | isAlpha c = let (a, b) = span isW cs in Just (c : a, b)
    identU _ = Nothing
    identParam (c:cs) | isAlpha c =
      let (a, b) = span isAlphaNum cs in Just (c : a, b)
    identParam _ = Nothing
    dropIdxSuffix ('~':c:rest) | isAlpha c = dropIdxSuffix rest
    dropIdxSuffix ('_':c:rest) | isAlpha c = dropIdxSuffix rest
    dropIdxSuffix s = s

-- NAME'(~a|_a)(~b|_b)? = EXPR   (a, b single index letters)
primeEqForm :: String -> Maybe (String, [IxPart], String)
primeEqForm s = do
  (nm, r1) <- ident s
  r2 <- stripPrefix "'" r1
  let (ixs, r3) = idxs r2
  r4 <- stripPrefix "=" (dropWhile isSpace r3)
  let ex = strip r4
  if null ex then Nothing else Just (nm, ixs, ex)
  where
    ident (c:cs) | isAlpha c = let (a, b) = span isAlphaNum cs in Just (c : a, b)
    ident _ = Nothing
    idxs (mark:c:rest)
      | mark `elem` "_~", isAlpha c, not (isAlphaNum (headDef ' ' rest)) =
          let (more, r) = idxs rest
              v = if mark == '~' then VUp else VDown
          in (IxPart v [c] : more, r)
    idxs r = ([], r)
    headDef d [] = d
    headDef _ (c:_) = c

-- ---------------------------------------------------------------- parser

data Section = STop | SInit | SStep

supportedUses :: [(String, [String])]
supportedUses =
  [ ("exterior-calculus", ["d", "delta", "codiff", "dForm", "hodge", "\916"])
  , ("vector-calculus", ["dGrad", "curl", "divg"])
  ]

displayUseName :: String -> String
displayUseName "\916" = "Δ"
displayUseName "delta" = "δ"
displayUseName nm = nm

normalizeUses :: [(String, [String])] -> [(String, [String])]
normalizeUses uses =
  [ (modName, nub (concat [names | (m, names) <- uses, m == modName]))
  | modName <- nub (map fst uses)
  ]

hasUse :: Model -> String -> String -> Bool
hasUse m modName nm =
  case lookup modName (mUses m) of
    Just names -> nm `elem` names
    Nothing -> False

validateUses :: Model -> IO ()
validateUses m = mapM_ validateModule (mUses m)
  where
    validateModule (modName, names) =
      case lookup modName supportedUses of
        Nothing -> fatal ("unknown use module: " ++ modName)
        Just allowed -> mapM_ (validateName modName allowed) names
    validateName modName allowed nm
      | nm `notElem` allowed =
          fatal ("unknown operator " ++ displayUseName nm ++ " in use " ++ modName)
      | modName == "vector-calculus", nm == "curl", mDim m /= 3 =
          fatal "curl requires dimension 3"
      | otherwise = return ()

validateDimensionFeatures :: Model -> IO ()
validateDimensionFeatures m
  | any isAntiField (mFlds m) && mDim m < 2 =
      fatal "antisymmetric rank-2 fields require dimension at least 2"
  | Just k <- firstBadFormDegree =
      fatal (show k ++ "-form fields require dimension at least " ++ show k)
  | otherwise = return ()
  where
    isAntiField (_, AntiM) = True
    isAntiField _ = False
    firstBadFormDegree =
      case [k | (_, Form k) <- mFlds m, k < 0 || k > mDim m] of
        k:_ -> Just k
        [] -> Nothing

usePreludeDefs :: Model -> [(String, (String, String))]
usePreludeDefs m =
  [ ("\916", ("u", "0 - delta (d u)"))
  | hasUse m "exterior-calculus" "\916"
  ]

missingUse :: Model -> String -> Maybe String
missingUse m s = go (tokenize s)
  where
    go [] = Nothing
    go (t:ts) = check t ts `orElse` go ts
    check (TId "d" _) rest
      | indexedAfter rest = Nothing
      | not (hasUse m "exterior-calculus" "d") =
      Just "d requires use exterior-calculus { d }"
    check (TId "delta" _) rest
      | indexedAfter rest = Nothing
      | not (hasUse m "exterior-calculus" "delta") =
      Just "δ requires use exterior-calculus { δ }"
    check (TId "codiff" _) _ | not (hasUse m "exterior-calculus" "codiff") =
      Just "codiff requires use exterior-calculus { codiff }"
    check (TId "dForm" _) _ | not (hasUse m "exterior-calculus" "dForm") =
      Just "dForm requires use exterior-calculus { dForm }"
    check (TId "hodge" _) _ | not (hasUse m "exterior-calculus" "hodge") =
      Just "hodge requires use exterior-calculus { hodge }"
    check (TId "\916" _) _ | not (hasUse m "exterior-calculus" "\916") =
      Just "Δ requires use exterior-calculus { Δ }"
    check (TId "curl" _) _ | not (hasUse m "vector-calculus" "curl") =
      Just "curl requires use vector-calculus { curl }"
    check (TId "divg" _) _ | not (hasUse m "vector-calculus" "divg") =
      Just "divg requires use vector-calculus { divg }"
    check (TId "dGrad" _) _ | not (hasUse m "vector-calculus" "dGrad") =
      Just "dGrad requires use vector-calculus { dGrad }"
    check _ _ = Nothing
    indexedAfter rest =
      case dropWhile isSpTok rest of
        TC '~' : _ -> True
        TC '_' : _ -> True
        _ -> False
    orElse (Just x) _ = Just x
    orElse Nothing y = y

parseFe :: String -> String -> IO Model
parseFe name txt = go STop (Model name 0 [] Nothing [] [] [] [] [] [] [] Nothing Nothing Nothing [])
                      (zip [1 :: Int ..] (lines txt))
  where
    -- dimension and axes are required: they fix the coordinate frame
    -- that gives the operators their meaning (which axis ∂theta is,
    -- what an index letter in ∂_j ranges over)
    go _ m []
      | mDim m == 0 = fatal "dimension declaration is required (dimension 1, 2, or 3)"
      | null (mAxes m) = fatal "axes declaration is required (e.g. axes x, y, z)"
      | length (mAxes m) /= mDim m =
          fatal ("axes declares " ++ show (length (mAxes m))
                 ++ " names for dimension " ++ show (mDim m))
      | otherwise = do
          let uses = normalizeUses (reverse (mUses m))
              mUse = m { mUses = uses }
          validateMetricName mUse
          validateUses mUse
          validateDimensionFeatures mUse
          mapM_ (\(_, (_, body)) ->
                    checkUserSurface mUse "in def" body)
                (mDefs mUse)
          mapM_ (\st ->
                    checkUserSurface mUse ("in step expression: " ++ sEx st) (sEx st))
                (mSteps mUse)
          mapM_ (checkInitUse mUse) (mInits mUse)
          -- resolve user-defined operators (definition order; a body may
          -- use only operators defined before it) and expand all uses
          defs <- resolveDefs (usePreludeDefs mUse ++ reverse (mDefs mUse))
          steps' <- mapM (\st -> do ex <- applyDefs defs (sEx st)
                                    return st { sEx = ex })
                         (reverse (mSteps mUse))
          inits' <- mapM (expandInit defs) (reverse (mInits mUse))
          mapM_ (\(nm, (_, body)) ->
                    checkGeneratedSurface mUse ("in def " ++ nm) body)
                defs
          mapM_ (\st ->
                    checkGeneratedSurface mUse ("in step expression: " ++ sEx st) (sEx st))
                steps'
          return mUse { mParams = reverse (mParams mUse), mHelp = reverse (mHelp mUse)
                   , mFlds = reverse (mFlds mUse)
                   , mFieldDecls = reverse (mFieldDecls mUse), mInits = inits'
                   , mSteps = steps', mDefs = defs }

    go sec m ((ln, raw):rest) = do
      let code = rstrip (stripComment raw)
          s = strip code
      if null s then go sec m rest else do
        case s of
          "init:" -> go SInit m rest
          "step:" -> go SStep m rest
          _ -> do
            let sec' = if take 1 code /= " " then STop else sec
            case sec' of
              STop -> top ln s m >>= \m' -> go STop m' rest
              -- an init line may continue over following lines until its
              -- brackets balance (tensor initializers span rows)
              SInit | bal s > 0 ->
                let (more, rest') = grab (bal s) rest
                in ini ln (s ++ " " ++ more) m >>= \m' -> go SInit m' rest'
              SInit -> ini ln s m >>= \m' -> go SInit m' rest
              SStep -> stp ln s m >>= \m' -> go SStep m' rest

    bal t = sum [1 :: Int | c <- t, c `elem` "(["] - sum [1 | c <- t, c `elem` ")]"]

    resolveDefs ds = goD [] ds
      where
        -- earlier defs are expanded into the body, so a resolved body
        -- may contain no def name at all: any survivor is a self or
        -- forward reference
        allNames = map fst ds
        goD acc [] = return acc
        goD acc ((nm, (p, body)) : more) = do
          body' <- applyDefs acc body
          case [w | TId w _ <- tokenize body', w `elem` allNames] of
            (w:_) -> fatal ("def " ++ nm ++ " uses " ++ w
                            ++ " which is not defined before it")
            [] -> goD ((nm, (p, body')) : acc) more

    -- expand operator applications: NAME ARG with ARG an identifier or
    -- a parenthesized expression.  Bodies are def-free after
    -- resolveDefs, so one pass suffices; arguments are expanded first.
    applyDefs defs s = fmap untok (goE (tokenize s))
      where
        goE [] = return []
        goE (TId nm False : ts)
          | Just (p, body) <- lookup nm defs = do
              let (_, rest) = span isSpTok ts
              (arg, rest') <- case rest of
                (TC '(' : r) -> case closeParenT 1 r [] of
                  Just (inner, r') -> return (untok inner, r')
                  Nothing -> fatal ("unbalanced argument to " ++ nm)
                (TId a pr : r) -> return (a ++ (if pr then "'" else ""), r)
                _ -> fatal ("operator " ++ nm ++ " needs an argument")
              arg' <- fmap untok (goE (tokenize arg))
              let argS = if all (\c -> isW c || c == '\'') arg'
                           then arg' else "(" ++ arg' ++ ")"
                  bodyT = concatMap (substP p argS) (tokenize body)
              fmap ((TC '(' : bodyT ++ [TC ')']) ++) (goE rest')
        goE (t : ts) = fmap (t :) (goE ts)
        substP p argS (TId w pr)
          | w == p = tokenize (argS ++ (if pr then "'" else ""))
        substP _ _ t = [t]

    expandInit defs it = case it of
      ICas nm ex -> do ex' <- applyDefs defs ex
                       return (ICas nm ex')
      ICasIndex nm ix ex -> do ex' <- applyDefs defs ex
                               return (ICasIndex nm ix ex')
      _ -> return it

    checkUserSurface m' context body =
      case surfaceBanned m' body of
        Just bad -> fatal (bad ++ " " ++ context)
        Nothing ->
          case missingUse m' body of
            Just bad -> fatal (bad ++ " " ++ context)
            Nothing -> return ()

    checkGeneratedSurface m' context body =
      case surfaceBanned m' body of
        Just bad -> fatal (bad ++ " " ++ context)
        Nothing -> return ()

    checkInitUse m' it = case it of
      ICas nm ex -> checkUserSurface m' ("in init expression: " ++ nm) ex
      ICasIndex nm ix ex -> checkUserSurface m' ("in init expression: " ++ nm ++ showIxParts ix) ex
      _ -> return ()

    grab _ [] = ("", [])
    grab d ((_, raw):rest) =
      let t = strip (rstrip (stripComment raw))
          d' = d + bal t
      in if d' <= 0
           then (t, rest)
           else let (more, rest') = grab d' rest
                in (t ++ " " ++ more, rest')

    top ln s m
      | Just r <- stripPrefix "def " s =
          case defForm r of
            Just (nm, p, body) -> do
              rejectReservedName ln nm
              rejectReservedName ln p
              return m { mDefs = (nm, (p, body)) : mDefs m }
            Nothing -> fatal ("bad def (line " ++ show ln
                              ++ "): def NAME ARG(~i|_i)* = EXPR")
      | Just r <- stripPrefix "param " s =
          case break (== '=') r of
            (nm, '=':v) | not (null (strip nm)) && not (null (strip v)) -> do
              rejectReservedName ln (strip nm)
              return m { mParams = (strip nm, strip v) : mParams m }
            _ -> fatal ("bad param (line " ++ show ln ++ ")")
      | Just r <- stripPrefix "extern " s =
          return m { mHelp = ("extern function :: " ++ strip r) : mHelp m }
      | Just r <- stripPrefix "use " s =
          case useForm r of
            Just (modName, names) ->
              return m { mUses = (modName, names) : mUses m }
            Nothing -> fatal ("bad use (line " ++ show ln
                              ++ "): use MODULE { name1, name2, ... }")
      | s == "raw" = return m { mHelp = "" : mHelp m }
      | Just r <- stripPrefix "raw " s = return m { mHelp = r : mHelp m }
      | Just r <- stripPrefix "field " s =
          parseFieldDecl ln r >>= addField
      | Just r <- stripPrefix "assert-dd-zero " s = return m { mDd = Just (strip r) }
      | Just r <- stripPrefix "embedding " s =
          case strip r of
            ('[':r1) | last r1 == ']' ->
              return m { mEmbed = Just (splitTop ',' (init r1)) }
            _ -> fatal ("bad embedding (line " ++ show ln ++ ")")
      | Just r <- stripPrefix "metric scale " s =
          case strip r of
            ('[':r1) | last r1 == ']' ->
              let es = splitTop ',' (init r1)
              in if mDim m == 0
                   then fatal ("dimension must be declared before metric scale (line " ++ show ln ++ ")")
                   else if length es == mDim m
                   then return m { mMetric = Just es }
                   else fatal ("metric scale needs " ++ show (mDim m)
                               ++ " factors (line " ++ show ln ++ ")")
            _ -> fatal ("bad metric scale (line " ++ show ln ++ ")")
      | Just r <- stripPrefix "metric " s =
          let nm = strip r
          in if not (validSurfaceName nm)
               then fatal ("bad metric name: " ++ nm ++ " (line " ++ show ln ++ ")")
               else do
                 rejectReservedName ln nm
                 return m { mMetricName = Just nm }
      | Just r <- stripPrefix "dimension " s = dim r
      | Just r <- stripPrefix "dim " s = dim r
      | Just r <- stripPrefix "axes " s =
          return m { mAxes = map strip (splitTop ',' r) }
      | otherwise = fatal ("unrecognized: " ++ s ++ " (line " ++ show ln ++ ")")
      where
        addField fd =
          return m { mFlds = (fdName fd, kindFromFieldDecl fd) : mFlds m
                   , mFieldDecls = fd : mFieldDecls m }
        dim r | all isDigit (strip r), n <- read (strip r) =
                  if n < (1 :: Int) || n > 3
                    then fatal ("Formurae currently supports dimension 1, 2, or 3 (got "
                                ++ show n ++ ")")
                    else return m { mDim = n }
              | otherwise = fatal ("bad dimension (line " ++ show ln ++ ")")
        useForm r =
          let (modName, rest0) = span (not . isSpace) (strip r)
              rest1 = strip rest0
          in case rest1 of
               ('{':body) | not (null body), last body == '}' ->
                 let names = map strip (splitTop ',' (init body))
                 in if null modName || null names || any null names
                      then Nothing
                      else Just (modName, names)
               _ -> Nothing

    ini ln s m
      | Just (nm, ix, ex) <- casForm s = do
          rejectReservedName ln (dropWhileEnd (== '\'') nm)
          if null ix
            then return m { mInits = ICas nm ex : mInits m }
            else do
              let baseNm = dropWhileEnd (== '\'') nm
              if baseNm /= nm
                then fatal ("indexed CAS initializer target cannot be primed: "
                            ++ nm ++ showIxParts ix ++ " (line " ++ show ln ++ ")")
                else return ()
              validateInitTarget baseNm ix
              if isIndexKind (kindOf m baseNm)
                then return m { mInits = ICasIndex baseNm ix ex : mInits m }
                else fatal ("CAS initializer with indices needs an indexed tensor field: "
                            ++ nm ++ showIxParts ix ++ " (line " ++ show ln ++ ")")
      | Just (nm, lhsIx, rhs) <- rawForm s = do
          rejectReservedName ln nm
          validateInitTarget nm lhsIx
          case (kindOf m nm, vecLit rhs) of
            (Just SymM, Just (rows, rhsIx)) -> do
              validateInitSuffix nm lhsIx rhsIx
              rows' <- mapM (\r -> case vecLit (strip r) of
                        Just (es, []) -> return (map strip es)
                        Just (_, ix) -> fatal ("tensor initializer row must not have an index suffix: "
                                               ++ showIxParts ix ++ " (line " ++ show ln ++ ")")
                        Nothing -> fatal ("symmetric initializer rows must be [| ... |] (line "
                                          ++ show ln ++ ")")) rows
              comps <-
                if fullMatrixRows rows'
                  then if symmetricRows rows'
                         then return [matrixAt rows' a b
                                     | (a, b) <- rank2Pairs (symComponentIndices (mDim m))]
                         else fatal ("symmetric initializer is not symmetric (line " ++ show ln ++ ")")
                  else if upperSymRows rows'
                         then return [upperSymAt rows' a b
                                     | (a, b) <- rank2Pairs (symComponentIndices (mDim m))]
                         else fatal ("symmetric initializer needs a full matrix or upper-triangle rows (line "
                                     ++ show ln ++ ")")
              return m { mInits = ISym nm comps : mInits m }
            (Just AntiM, Just (rows, rhsIx)) -> do
              validateInitSuffix nm lhsIx rhsIx
              rows' <- mapM (\r -> case vecLit (strip r) of
                        Just (es, []) -> return (map strip es)
                        Just (_, ix) -> fatal ("antisymmetric initializer row must not have an index suffix: "
                                               ++ showIxParts ix ++ " (line " ++ show ln ++ ")")
                        Nothing -> fatal ("antisymmetric initializer rows must be [| ... |] (line "
                                          ++ show ln ++ ")")) rows
              comps <-
                if fullMatrixRows rows'
                  then if antisymmetricRows rows'
                         then return [matrixAt rows' a b
                                     | (a, b) <- rank2Pairs (antiComponentIndices (mDim m))]
                         else fatal ("antisymmetric initializer is not antisymmetric (line "
                                     ++ show ln ++ ")")
                  else if upperAntiRows rows'
                         then return [upperAntiAt rows' a b
                                     | (a, b) <- rank2Pairs (antiComponentIndices (mDim m))]
                         else fatal ("antisymmetric initializer needs a full matrix or upper-off-diagonal rows (line "
                                     ++ show ln ++ ")")
              return m { mInits = IAnti nm comps : mInits m }
            (Just (Tensor2 _), Just (rows, rhsIx)) -> do
              validateInitSuffix nm lhsIx rhsIx
              rows' <- mapM (\r -> case vecLit (strip r) of
                        Just (es, []) -> return (map strip es)
                        Just (_, ix) -> fatal ("tensor initializer row must not have an index suffix: "
                                               ++ showIxParts ix ++ " (line " ++ show ln ++ ")")
                        Nothing -> fatal ("tensor initializer rows must be [| ... |] (line "
                                          ++ show ln ++ ")")) rows
              comps <-
                if fullMatrixRows rows'
                  then return [matrixAt rows' a b
                              | (a, b) <- rank2Pairs (componentIndices (mDim m) (Tensor2 False))]
                  else fatal ("tensor initializer needs a full matrix (line "
                              ++ show ln ++ ")")
              return m { mInits = ITensor2 nm comps : mInits m }
            (k, Just (elems, rhsIx)) -> do
              validateInitSuffix nm lhsIx rhsIx
              let ok = case k of
                         Just (Vector _) -> True
                         Just (Form _) -> True
                         _ -> False
              if not ok
                then fatal ("[| ... |] initializer needs a vector/form/tensor field: "
                            ++ nm ++ " (line " ++ show ln ++ ")")
                else if length elems /= componentCount k
                  then fatal ("[| ... |] initializer needs " ++ show (componentCount k)
                              ++ " components (line "
                              ++ show ln ++ ")")
                  else return m { mInits = IVec nm elems : mInits m }
            _
              | not (null lhsIx) ->
                  fatal ("indexed initializer needs a [| ... |] literal with matching suffix: "
                         ++ nm ++ showIxParts lhsIx ++ " = [| ... |]"
                         ++ showIxParts lhsIx ++ " (line " ++ show ln ++ ")")
              | otherwise -> return m { mInits = IRaw nm rhs : mInits m }
      | otherwise = fatal ("bad init: " ++ s ++ " (line " ++ show ln ++ ")")
      where
        casForm t = do
          (nm, ix, r1) <- initLhs t
          let (nm', r1') = case stripPrefix "'" r1 of
                             Just r -> (nm ++ "'", r)
                             Nothing -> (nm, r1)
          r2 <- stripPrefix ":=" (dropWhile isSpace r1')
          let ex = strip r2
          if null ex then Nothing else Just (nm', ix, ex)
        rawForm t = do
          (nm, ix, r1) <- initLhs t
          r2 <- stripPrefix "=" (dropWhile isSpace r1)
          let ex = strip r2
          if null ex then Nothing else Just (nm, ix, ex)
        initLhs t =
          case indexedLhs t of
            Just lhs@(_, _, r1) | assignmentFollows r1 -> Just lhs
            Nothing -> do
              (nm, r1) <- identW t
              Just (nm, [], r1)
            _ -> do
              (nm, r1) <- identW t
              Just (nm, [], r1)
        indexedLhs (c:cs) | isAlpha c = do
          let (a, r1) = span isAlphaNum cs
              nm = c : a
          (ix, r2) <- parseMarkedPrefix r1
          Just (nm, ix, r2)
        indexedLhs _ = Nothing
        assignmentFollows r =
          case dropWhile isSpace r of
            '=':_ -> True
            ':':'=':_ -> True
            '\'':rest -> assignmentFollows rest
            _ -> False
        identW (c:cs) | isAlpha c = let (a, b) = span isW cs in Just (c : a, b)
        identW _ = Nothing
        vecLit t = do
          (elems, rest) <- vecLitWithRest t
          ix <- parseMarkedSeq (strip rest)
          return (elems, ix)
        vecLitWithRest t = do
          r1 <- stripPrefix "[|" (strip t)
          closeVec (0 :: Int) [] r1
        closeVec _ _ [] = Nothing
        closeVec d acc ('|':']':rest)
          | d == 0 = Just (splitTop ',' (reverse acc), rest)
          | otherwise = closeVec (d - 1) (']' : '|' : acc) rest
        closeVec d acc ('[':'|':rest) =
          closeVec (d + 1) ('|' : '[' : acc) rest
        closeVec d acc (c:rest) = closeVec d (c : acc) rest
        validateInitTarget nm ix =
          case fieldDeclOf m nm of
            Just fd
              | fieldDeclAcceptsParts fd ix -> return ()
              | fdIndex fd /= Nothing && null ix ->
                  fatal ("indexed field initializer must write declared indices: "
                         ++ nm ++ fieldDeclIndexSuffix fd ++ " = [| ... |]"
                         ++ fieldDeclIndexSuffix fd ++ " (line " ++ show ln ++ ")")
              | fdIndex fd == Nothing ->
                  fatal ("field " ++ nm ++ " has no declared index variance; remove "
                         ++ showIxParts ix ++ " from the initializer (line "
                         ++ show ln ++ ")")
              | otherwise ->
                  fatal ("initializer for field " ++ nm
                         ++ " has incompatible index variance: "
                         ++ nm ++ showIxParts ix ++ " (line " ++ show ln ++ ")")
            Nothing
              | null ix -> return ()
              | otherwise ->
                  fatal ("indexed initializer refers to unknown field: "
                         ++ nm ++ showIxParts ix ++ " (line " ++ show ln ++ ")")
        validateInitSuffix nm lhsIx rhsIx
          | null lhsIx && null rhsIx = return ()
          | null rhsIx =
              fatal ("indexed initializer RHS must carry the same suffix as the LHS: "
                     ++ nm ++ showIxParts lhsIx ++ " = [| ... |]"
                     ++ showIxParts lhsIx ++ " (line " ++ show ln ++ ")")
          | null lhsIx =
              fatal ("initializer RHS has indices but the LHS does not: "
                     ++ nm ++ " = [| ... |]" ++ showIxParts rhsIx
                     ++ " (line " ++ show ln ++ ")")
          | lhsIx == rhsIx = return ()
          | otherwise =
              fatal ("initializer RHS index suffix " ++ showIxParts rhsIx
                     ++ " does not match LHS suffix " ++ showIxParts lhsIx
                     ++ " (line " ++ show ln ++ ")")
        normExpr = filter (not . isSpace)
        stripOuterParens t =
          let u = normExpr t
          in case u of
               '(':rest | not (null rest), last rest == ')' -> init rest
               _ -> u
        isZeroExpr t = stripOuterParens t `elem` ["0", "0.0"]
        negatesExpr lhs upper =
          let l = stripOuterParens lhs
              u = stripOuterParens upper
          in l == "0-" ++ u
             || l == "-" ++ u
             || l == "(-1)*" ++ u
             || l == "-1*" ++ u
        rowLengthsMatch lens rows = map length rows == lens
        fullMatrixRows rows =
          length rows == mDim m && all ((== mDim m) . length) rows
        matrixAt rows a b = rows !! (a - 1) !! (b - 1)
        upperSymRows rows =
          length rows == mDim m && rowLengthsMatch [mDim m, mDim m - 1 .. 1] rows
        upperSymAt rows a b =
          let lo = min a b
              hi = max a b
          in rows !! (lo - 1) !! (hi - lo)
        upperAntiRows rows =
          length rows == max 0 (mDim m - 1)
          && rowLengthsMatch [mDim m - 1, mDim m - 2 .. 1] rows
        upperAntiAt rows a b =
          let lo = min a b
              hi = max a b
          in rows !! (lo - 1) !! (hi - lo - 1)
        symmetricRows rows =
          and [matrixAt rows a b == matrixAt rows b a
              | a <- axisRange m, b <- axisRange m, a < b]
        antisymmetricRows rows =
          and [isZeroExpr (matrixAt rows a a) | a <- axisRange m]
          && and [negatesExpr (matrixAt rows b a) (matrixAt rows a b)
                 | a <- axisRange m, b <- axisRange m, a < b]
        componentCount (Just kind) = length (componentIndices (mDim m) kind)
        componentCount Nothing = mDim m

    -- Step equations keep superscripts (~i) and subscripts (_i)
    -- distinct.  The current component expander still lowers existing
    -- Euclidean/Staggered fields to the same stored components, but
    -- variance is preserved long enough for metric references such as
    -- g~i_j and for future variance-aware contraction checks.
    stp ln s0 m
      | Just bad <- banned =
          fatal (bad ++ " (line " ++ show ln ++ ")")
      | Just (nm, ix, ex) <- eqForm "let" s = do
          rejectReservedName ln nm
          return m { mSteps = Step KLet nm ix ex : mSteps m }
      | Just (nm, _, ex) <- eqForm "local" s = do
          rejectReservedName ln nm
          return m { mSteps = Step KLocal nm [] ex : mSteps m }
      | Just (nm, ixs, ex) <- primeEqForm s = do
          rejectReservedName ln nm
          return m { mSteps = Step KEq nm ixs ex : mSteps m }
      | otherwise = fatal ("bad step eq: " ++ s ++ " (line " ++ show ln ++ ")")
      where
        s = s0
        banned = surfaceBanned m s

surfaceBanned :: Model -> String -> Maybe String
surfaceBanned m s =
  foldr (\t acc -> checkTok t `orElse` acc) Nothing (tokenize s)
  `orElse`
  foldr (\t acc -> checkIndexTok t `orElse` acc) Nothing (itok s)
  where
    checkTok (TId nm _)
      | Just ax <- stripPrefix "d_" nm, ax `elem` mAxes m =
          Just ("coordinate derivative must be written ∂" ++ ax
                ++ "; ∂_" ++ ax ++ " and d_" ++ ax ++ " are not part of Formurae")
      | Just ax <- stripPrefix "d2_" nm, ax `elem` mAxes m =
          Just ("d2 is not an operator; write ∂" ++ ax ++ " (∂" ++ ax
                ++ " u) for the second difference: " ++ nm)
      | take 3 nm == "d2_" =
          Just ("d2 is not an operator; write ∂a (∂a u) for the second difference: " ++ nm)
      | ("delta" : ps) <- splitOn '_' nm, any ((> 1) . length) ps =
          Just ("Kronecker delta takes one index per mark (delta~i_j): " ++ nm)
    checkTok _ = Nothing
    checkIndexTok (II nm) =
      case parseIndexedIdent nm of
        ("delta", parts@(_:_))
          | not (length parts == 2 && all isSingleAlphaIx parts) ->
              Just ("Kronecker delta takes two single marked indices, e.g. delta~i_j: " ++ nm)
        ("epsilon", parts@(_:_))
          | not (length parts == 3 && all isSingleAlphaIx parts) ->
              Just ("epsilon takes three single marked indices, e.g. epsilon~i~j~k: " ++ nm)
        _ -> Nothing
    checkIndexTok _ = Nothing
    orElse (Just x) _ = Just x
    orElse Nothing y = y

-- --------------------------------------------------- expression rewriting

data Tok = TId String Bool   -- identifier, followed-by-prime
         | TC Char

tokenize :: String -> [Tok]
tokenize [] = []
tokenize (c:cs)
  | isAlpha c =
      let (a, b) = span isW cs
      in case b of
           ('\'':b') -> TId (c : a) True : tokenize b'
           _ -> TId (c : a) False : tokenize b
  | otherwise = TC c : tokenize cs

data Elem = EId String Bool | EC Char | ERaw String
          | EMarkV String | EMarkL String

-- the field to which lb is applied, if any (scans the same
-- preprocessed form the rewriter uses, so Δ and delta (d u) count)
lbTarget :: Model -> Maybe String
lbTarget m = case concatMap scan (mSteps m) of
               (nm:_) -> Just nm
               [] -> Nothing
  where
    scan st = go (tokenize (stepPre m (sEx st)))
    go (TId "lb" False : ts) =
      case dropWhile isSp ts of
        (TId nm False : rest) | kindOf m nm == Just Scalar -> nm : go rest
        _ -> go ts
    go (_ : ts) = go ts
    go [] = []
    isSp (TC c) = isSpace c
    isSp _ = False


-- ------------------------------------ tensor index equations (staggered)
--
-- v'~i   = v~i + (dt / rho0) * ∂_j s~i_j
-- s'~i_j = s~i_j + dt * (la * δ~i_j * ∂_k v'~k + mu * (∂_i v'~j + ∂_j v'~i))
--
-- Free indices come from the left-hand side; a repeated index letter
-- inside a term is summed over 1..dimension (Einstein convention).
-- δ~i_j is Kronecker's delta, and epsilon~i~j~k is the 3D Levi-Civita
-- symbol.
-- ∂_a applied to a staggered field component is the
-- half-cell difference anchored at the placement of the TARGET
-- component (Virieux/Yee); symmetric components are canonicalized
-- (s_2_1 means s_1_2).

data ITok = II String | IC Char deriving Eq

itok :: String -> [ITok]
itok [] = []
itok (c:cs)
  | isAlpha c =
      let (a, b) = span (\ch -> isAlphaNum ch || ch == '_' || ch == '~' || ch == '\'') cs
      in II (c : a) : itok b
  | otherwise = IC c : itok cs

data Variance = VUp | VDown deriving (Eq, Show)
data IxPart = IxPart Variance String deriving (Eq, Show)

ixName :: IxPart -> String
ixName (IxPart _ nm) = nm

ixNames :: [IxPart] -> [String]
ixNames = map ixName

isIndexI :: [IxPart] -> Bool
isIndexI parts = ixNames parts == ["i"]

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

isSingleAlphaIx :: IxPart -> Bool
isSingleAlphaIx (IxPart _ [c]) = isAlpha c
isSingleAlphaIx _ = False

varianceWord :: Variance -> String
varianceWord VUp = "Up"
varianceWord VDown = "Down"

tensorInternalBase :: String -> [Variance] -> String
tensorInternalBase nm vars =
  reservedInternalPrefix ++ "Tensor" ++ nm ++ concatMap varianceWord vars

metricInternalBase :: Variance -> Variance -> String
metricInternalBase VUp VUp = reservedInternalPrefix ++ "MetricContra"
metricInternalBase VUp VDown = reservedInternalPrefix ++ "MetricMixedUpDown"
metricInternalBase VDown VUp = reservedInternalPrefix ++ "MetricMixedDownUp"
metricInternalBase VDown VDown = reservedInternalPrefix ++ "MetricCov"

splitOn :: Char -> String -> [String]
splitOn ch = foldr step [[]]
  where
    step c acc@(cur:rest) | c == ch = [] : acc
                          | otherwise = (c : cur) : rest
    step _ [] = [[]]

plOf :: [Bool] -> String
plOf hs = "[" ++ intercalate ", " [if h then "1 / 2" else "0" | h <- hs] ++ "]"

axisRange :: Model -> [Int]
axisRange m = [1 .. mDim m]

zeroPlaceM :: Model -> String
zeroPlaceM m = plOf (replicate (mDim m) False)

placeV :: Model -> Int -> String
placeV m a = plOf [c == a | c <- axisRange m]

placeS :: Model -> Int -> Int -> String
placeS m a b
  | a == b = zeroPlaceM m
  | otherwise = plOf [c == a || c == b | c <- axisRange m]

leviCivita3 :: [Int] -> Int
leviCivita3 xs
  | sort xs /= [1, 2, 3] = 0
  | xs `elem` [[1, 2, 3], [2, 3, 1], [3, 1, 2]] = 1
  | otherwise = -1

indexContractionDots :: String -> String
indexContractionDots = go Nothing
  where
    go _ [] = []
    go prev ('.':cs)
      | maybe False isSpace prev
      , case cs of
          c:_ -> isSpace c
          [] -> False
      = '*' : go (Just '*') cs
    go _ (c:cs) = c : go (Just c) cs

fieldBaseOf :: String -> (String, Int)
fieldBaseOf w = (takeWhile (/= '\'') w, length (filter (== '\'') w))

ixVariance :: IxPart -> Variance
ixVariance (IxPart v _) = v

fieldIndexParts :: FieldDecl -> Maybe [IxPart]
fieldIndexParts fd =
  case fdIndex fd of
    Just (FieldIndex [Plain parts]) -> Just parts
    Just (FieldIndex [Symmetric parts]) -> Just parts
    Just (FieldIndex [Antisymmetric parts]) -> Just parts
    _ -> Nothing

componentRank :: Kind -> Int
componentRank Scalar = 0
componentRank (Vector _) = 1
componentRank (Form k) = k
componentRank SymM = 2
componentRank AntiM = 2
componentRank (Tensor2 _) = 2

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
componentIndices dim (Vector _) = [[a] | a <- [1 .. dim]]
componentIndices dim (Form k) = choose k [1 .. dim]
componentIndices dim SymM = symComponentIndices dim
componentIndices dim AntiM = antiComponentIndices dim
componentIndices dim (Tensor2 _) = [[a, b] | a <- [1 .. dim], b <- [1 .. dim]]

rank2Pairs :: [[Int]] -> [(Int, Int)]
rank2Pairs = map pairOf
  where
    pairOf [a, b] = (a, b)
    pairOf xs = error ("internal rank-2 component shape: " ++ show xs)

componentVariances :: Model -> String -> Kind -> [Maybe Variance]
componentVariances m nm kind =
  case fieldDeclOf m nm >>= fieldIndexParts of
    Just parts | length parts == componentRank kind -> map (Just . ixVariance) parts
    _ -> replicate (componentRank kind) Nothing

storageIndexTag :: Maybe Variance -> Int -> String
storageIndexTag Nothing a = "_" ++ show a
storageIndexTag (Just VUp) a = "_up" ++ show a
storageIndexTag (Just VDown) a = "_down" ++ show a

componentStorageName :: Model -> String -> Kind -> [Int] -> String
componentStorageName m nm kind inds =
  nm ++ concat (zipWith storageIndexTag (componentVariances m nm kind) inds)

internalCoordNames :: Model -> [String]
internalCoordNames m = take (mDim m) ["x", "y", "z"]

internalHstepNames :: Model -> [String]
internalHstepNames m = take (mDim m) ["hx", "hy", "hz"]

internalIndexNames :: Model -> [String]
internalIndexNames m = take (mDim m) ["i", "j", "k"]

componentStorageNames :: Model -> String -> Kind -> [String]
componentStorageNames m nm kind =
  [ componentStorageName m nm kind inds | inds <- componentIndices (mDim m) kind ]

componentStorageNamesOf :: Model -> String -> [String]
componentStorageNamesOf m nm =
  case kindOf m nm of
    Just kind -> componentStorageNames m nm kind
    Nothing -> [nm]

firstComponentStorageName :: Model -> String -> String
firstComponentStorageName m nm =
  case componentStorageNamesOf m nm of
    x:_ -> x
    [] -> nm

egisonComponentName :: String -> Int -> [Int] -> String
egisonComponentName nm primes inds =
  nm ++ replicate primes '\'' ++ concatMap (('_' :) . show) inds

fieldStorageMapEntries :: Model -> (String, Kind) -> [(String, String)]
fieldStorageMapEntries m (nm, kind) =
  [ (egisonComponentName nm primes inds, storage ++ replicate primes '\'')
  | (inds, storage) <- zip (componentIndices (mDim m) kind) (componentStorageNames m nm kind)
  , primes <- [0, 1]
  ]

strictEinstein :: Model -> [String] -> [IxPart] -> String -> IO ()
strictEinstein m lets lhs expr = do
  alts <- regionOccurrences (itok (indexContractionDots expr))
  mapM_ checkTerm alts
  where
    regionOccurrences ts = fmap concat (mapM termOccurrences (splitTerms ts))

    splitTerms = go (0 :: Int) []
      where
        go _ cur [] = [reverse cur | not (null cur)]
        go d cur (t@(IC c) : rest)
          | c `elem` "([" = go (d + 1) (t : cur) rest
          | c `elem` ")]" = go (d - 1) (t : cur) rest
          | d == 0 && c `elem` "+-" =
              if null cur
                then go d cur rest
                else reverse cur : go d [] rest
        go d cur (t : rest) = go d (t : cur) rest

    termOccurrences ts = go [[]] ts
      where
        go acc [] = return acc
        go acc (II w : rest) = do
          occ <- identOccurrences w
          go (map (++ occ) acc) rest
        go acc (IC '(' : rest) = do
          let (inner, rest') = matchGroup ')' rest
          innerAlts <- regionOccurrences inner
          go [a ++ b | a <- acc, b <- innerAlts] rest'
        go acc (IC '[' : rest) = do
          let (inner, rest') = matchGroup ']' rest
          innerAlts <- regionOccurrences inner
          go [a ++ b | a <- acc, b <- innerAlts] rest'
        go acc (_ : rest) = go acc rest

    matchGroup close = goG (0 :: Int) []
      where
        goG _ acc [] = (reverse acc, [])
        goG d acc (IC c : rest)
          | c == close && d == 0 = (reverse acc, rest)
          | c == close = goG (d - 1) (IC c : acc) rest
          | (close == ')' && c == '(') || (close == ']' && c == '[') =
              goG (d + 1) (IC c : acc) rest
        goG d acc (t : rest) = goG d (t : acc) rest

    identOccurrences w =
      let (base0, parts) = parseIndexedIdent w
          (base, _) = fieldBaseOf base0
      in case () of
           _
             | Just metricNm <- mMetricName m, base == metricNm ->
                 metricOccurrences metricNm parts w
             | base == "epsilon", not (null parts) ->
                 if mDim m /= 3
                   then fatal ("epsilon currently requires dimension 3: " ++ w)
                   else if length parts == 3 && all isSingleAlphaIx parts
                   then return parts
                   else fatal ("epsilon takes three single marked indices, e.g. epsilon~i~j~k: " ++ w)
             | base == "delta", not (null parts) ->
                 kroneckerOccurrences parts w
             | base == "d", not (null parts) ->
                 derivativeOccurrences parts w
             | fieldDeclOf m base /= Nothing && not (null parts) -> do
                 validateFieldRefParts m lets w
                 return parts
             | base `elem` lets && not (null parts) ->
                 return parts
             | otherwise ->
                 return []

    metricOccurrences metricNm parts w =
      if length parts == 2 && all indexedMetricPart parts
        then return parts
        else fatal ("metric tensor " ++ metricNm ++ " needs exactly two marked indices: " ++ w)

    kroneckerOccurrences [p, q] w
      | all isSingleAlphaIx [p, q] =
          if isMixedPair p q
            then return [p, q]
            else fatal ("Kronecker delta must be mixed, e.g. delta~i_j; use a declared metric tensor for covariant/contravariant components: " ++ w)
    kroneckerOccurrences _ w =
      fatal ("Kronecker delta takes two single marked indices, e.g. delta~i_j: " ++ w)

    derivativeOccurrences [p@(IxPart VDown _)] _ = return [p]
    derivativeOccurrences [_] w =
      fatal ("indexed derivative must use a lower index, e.g. d_i or ∂_i: " ++ w)
    derivativeOccurrences _ w =
      fatal ("indexed derivative takes one lower index, e.g. d_i or ∂_i: " ++ w)

    indexedMetricPart (IxPart _ nm) = all isAlphaNum nm && not (null nm)
    isMixedPair (IxPart VUp _) (IxPart VDown _) = True
    isMixedPair (IxPart VDown _) (IxPart VUp _) = True
    isMixedPair _ _ = False

    checkTerm occs = do
      mapM_ checkFree lhs
      mapM_ checkDummy dummyNames
      where
        names = nub (map ixName occs ++ map ixName lhs)
        lhsNames = map ixName lhs
        dummyNames = [nm | nm <- names, nm `notElem` lhsNames]
        sameName nm (IxPart _ nm') = nm == nm'
        checkFree lp@(IxPart lv ln) =
          case filter (sameName ln) occs of
            [IxPart rv _] | rv == lv -> return ()
            [] -> fatal ("free index " ++ showIx lp ++ " is missing in term: " ++ expr)
            [_] -> fatal ("free index " ++ showIx lp ++ " has wrong variance in term: " ++ expr)
            _ -> fatal ("free index " ++ ixName lp ++ " appears more than once in term: " ++ expr)
        checkDummy nm =
          case filter (sameName nm) occs of
            [IxPart VUp _, IxPart VDown _] -> return ()
            [IxPart VDown _, IxPart VUp _] -> return ()
            [_] -> fatal ("index " ++ nm ++ " is free but not on the left-hand side in term: " ++ expr)
            [_, _] -> fatal ("dummy index " ++ nm ++ " must appear once up and once down in term: " ++ expr)
            [] -> return ()
            _ -> fatal ("index " ++ nm ++ " appears more than twice in term: " ++ expr)

    showIx (IxPart VUp nm) = "~" ++ nm
    showIx (IxPart VDown nm) = "_" ++ nm

validateFieldRefParts :: Model -> [String] -> String -> IO ()
validateFieldRefParts m lets w =
  let (base0, parts) = parseIndexedIdent w
      (fname, _) = fieldBaseOf base0
  in case fieldDeclOf m fname of
       Just fd -> validateDecl fd parts
       Nothing | fname `elem` lets -> return ()
       _ -> return ()
  where
    validateDecl fd parts =
      case (fdIndex fd, parts) of
        (Nothing, []) -> return ()
        (Nothing, _ : _) ->
          fatal ("field " ++ fdName fd ++ " has no declared index variance; use the indexed field syntax in its declaration")
        (Just _, []) -> return ()
        (Just (FieldIndex [Plain decl]), _) ->
          if sameVarianceList decl parts
            then return ()
            else fatal ("field " ++ fdName fd ++ " is referenced with incompatible index variance: " ++ w)
        (Just (FieldIndex [Symmetric decl]), _) ->
          if sameVarianceList decl parts || sameVarianceList (reverse decl) parts
            then return ()
            else fatal ("symmetric field " ++ fdName fd ++ " is referenced with incompatible index variance: " ++ w)
        (Just (FieldIndex [Antisymmetric decl]), _) ->
          if sameVarianceList decl parts || sameVarianceList (reverse decl) parts
            then return ()
            else fatal ("antisymmetric field " ++ fdName fd ++ " is referenced with incompatible index variance: " ++ w)
        _ -> fatal ("unsupported field index declaration for " ++ fdName fd)

indexDefs :: Model -> [String] -> Step -> IO [String]
indexDefs m lets st = do
  validateFieldRefParts m lets (sNm st ++ concatMap ixSuffix (sIdx st))
  strictEinstein m lets (sIdx st) (sEx st)
  case (kindOf m (sNm st), sIdx st) of
    (Just (Vector staggered), [fi]) ->
      mapM (\a -> comp [(ixName fi, a)]
                         (if staggered then placeV m a else zeroPlaceM m)
                         (base ++ show a)) (axisRange m)
    (Just SymM, [fi, fj]) ->
      mapM (\(a, b) -> comp [(ixName fi, a), (ixName fj, b)] (placeS m a b) (base ++ show a ++ show b))
           (rank2Pairs (symComponentIndices (mDim m)))
    (Just AntiM, [fi, fj]) ->
      mapM (\(a, b) -> comp [(ixName fi, a), (ixName fj, b)] (placeS m a b) (base ++ show a ++ show b))
           (rank2Pairs (antiComponentIndices (mDim m)))
    (Just (Tensor2 staggered), [fi, fj]) ->
      mapM (\(a, b) -> comp [(ixName fi, a), (ixName fj, b)]
                              (if staggered then placeS m a b else zeroPlaceM m)
                              (base ++ show a ++ show b))
           (rank2Pairs (componentIndices (mDim m) (Tensor2 staggered)))
    _ -> fatal ("index equation has wrong indices for its field kind: " ++ sNm st)
  where
    base = "feq" ++ sNm st
    comp env anchor defnm = do
      e <- ixExpand m lets env anchor (sEx st)
      return ("def " ++ defnm ++ " := " ++ e)

-- expand one component: parens are independent regions, a repeated
-- index letter is summed over the smallest term containing it, then
-- names and derivatives are resolved
ixExpand :: Model -> [String] -> [(String, Int)] -> String -> String -> IO String
ixExpand m lets env anchor expr = expandRegion env (itok (indexContractionDots expr))
  where
    -- a region is a +/- separated list of terms
    expandRegion env' ts = goR env' (0 :: Int) [] ts
    goR env' _ cur [] = expandTerm env' (reverse cur)
    goR env' d cur (t@(IC c) : rest)
      | c `elem` "([" = goR env' (d + 1) (t : cur) rest
      | c `elem` ")]" = goR env' (d - 1) (t : cur) rest
      | d == 0 && c `elem` "+-" = do
          e1 <- expandTerm env' (reverse cur)
          e2 <- goR env' 0 [] rest
          return (e1 ++ [c] ++ e2)
    goR env' d cur (t : rest) = goR env' d (t : cur) rest

    -- one term: sum its own (depth-0) dummies, then resolve
    expandTerm env' ts =
      case levelDummies env' ts of
        (k:_) -> do
          parts <- mapM (\n -> expandTerm ((k, n) : env') ts) (axisRange m)
          return ("(" ++ intercalate " + " parts ++ ")")
        [] -> resolve env' ts

    levelDummies env' ts = nub (go2 (0 :: Int) ts)
      where
        go2 _ [] = []
        go2 d (IC c : rest)
          | c `elem` "([" = go2 (d + 1) rest
          | c `elem` ")]" = go2 (d - 1) rest
          | otherwise = go2 d rest
        go2 d (II w : rest)
          | d == 0 = [l | l <- idxLetters w, lookup l env' == Nothing] ++ go2 d rest
          | otherwise = go2 d rest

    idxLetters w =
      let (_, parts) = parseIndexedIdent w
      in [ ixName pt | pt <- parts, isSingleAlphaIx pt ]

    resolveIx env' pt
      | all isDigit pt = Just (read pt)
      | otherwise = lookup pt env'

    -- resolve a dummy-free term; parens recurse as fresh regions
    resolve _ [] = return ""
    resolve env' (IC '(' : rest) = do
      let (inner, rest') = matchParen (0 :: Int) [] rest
      e <- expandRegion env' inner
      fmap (("(" ++ e ++ ")") ++) (resolve env' rest')
    resolve env' (IC c : rest) = fmap ([c] ++) (resolve env' rest)
    resolve env' (II w : rest)
      -- Kronecker delta, one index per mark: delta~i_j / \948~i_j
      -- The variance is intentionally kept: delta is the mixed identity,
      -- while the declared metric name (for example g_i_j / g~i~j when
      -- `metric g` is present) denotes metric tensors.
      | Just (_, [p, q]) <- metricIdent splitIdentW
      , indexedMetricPart p, indexedMetricPart q = do
          pv <- need env' (ixName p)
          qv <- need env' (ixName q)
          fmap ((metricRef p q pv qv) ++) (resolve env' rest)
      | Just (metricNm, _ : _) <- metricIdent splitIdentW =
          fatal ("metric tensor " ++ metricNm ++ " needs exactly two marked indices: " ++ w
                 ++ " (examples: " ++ metricNm ++ "~i~j, " ++ metricNm ++ "~i_j, "
                 ++ metricNm ++ "_i~j, " ++ metricNm ++ "_i_j)")
      | ("epsilon", [p, q, r]) <- splitIdentW
      , all isSingleAlphaIx [p, q, r] = do
          if mDim m /= 3
            then fatal ("epsilon currently requires dimension 3: " ++ w)
            else return ()
          vals <- mapM (need env' . ixName) [p, q, r]
          fmap ((show (leviCivita3 vals)) ++) (resolve env' rest)
      | ("delta", [p, q]) <- splitIdentW
      , all isSingleAlphaIx [p, q] = do
          if not (isMixedPair p q)
            then fatal ("Kronecker delta must be mixed, e.g. delta~i_j; use a declared metric tensor for covariant/contravariant components: " ++ w)
            else return ()
          pv <- need env' (ixName p)
          qv <- need env' (ixName q)
          fmap ((if pv == qv then "1" else "0") ++) (resolve env' rest)
      | ("delta", _ : _) <- splitIdentW =
          fatal ("Kronecker delta takes two single marked indices, e.g. delta~i_j: " ++ w)
      | ("epsilon", _ : _) <- splitIdentW =
          fatal ("epsilon takes three single marked indices, e.g. epsilon~i~j~k: " ++ w)
      | ("d", [k]) <- splitIdentW = do
          n <- need env' (ixName k)
          let rest1 = dropWhile isSp rest
          case rest1 of
            (II opw : rest2) -> do
              ref <- fieldRef env' opw
              fmap (deriv n ref ++) (resolve env' rest2)
            _ -> fatal ("d_" ++ ixName k ++ " needs a field operand: " ++ expr)
      | isField = do
          ref <- fieldRef env' w
          fmap (fst ref ++) (resolve env' rest)
      | not (null (snd splitIdentW)) =
          fatal ("unknown indexed tensor: " ++ w
                 ++ " (declare metric " ++ fst splitIdentW
                 ++ " to use it as the metric tensor)")
      | otherwise = fmap (w ++) (resolve env' rest)
      where
        splitIdentW = parseIndexedIdent w
        isField = (kindOf m (fst (fieldBaseOf (fst splitIdentW))) /= Nothing
                   || fst (fieldBaseOf (fst splitIdentW)) `elem` lets)
                  && not (null (snd splitIdentW))
        metricIdent (base, parts) =
          case mMetricName m of
            Just metricNm | base == metricNm -> Just (metricNm, parts)
            _ -> Nothing
        isMixedPair (IxPart VUp _) (IxPart VDown _) = True
        isMixedPair (IxPart VDown _) (IxPart VUp _) = True
        isMixedPair _ _ = False
        indexedMetricPart (IxPart _ nm) = all isAlphaNum nm && not (null nm)
        metricRef (IxPart v1 _) (IxPart v2 _) a b =
          metricInternalBase v1 v2 ++ "_" ++ show a ++ "_" ++ show b

    matchParen d acc (IC ')' : rest)
      | d == 0 = (reverse acc, rest)
      | otherwise = matchParen (d - 1) (IC ')' : acc) rest
    matchParen d acc (t@(IC '(') : rest) = matchParen (d + 1) (t : acc) rest
    matchParen d acc (t : rest) = matchParen d (t : acc) rest
    matchParen _ acc [] = (reverse acc, [])

    isSp (IC c) = isSpace c
    isSp _ = False

    need env' l = case resolveIx env' l of
      Just n -> return n
      Nothing -> fatal ("unresolved index '" ++ l ++ "' in: " ++ expr)

    fieldRef env' w = do
      let (b, parts) = parseIndexedIdent w
          (fname, primes) = fieldBaseOf b
      validateFieldRefParts m lets w
      ns <- mapM (need env' . ixName) parts
      case (kindOf m fname, ns) of
        (Just (Vector staggered), [a]) ->
          return (fname ++ replicate primes '\'' ++ "_" ++ show a,
                  if staggered then placeV m a else zeroPlaceM m)
        (Just (Form _), [a]) ->
          return (fname ++ replicate primes '\'' ++ "_" ++ show a,
                  zeroPlaceM m)
        (Just SymM, [a, b2]) ->
          let (lo, hi) = (min a b2, max a b2)
          in return (fname ++ replicate primes '\'' ++ "_" ++ show lo ++ "_" ++ show hi,
                     placeS m a b2)
        (Just AntiM, [a, b2]) ->
          let (lo, hi) = (min a b2, max a b2)
              comp = fname ++ replicate primes '\'' ++ "_" ++ show lo ++ "_" ++ show hi
              signed | a == b2 = "0"
                     | a < b2 = comp
                     | otherwise = "(0 - " ++ comp ++ ")"
          in return (signed, placeS m a b2)
        (Just (Tensor2 staggered), [a, b2]) ->
          return (fname ++ replicate primes '\'' ++ "_" ++ show a ++ "_" ++ show b2,
                  if staggered then placeS m a b2 else zeroPlaceM m)
        (Just Scalar, []) ->
          return (fname ++ replicate primes '\'', zeroPlaceM m)
        (Nothing, [a]) | fname `elem` lets, primes == 0 ->
          return (fname ++ "_" ++ show a, zeroPlaceM m)
        _ -> fatal ("bad field reference in index equation: " ++ w)

    deriv n (comp, place) =
      "dYee " ++ show n ++ " " ++ anchor ++ " (" ++ comp ++ ", " ++ place ++ ")"

isIndexKind :: Maybe Kind -> Bool
isIndexKind (Just (Vector _)) = True
isIndexKind (Just SymM) = True
isIndexKind (Just AntiM) = True
isIndexKind (Just (Tensor2 _)) = True
isIndexKind _ = False

-- names X whose updated value X' is referenced in some step RHS
primedRefs :: Model -> [String]
primedRefs m = sort (nub [nm | st <- mSteps m, TId nm True <- tokenize (sEx st)
                             , kindOf m nm /= Nothing])

opPass :: Model -> [String] -> [Tok] -> [Elem]
opPass m lets = go
  where
    forms = [(n, d) | (n, Form d) <- mFlds m]
    vecs = [n | (n, Vector False) <- mFlds m]
    go [] = []
    go (TId op False : ts)
      | op `elem` vecOps
      , (sp@(_:_), ts1) <- span isSpaceTok ts
      , (TId nm pr : ts2) <- ts1 =
          case lookup nm forms of
            Just _ ->
              let fn = if op `elem` deltaOps then "codiff" else "dForm"
                  tag = nm ++ (if pr then "fN" else "f")
              in EMarkL ("formComps (" ++ fn ++ " " ++ tag ++ ")") : go ts2
            Nothing
              | op == "d" || op `elem` deltaOps ->
                  EId op False : map toElem sp ++ go ts1
              | nm `elem` vecs || nm `elem` lets ->
                  let core = op ++ " " ++ nm ++ (if pr then "'" else "") ++ "_#"
                  in (if op `elem` vecRet then EMarkV core else ERaw core) : go ts2
              | otherwise -> EId op False : map toElem sp ++ go ts1
    go (t : ts) = toElem t : go ts
    isSpaceTok (TC c) = isSpace c
    isSpaceTok _ = False
    toElem (TId n p) = EId n p
    toElem (TC c) = EC c

-- rename user axis names to the internal coordinates x,y,z as needed
renameAxes :: Model -> String -> String
renameAxes m = concatMap out . tokenize
  where
    out (TId nm pr) = subst nm ++ (if pr then "'" else "")
    out (TC c) = [c]
    subst nm = case lookup nm (zip (mAxes m) (internalCoordNames m)) of
                 Just v -> v
                 Nothing -> nm

-- the Laplace-Beltrami stencil: flux divergence over the coefficient
-- fields generated for the declared metric
lbExpansion :: Model -> String
lbExpansion m =
  "((" ++ intercalate " + "
    [ "dYee " ++ show a ++ " " ++ zeroPlaceM m
      ++ " (f" ++ show a ++ ", " ++ placeV m a ++ ")"
    | a <- axisRange m ]
  ++ ") / sg)"

-- mathematical derivative operators, resolved by axis name
mathOps :: Model -> String -> String
mathOps m = concatMap out . tokenize
  where
    axmap = zip (mAxes m) (map show (axisRange m))
    out (TId nm pr)
      | not pr, Just rest <- stripPrefix "pd2_" nm, Just n <- lookup rest axmap = "dC2 " ++ n
      | not pr, Just rest <- stripPrefix "pd_" nm, Just n <- lookup rest axmap = "dC " ++ n
      | not pr, nm == "lap4" = ['\916', '4']   -- alias of the main spelling Δ4
      | otherwise = nm ++ (if pr then "'" else "")
    out (TC c) = [c]

metricOn :: Model -> Bool
metricOn m = mMetric m /= Nothing || mEmbed m /= Nothing

-- shared step-expression preprocessing: fuse repeated d, lower
-- delta (d u), rename axes, resolve math operators (incl. Δ)
stepPre :: Model -> String -> String
stepPre m = mathOps m . renameAxes m . lowerDeltaD m . fuseDD

isSpTok :: Tok -> Bool
isSpTok (TC c) = isSpace c
isSpTok _ = False

untok :: [Tok] -> String
untok = concatMap out
  where
    out (TId nm pr) = nm ++ (if pr then "'" else "")
    out (TC c) = [c]

-- collect tokens up to the ')' closing an already-consumed '('
closeParenT :: Int -> [Tok] -> [Tok] -> Maybe ([Tok], [Tok])
closeParenT _ [] _ = Nothing
closeParenT n (TC '(' : ts) acc = closeParenT (n + 1) ts (TC '(' : acc)
closeParenT n (TC ')' : ts) acc
  | n == 1 = Just (reverse acc, ts)
  | otherwise = closeParenT (n - 1) ts (TC ')' : acc)
closeParenT n (t : ts) acc = closeParenT n ts (t : acc)

-- ∂a (∂a X) fuses to the compact second difference pd2_a (X): repeated
-- derivatives pair up as staggered half-cell differences (forward then
-- backward), which is the dC2 stencil -- not the double-width central
-- composition -- so writing d twice generates byte-identical code.
fuseDD :: String -> String
fuseDD = untok . go . tokenize
  where
    go (TId d1 False : ts)
      | Just ax <- stripPrefix "pd_" d1
      , (_, TC '(' : ts1) <- span isSpTok ts
      , (_, TId d2 False : ts2) <- span isSpTok ts1
      , stripPrefix "pd_" d2 == Just ax
      , Just (inner, rest) <- closeParenT 1 ts2 []
      = TId ("pd2_" ++ ax) False : TC '(' : go inner ++ (TC ')' : go rest)
    go (t : ts) = t : go ts
    go [] = []

-- delta (d u) on a scalar field lowers to minus the Laplacian: the
-- codifferential of the exterior derivative is -lap (flat) or -lb
-- (with a declared metric), so `u' = u - dt * delta (d u)` is the heat
-- equation written with the basic operators only.
lowerDeltaD :: Model -> String -> String
lowerDeltaD m = untok . go . tokenize
  where
    lapNm = if metricOn m then "lb" else "lap"
    go (TId "delta" False : ts)
      | (_, TC '(' : ts1) <- span isSpTok ts
      , (_, TId "d" False : ts2) <- span isSpTok ts1
      , Just (inner, rest) <- closeParenT 1 ts2 []
      = case bareIdent inner of
          Just (nm, pr) | kindOf m nm == Just Scalar ->
            tokenize ("((0 - 1) * " ++ lapNm ++ " " ++ nm ++ (if pr then "'" else "") ++ ")")
              ++ go rest
          -- compound operand: flat geometry only (the metric flux
          -- machinery is anchored to a named field)
          _ | not (metricOn m) ->
            tokenize ("((0 - 1) * lap (" ++ untok inner ++ "))") ++ go rest
          _ -> TId "delta" False : go ts
    go (t : ts) = t : go ts
    go [] = []
    bareIdent ts = case filter (not . isSpTok) ts of
      [TId nm pr] -> Just (nm, pr)
      [TC '(', TId nm pr, TC ')'] -> Just (nm, pr)
      _ -> Nothing

rewrite :: Model -> [String] -> Maybe String -> String -> IO String
rewrite m lets mk expr = fmap concat (mapM render (attach elems))
  where
    elems = lbPass (opPass m lets (tokenize (stepPre m expr)))
    lbPass [] = []
    lbPass (EId "lb" False : rest0) =
      case dropWhile isSp rest0 of
        (EId nm False : rest) | kindOf m nm == Just Scalar ->
          ERaw (lbExpansion m) : lbPass rest
        _ -> EId "lb" False : lbPass rest0
      where isSp (EC c) = isSpace c
            isSp _ = False
    lbPass (e : rest) = e : lbPass rest
    forms = [n | (n, Form _) <- mFlds m]
    vecs = [n | (n, Vector False) <- mFlds m]
    -- pair each element with the next character (to skip function calls)
    attach es = zip es (map nextC (drop 1 (map Just es) ++ [Nothing]))
    nextC (Just (EC c)) = Just c
    nextC _ = Nothing
    render (EId nm pr, nxt) =
      case mk of
        Just k | nm `elem` forms
                 && nxt /= Just '(' ->
          return (componentByOrdinal nm pr k)
        Just k | (nm `elem` vecs || nm `elem` lets)
                 && nxt /= Just '(' ->
          return (nm ++ (if pr then "'" else "") ++ "_" ++ k)
        _ -> return (nm ++ (if pr then "'" else ""))
    render (EC c, _) = return [c]
    render (ERaw t, _) = return t
    render (EMarkV t, _) =
      case mk of
        Just k -> return ("(" ++ t ++ ")_" ++ k)
        Nothing -> return ("(" ++ t ++ ")")
    render (EMarkL t, _) =
      case mk of
        Just "i" -> fatal ("forms cannot appear in an unindexed vector equation: " ++ expr)
        Just k -> return ("nth " ++ k ++ " (" ++ t ++ ")")
        Nothing -> return ("(" ++ t ++ ")")
    componentByOrdinal nm pr k =
      case reads k of
        [(idx, "")] ->
          case kindOf m nm of
            Just kind ->
              case drop (idx - 1) (componentIndices (mDim m) kind) of
                inds:_ -> nm ++ (if pr then "'" else "") ++ concatMap (('_' :) . show) inds
                [] -> nm ++ (if pr then "'" else "") ++ "_" ++ k
            Nothing ->
              case drop (idx - 1) (componentStorageNamesOf m nm) of
                comp:_ -> comp ++ (if pr then "'" else "")
                [] -> nm ++ (if pr then "'" else "") ++ "_" ++ k
        _ -> nm ++ (if pr then "'" else "") ++ "_" ++ k

rewriteScalar :: Model -> [String] -> String -> IO String
rewriteScalar m lets expr =
  let pre = stepPre m expr
  in if hasIndexSyntax m pre
       then strictEinstein m lets [] pre
            >> ixExpand m lets [] (zeroPlaceM m) pre
       else rewrite m lets Nothing expr

hasIndexSyntax :: Model -> String -> Bool
hasIndexSyntax m = any indexedTok . itok
  where
    indexedTok (II nm) =
      case parseIndexedIdent nm of
        (_, parts@(_:_)) ->
          all isIndexPart parts
          && not (isAxisDerivative nm parts)
        _ -> False
    indexedTok _ = False
    isIndexPart (IxPart _ [c]) = isAlpha c || isDigit c
    isIndexPart _ = False
    isAxisDerivative nm parts =
      (take 2 nm == "d_" || take 3 nm == "d2_")
      && all (\p -> ixName p `elem` mAxes m) parts

-- ---------------------------------------------------------------- emitter

escQ :: String -> String
escQ = concatMap (\c -> if c == '"' then "\\\"" else [c])

escH :: String -> String
escH = concatMap esc
  where
    esc '\\' = "\\\\"
    esc '"' = "\\\""
    esc c = [c]

emit :: Model -> IO String
emit m = do
  if length (mAxes m) /= mDim m
    then fatal ("axes count (" ++ show (length (mAxes m))
                ++ ") does not match dimension (" ++ show (mDim m) ++ ")")
    else return ()
  let lets = [sNm st | st <- mSteps m, sk st == KLet, isIndexI (sIdx st)]
      prims = primedRefs m
  if mMetric m /= Nothing && mEmbed m /= Nothing
    then fatal "declare either 'metric scale' or 'embedding', not both"
    else return ()
  mtx <- case (lbTarget m, mMetric m, mEmbed m) of
    (Just _, Nothing, Nothing) ->
      fatal "lb needs a 'metric scale [...]' or 'embedding [...]' declaration"
    (Just u, Just hs, _) -> return (Just (u, map (renameAxes m) hs))
    (Just u, Nothing, Just _) ->
      return (Just (u, ["feH" ++ show a | a <- axisRange m]))
    (Nothing, _, _) -> return Nothing
  let internalCoords = internalCoordNames m
      internalHsteps = internalHstepNames m
      internalGridSteps = map ("d" ++) (mAxes m)
      internalIndexVars = internalIndexNames m
      coordVec = "[| " ++ intercalate ", " internalCoords ++ " |]"
      hstepVec = "[| " ++ intercalate ", " internalHsteps ++ " |]"
      coordArgs = intercalate ", " internalCoords
      axisIds = [1 .. mDim m]
      axisList = "[" ++ intercalate ", " (map show axisIds) ++ "]"
      symbolDecl = "declare symbol " ++ intercalate ", " (internalCoords ++ internalHsteps)
      axisPairList =
        "[" ++ intercalate ", " [ "(" ++ show a ++ ", " ++ show b ++ ")"
                                | a <- axisIds, b <- axisIds ] ++ "]"
      ifChain cases fallback =
        foldr (\(cond, value) rest -> "if " ++ cond ++ " then " ++ value ++ " else " ++ rest)
              fallback cases
      formBasisExpr =
        ifChain [("k = " ++ show k, egiIntLists (componentIndices (mDim m) (Form k)))
                | k <- [0 .. mDim m]]
                "[]"
      basisSignInputs =
        nub (concat [permutations basis
                    | k <- [0 .. mDim m]
                    , basis <- componentIndices (mDim m) (Form k)])
      basisSignExpr =
        ifChain [("xs = " ++ egiIntList xs, show (permSign xs))
                | xs <- basisSignInputs]
                "0"
      hasExt names = any (hasUse m "exterior-calculus") names
      hasVec names = any (hasUse m "vector-calculus") names
      needsVectorContext = hasVec ["dGrad", "curl", "divg"]
      needsFormContext = hasExt ["d", "delta", "codiff", "dForm", "hodge"] || mDd m /= Nothing
      needsStaggeredContext =
        any (\(_, k) -> k == Vector True || k == SymM || k == AntiM || k == Tensor2 True) (mFlds m)
      needsYeeContext = mtx /= Nothing || needsFormContext || needsStaggeredContext
      symbolCase sym repl = "    | #\"" ++ sym ++ "\" -> \"" ++ repl ++ "\""
      contextDecls =
            [ symbolDecl
            , "def feDim : Integer := " ++ show (mDim m)
            , "def feAxes : [String] := " ++ egiStringList (mAxes m)
            , "def feAxisIds : [Integer] := " ++ axisList
            , "def feCoords : Vector MathValue := " ++ coordVec
            , "def feHsteps : Vector MathValue := " ++ hstepVec
            , "def coords : Vector MathValue := feCoords"
            , "def hsteps : Vector MathValue := feHsteps"
            , "def axisName (a: Integer) : String := nth a " ++ egiStringList internalIndexVars
            , "def symName (v: String) : String :="
            , "  match v as string with"
            ]
            ++ [ symbolCase h g | (h, g) <- zip internalHsteps internalGridSteps ]
            ++ [ symbolCase c ("(" ++ ix ++ "*" ++ g ++ ")")
               | (c, ix, g) <- zip3 internalCoords internalIndexVars internalGridSteps ]
            ++ [ "    | _ -> v" ]
      contextMathDecls = scalarContextDecls
                         ++ (if needsVectorContext then vectorContextDecls else [])
                         ++ (if needsYeeContext then yeeContextDecls else [])
                         ++ (if needsFormContext then formContextDecls else [])
      scalarContextDecls =
            [ "def shift (a: Integer) (c: MathValue) (u: MathValue) : MathValue :="
            , "  substitute [(feCoords_a, feCoords_a + c * feHsteps_a)] u"
            , "def dC (a: Integer) (u: MathValue) : MathValue :="
            , "  (shift a 1 u - shift a (-1) u) / (2 * feHsteps_a)"
            , "def dC2 (a: Integer) (u: MathValue) : MathValue :="
            , "  (shift a 1 u - 2 * u + shift a (-1) u) / ((feHsteps_a) ^ 2)"
            , "def dF (a: Integer) (u: MathValue) : MathValue := (shift a 1 u - u) / feHsteps_a"
            , "def dB (a: Integer) (u: MathValue) : MathValue := (u - shift a (-1) u) / feHsteps_a"
            , "def lap (u: MathValue) : MathValue := sum (map (\\a -> dC2 a u) feAxisIds)"
            , "def dTaylor (m: Integer) (ks: [MathValue]) (a: Integer) (u: MathValue) : MathValue :="
            , "  sum (map (\\(c, k) -> c * shift a k u) (zip (taylorStencil m ks) ks)) / (feHsteps_a ^ m)"
            , "def \916\&4 (u: MathValue) : MathValue :="
            , "  sum (map (\\a -> dTaylor 2 [-2, -1, 0, 1, 2] a u) feAxisIds)"
            ]
      vectorContextDecls =
            [ "def dGrad (X: Vector MathValue) : Matrix MathValue :="
            , "  generateTensor (\\[a, b] -> dC a X_b) [feDim, feDim]"
            , "def curl (X: Vector MathValue) : Vector MathValue :="
            , "  withSymbols [i, j, k] (\949 3)~i~j~k . (dGrad X)_j_k"
            , "def divg (X: Vector MathValue) : MathValue := trace (dGrad X)"
            ]
      yeeContextDecls =
            [ "def feIndexPairs : [(Integer, Integer)] := " ++ axisPairList
            , "def yeeRef (sT: [MathValue]) (fld: (MathValue, [MathValue])) (disp: [MathValue]) : MathValue :="
            , "  let (fF, sF) := fld"
            , "   in substitute"
            , "        (map (\\a -> (feCoords_a, feCoords_a + (nth a disp + nth a sT - nth a sF) * feHsteps_a)) feAxisIds)"
            , "        fF"
            , "def unit3 (a: Integer) (c: MathValue) : [MathValue] :="
            , "  map (\\b -> if a = b then c else 0) feAxisIds"
            , "def dYee (a: Integer) (sT: [MathValue]) (fld: (MathValue, [MathValue])) : MathValue :="
            , "  (yeeRef sT fld (unit3 a (1 / 2)) - yeeRef sT fld (unit3 a (-1 / 2))) / feHsteps_a"
            , "def curlYee (i1: Integer) (sT: [MathValue]) (flds: [(MathValue, [MathValue])]) : MathValue :="
            , "  sum (map (\\(j1, k1) -> (\949 3)_i1_j1_k1 * dYee j1 sT (nth k1 flds))"
            , "           feIndexPairs)"
            ]
      formContextDecls =
            [ "def formBasis (k: Integer) : [[Integer]] := " ++ formBasisExpr
            , "def basisSign (xs: [Integer]) : MathValue := " ++ basisSignExpr
            , "def basisContains (a: Integer) (basis: [Integer]) : Bool :="
            , "  any (\\b -> a = b) basis"
            , "def basisRemove (a: Integer) (basis: [Integer]) : [Integer] :="
            , "  filter (\\b -> not (a = b)) basis"
            , "def complementBasis (basis: [Integer]) : [Integer] :="
            , "  filter (\\a -> not (basisContains a basis)) feAxisIds"
            , "def formIndex (basis: [Integer]) : Integer :="
            , "  head (map (\\(_, idx) -> idx)"
            , "            (filter (\\(b, _) -> b = basis)"
            , "                    (zip (formBasis (length basis)) (between 1 (length (formBasis (length basis)))))))"
            , "def formComponent (basis: [Integer]) (cs: [MathValue]) : MathValue :="
            , "  nth (formIndex basis) cs"
            , "def sigmaOf (basis: [Integer]) : [MathValue] :="
            , "  map (\\a -> if basisContains a basis then 1 / 2 else 0) feAxisIds"
            , "def sigmaC (c: Integer) (basis: [Integer]) : [MathValue] :="
            , "  if c = 0 then sigmaOf basis else sigmaOf (complementBasis basis)"
            , "def hodge (f: (Integer, Integer, [MathValue])) : (Integer, Integer, [MathValue]) :="
            , "  let (c, k, cs) := f"
            , "   in let kd := feDim - k"
            , "   in (1 - c, kd,"
            , "       map (\\basis ->"
            , "              let src := complementBasis basis"
            , "               in basisSign (src ++ basis) * formComponent src cs)"
            , "           (formBasis kd))"
            , "def dForm (f: (Integer, Integer, [MathValue])) : (Integer, Integer, [MathValue]) :="
            , "  let (c, k, cs) := f"
            , "   in let kp := k + 1"
            , "   in (c, kp,"
            , "       map (\\basis ->"
            , "              foldl (\\acc a ->"
            , "                       let src := basisRemove a basis"
            , "                        in acc + basisSign ([a] ++ src) * dYee a (sigmaC c basis) (formComponent src cs, sigmaC c src))"
            , "                    0 basis)"
            , "           (formBasis kp))"
            , "def codiff (f: (Integer, Integer, [MathValue])) : (Integer, Integer, [MathValue]) :="
            , "  scaleForm ((-1) ^ (feDim * (formDeg f + 1) + 1)) (hodge (dForm (hodge f)))"
            , "def \948 := codiff"
            ]
      metricContextDecls =
            case mMetricName m of
              Nothing -> []
              Just _ ->
                let identity = "if i = j then 1 else 0"
                    gen nm expr =
                      "def " ++ nm ++ "_i_j := generateTensor (\\[i, j] -> "
                      ++ expr ++ ") [feDim, feDim]"
                    (covExpr, contraExpr) = case (mMetric m, mEmbed m) of
                      (Just hs0, _) ->
                        let hs = "[" ++ intercalate ", " (map (renameAxes m) hs0) ++ "]"
                            hI = "(nth i " ++ hs ++ ")"
                        in ("if i = j then (" ++ hI ++ ") ^ 2 else 0",
                            "if i = j then 1 / ((" ++ hI ++ ") ^ 2) else 0")
                      (Nothing, Just _) ->
                        ("if i = j then feGd i else feGo i j",
                         "if i = j then 1 / (feGd i) else 0")
                      (Nothing, Nothing) -> (identity, identity)
                in [ gen (metricInternalBase VDown VDown) covExpr
                   , gen (metricInternalBase VUp VUp) contraExpr
                   , gen (metricInternalBase VUp VDown) identity
                   , gen (metricInternalBase VDown VUp) identity
                   ]
      fmrFieldNameCases =
        [ "    | #\"" ++ escH egisonName ++ "\" -> \"" ++ escH storageName ++ "\""
        | (egisonName, storageName) <- concatMap (fieldStorageMapEntries m) (mFlds m)
        , egisonName /= storageName
        ]
        ++ ["    | _ -> nm"]
      printerContextDecls =
            [ "def offsetSuffix (o: MathValue) : String :="
            , "  match o as mathValue with"
            , "    | #0 -> \"\""
            , "    | #1 -> \"+1\""
            , "    | #2 -> \"+2\""
            , "    | #3 -> \"+3\""
            , "    | #(-1) -> \"-1\""
            , "    | #(-2) -> \"-2\""
            , "    | #(-3) -> \"-3\""
            , "    | #(1 / 2) -> \"+1/2\""
            , "    | #(-1 / 2) -> \"-1/2\""
            , "    | #(3 / 2) -> \"+3/2\""
            , "    | #(-3 / 2) -> \"-3/2\""
            , "    | _ -> S.concat [\"+(\", show o, \")\"]"
            , "def gridIndex (a: Integer) (arg: MathValue) : String :="
            , "  S.append (axisName a) (offsetSuffix ((arg - coords_a) / hsteps_a))"
            , "def fmrFieldName (nm: String) : String :="
            , "  match nm as string with"
            ]
            ++ fmrFieldNameCases
            ++
            [ "def gridRef (g: MathValue) (args: [MathValue]) : String :="
            , "  S.concat"
            , "    [fmrFieldName (show g), \"[\","
            , "     S.intercalate \",\" (map (\\(a, arg) -> gridIndex a arg) (zip feAxisIds args)),"
            , "     \"]\"]"
            , "def wrapNeg (s: String) : String :="
            , "  if S.head s = '-' then S.concat [\"(\", s, \")\"] else s"
            , "def applyName g := mathFunctionName g"
            , "def showFactor (f: MathValue) : String :="
            , "  match f as mathValue with"
            , "    | func $g $args -> gridRef g args"
            , "    | apply1 $g $a1 -> S.concat [applyName g, \"(\", showFmr a1, \")\"]"
            , "    | quote $e -> S.concat [\"(\", showFmr e, \")\"]"
            , "    | symbol $v _ -> symName v"
            , "    | _ -> S.concat [\"(\", showFmr f, \")\"]"
            , "def showPow (f: MathValue) (n: Integer) : String :="
            , "  if n = 1 then showFactor f else S.concat [showFactor f, \"**\", show n]"
            , "def coefPQ (c: MathValue) : (String, String) :="
            , "  match c as mathValue with"
            , "    | $p / $q -> (show p, show q)"
            , "def showTerm (t: MathValue) : String :="
            , "  match t as mathValue with"
            , "    | term $c $xs ->"
            , "        let (cp, cq) := coefPQ c"
            , "         in let numFs := map (\\(f, n) -> showPow f n) (filter (\\(f, n) -> n > 0) xs)"
            , "         in let denFs := map (\\(f, n) -> showPow f (0 - n)) (filter (\\(f, n) -> n < 0) xs)"
            , "         in let numParts := if cp = \"1\" && not (numFs = []) then numFs"
            , "                              else wrapNeg cp :: numFs"
            , "         in let denParts := (if cq = \"1\" then [] else [cq]) ++ denFs"
            , "         in let numStr := S.intercalate \"*\" numParts"
            , "         in if denParts = []"
            , "              then numStr"
            , "              else S.concat [numStr, \"/(\", S.intercalate \"*\" denParts, \")\"]"
            , "def showPoly (p: MathValue) : String :="
            , "  match p as mathValue with"
            , "    | #0 -> \"0\""
            , "    | poly $ts / _ -> S.intercalate \" + \" (map showTerm ts)"
            , "def showFmr (e: MathValue) : String :="
            , "  match e as mathValue with"
            , "    | #0 -> \"0\""
            , "    | $nu / #1 -> showPoly nu"
            , "    | $nu / $de -> S.concat [\"(\", showPoly nu, \")/(\", showPoly de, \")\"]"
            , "def fmrEq (lhs: String) (rhs: MathValue) : String :="
            , "  S.concat [\"  \", lhs, \" = \", showFmr rhs]"
            , "def feGridPoint : String := S.intercalate \",\" (map axisName feAxisIds)"
            , "def fmrInit (lhs: String) (rhs: MathValue) : String :="
            , "  S.concat [\"  \", lhs, \"[\", feGridPoint, \"] = \", showFmr rhs]"
            , "def componentEqs (names: [String]) (values: [MathValue]) : [String] :="
            , "  map (\\(name, value) -> fmrEq (S.append name \"'\") value) (zip names values)"
            , "def scalarEq (nm: String) (c: MathValue) : [String] := [fmrEq (S.append nm \"'\") c]"
            , "def tupleOf (xs: [String]) : String :="
            , "  if length xs = 1"
            , "    then head xs"
            , "    else S.concat [\"(\", S.intercalate \",\" xs, \")\"]"
            , "def emitModelOn (dim: Integer) (axes: [String])"
            , "                (params: [(String, String)]) (helpers: [String])"
            , "                (comps: [String]) (initLines: [String])"
            , "                (stepLines: [String]) : String :="
            , "  let compsP := map (\\c -> S.append c \"'\") comps"
            , "   in S.intercalate \"\\n\""
            , "        ([ S.append \"dimension :: \" (show dim)"
            , "         , S.append \"axes :: \" (S.intercalate \",\" axes)"
            , "         , \"\""
            , "         ]"
            , "         ++ map (\\(n, v) -> S.concat [\"double :: \", n, \" = \", v]) params"
            , "         ++ [\"\"] ++ helpers ++ [\"\"]"
            , "         ++ [ S.concat [\"begin function \", tupleOf comps, \" = init()\"]"
            , "            , S.concat [\"  double [] :: \", S.intercalate \", \" comps]"
            , "            ]"
            , "         ++ initLines"
            , "         ++ [ \"end function\""
            , "            , \"\""
            , "            , S.concat [\"begin function \", tupleOf compsP,"
            , "                        \" = step\", \"(\", S.intercalate \",\" comps, \")\"]"
            , "            ]"
            , "         ++ stepLines"
            , "         ++ [ \"end function\" ])"
            ]
      embDefs = case mEmbed m of
        Nothing -> []
        Just es ->
          [ "def feX : [MathValue] := [" ++ intercalate ", " (map (renameAxes m) es) ++ "]"
          , "def feGd (a: Integer) : MathValue := sum (map (\\e -> (\8706/\8706 e feCoords_a) ^ 2) feX)"
          , "def feGo (a: Integer) (b: Integer) : MathValue := sum (map (\\e -> \8706/\8706 e feCoords_a * \8706/\8706 e feCoords_b) feX)"
          ]
          ++ [ "def feH" ++ show a ++ " := unquoteAll (expandAll (sqrt (feGd "
               ++ show a ++ ")))"
             | a <- axisRange m ]
      orthoGate = case mEmbed m of
        Nothing -> []
        Just _ ->
          let offDiag = [(a, b) | a <- axisRange m, b <- axisRange m, a < b]
              cond = intercalate " && "
                       ["feGo " ++ show a ++ " " ++ show b ++ " = 0"
                       | (a, b) <- offDiag]
              msg = "# ERROR: the embedding is not orthogonal (off-diagonal metric terms must vanish symbolically); general metrics are not supported yet"
          in if null offDiag then [] else [(cond, msg)]
  body <- mapM (stepDefs lets) (mSteps m)
  items <- mapM (stepItem lets) (mSteps m)
  inits <- mapM (initLine lets) (mInits m)
  let sqgOf hs = intercalate " * " ["(" ++ h ++ ")" | h <- hs]
      metricCoeffNames = take (mDim m) ["ca", "cb", "cc"]
      metricFluxNames = ["f" ++ show a | a <- axisRange m]
      mtDecls = case mtx of
        Nothing -> []
        Just _ -> [ "def " ++ n ++ " := function (" ++ coordArgs ++ ")"
                  | n <- metricCoeffNames ++ ["sg"] ++ metricFluxNames ]
      mtInits = case mtx of
        Nothing -> []
        Just (_, hs) ->
          [ "fmrInit \"" ++ n ++ "\" (substitute [(feCoords_" ++ show a
            ++ ", feCoords_" ++ show a ++ " + feHsteps_" ++ show a
            ++ " / 2)] (" ++ sqgOf hs ++ " / ((" ++ h ++ ") ^ 2)))"
          | (n, a, h) <- zip3 metricCoeffNames (axisRange m) hs ]
          ++ [ "fmrInit \"sg\" (" ++ sqgOf hs ++ ")" ]
      mtFlds = case mtx of
        Nothing -> []
        Just _ -> [(n, Scalar) | n <- metricCoeffNames ++ ["sg"]]
      mtFlux = case mtx of
        Nothing -> []
        Just (u, _) ->
          [ "[fmrEq \"f" ++ show a ++ "\" (" ++ coeff
            ++ " * dYee " ++ show a ++ " " ++ placeV m a
            ++ " (" ++ u ++ ", " ++ zeroPlaceM m ++ "))]"
          | (a, coeff) <- zip (axisRange m) metricCoeffNames
          ]
      mtPass = case mtx of
        Nothing -> []
        Just _ -> [ "scalarEq \"" ++ n ++ "\" (" ++ n ++ ")"
                  | n <- metricCoeffNames ++ ["sg"] ]
      stepItems = mtFlux ++ [it | Just it <- items] ++ mtPass
      header =
        [ "--"
        , "-- GENERATED by fec (the Formurae compiler) from " ++ mName m
            ++ ".fe -- edit the .fe, not this file"
        , "--"
        , "" ] ++
        (if null (mParams m) then []
         else [ "declare symbol " ++ intercalate ", " (map fst (mParams m)), "" ])
      fieldDecls = concatMap fdecl (mFlds m)
      primDecls = concatMap pdecl prims
      tensorAliasDecls =
        concatMap (\(nm, k) -> tensorAliases nm 0 k) (mFlds m)
        ++ concatMap (\nm -> maybe [] (tensorAliases nm 1) (kindOf m nm)) prims
      localDecls = [ "def " ++ sNm st ++ " := function (" ++ coordArgs ++ ")"
                   | st <- mSteps m, sk st == KLocal ] ++ embDefs ++ mtDecls
      ddDef = case mDd m of
        Nothing -> []
        Just g -> ["def feDD := foldl (\\acc x -> acc + x ^ 2) 0 (formComps (dForm (dForm "
                   ++ dropWhileEnd (== '\'') g ++ "fN)))"]
      feParams = "def feParams := ["
                 ++ intercalate ", " [ "(\"" ++ n ++ "\", \"" ++ v ++ "\")"
                                     | (n, v) <- mParams m ] ++ "]"
      explicitHelps = mHelp m ++ (case mEmbed m of
                              Just _ -> ["extern function :: sqrt"]
                              Nothing -> [])
      helps = autoScalarExterns m explicitHelps ++ explicitHelps
      feHelpers
        | null helps = ["def feHelpers : [String] := []"]
        | otherwise = "def feHelpers :="
            : [ (if i == (0 :: Int) then "  [ " else "  , ") ++ "\"" ++ escH h ++ "\""
              | (i, h) <- zip [0 ..] helps ] ++ ["  ]"]
      feComps = "def feComps : [String] := "
                ++ egiStringList (concat [componentStorageNames m n k
                                          | (n, k) <- mFlds m ++ mtFlds])
      feInits = "def feInits :="
        : [ (if i == (0 :: Int) then "  [ " else "  , ") ++ ln
          | (i, ln) <- zip [0 ..] (concat inits ++ mtInits) ] ++ ["  ]"]
      feSteps = "def feSteps := " ++ intercalate " ++ " stepItems
      emitter = "emitModelOn " ++ show (mDim m) ++ " " ++ egiStringList (mAxes m)
      gates = orthoGate ++ (case mDd m of
                Just _ -> [("feDD = 0",
                            "# ERROR: d . d /= 0 on this grid -- refusing to generate")]
                Nothing -> [])
      emitCall = "print (" ++ emitter ++ " feParams feHelpers feComps feInits feSteps)"
      nest [] = emitCall
      nest ((c, msg):gs) =
        "if " ++ c ++ " then (" ++ nest gs ++ ") else print \"" ++ escH msg ++ "\""
      mainDef
        | null gates = [ "def main (args: [String]) : IO () := " ++ emitCall ]
        | otherwise = [ "def main (args: [String]) : IO () :=", "  " ++ nest gates ]
  return (unlines (header ++ contextDecls ++ contextMathDecls ++ printerContextDecls
                   ++ (if null contextDecls then [] else [""])
                   ++ fieldDecls ++ primDecls ++ localDecls ++ tensorAliasDecls
                   ++ metricContextDecls ++ [""]
                   ++ concat body ++ ddDef ++ [""]
                   ++ [feParams] ++ feHelpers ++ [feComps] ++ feInits
                   ++ [feSteps] ++ [""] ++ mainDef))
  where
    fieldCoordArgs = intercalate ", " (internalCoordNames m)
    shape1 = "[" ++ show (mDim m) ++ "]"
    shape2 = "[" ++ show (mDim m) ++ ", " ++ show (mDim m) ++ "]"
    shapeK k = "[" ++ intercalate ", " (replicate k (show (mDim m))) ++ "]"
    tensorIndexVars k = take k (internalIndexNames m)
    formComponentNames nm primes k =
      [nm ++ primes ++ concatMap (('_' :) . show) inds
      | inds <- componentIndices (mDim m) (Form k)]
    formComponentList nm primes k =
      "[" ++ intercalate ", " (formComponentNames nm primes k) ++ "]"
    fdecl (nm, Scalar) = ["def " ++ nm ++ " := function (" ++ fieldCoordArgs ++ ")"]
    fdecl (nm, Vector _) =
      ["def " ++ nm ++ "_i := generateTensor (\\[i] -> function (" ++ fieldCoordArgs ++ ")) " ++ shape1]
    fdecl (nm, SymM) =
      ["def " ++ nm ++ "_i_j := generateTensor (\\[i, j] -> function (" ++ fieldCoordArgs ++ ")) " ++ shape2]
    fdecl (nm, AntiM) =
      ["def " ++ nm ++ "_i_j := generateTensor (\\[i, j] -> function (" ++ fieldCoordArgs ++ ")) " ++ shape2]
    fdecl (nm, Tensor2 _) =
      ["def " ++ nm ++ "_i_j := generateTensor (\\[i, j] -> function (" ++ fieldCoordArgs ++ ")) " ++ shape2]
    fdecl (nm, Form k) =
      formFamilyDecl nm "" k
      ++ [ "def " ++ nm ++ "f : (Integer, Integer, [MathValue]) := (0, " ++ show k
           ++ ", " ++ formComponentList nm "" k ++ ")" ]
    pdecl nm = case kindOf m nm of
      Just Scalar -> ["def " ++ nm ++ "' := function (" ++ fieldCoordArgs ++ ")"]
      Just (Vector _) ->
        ["def " ++ nm ++ "'_i := generateTensor (\\[i] -> function (" ++ fieldCoordArgs ++ ")) " ++ shape1]
      Just SymM ->
        ["def " ++ nm ++ "'_i_j := generateTensor (\\[i, j] -> function (" ++ fieldCoordArgs ++ ")) " ++ shape2]
      Just AntiM ->
        ["def " ++ nm ++ "'_i_j := generateTensor (\\[i, j] -> function (" ++ fieldCoordArgs ++ ")) " ++ shape2]
      Just (Tensor2 _) ->
        ["def " ++ nm ++ "'_i_j := generateTensor (\\[i, j] -> function (" ++ fieldCoordArgs ++ ")) " ++ shape2]
      Just (Form k) ->
        formFamilyDecl nm "'" k
        ++ [ "def " ++ nm ++ "fN : (Integer, Integer, [MathValue]) := (0, " ++ show k
             ++ ", " ++ formComponentList nm "'" k ++ ")" ]
      Nothing -> []
    formFamilyDecl nm primes k
      | k == 0 =
          ["def " ++ nm ++ primes ++ " := function (" ++ fieldCoordArgs ++ ")"]
      | k > 0 =
          let vars = tensorIndexVars k
          in ["def " ++ nm ++ primes ++ concatMap ('_' :) vars
              ++ " := generateTensor (\\[" ++ intercalate ", " vars
              ++ "] -> function (" ++ fieldCoordArgs ++ ")) " ++ shapeK k]
      | otherwise =
          error ("unsupported form degree in field declaration: " ++ nm)
    tensorAliases nm primes kind = case kind of
      Scalar -> []
      Vector _ -> rank1Aliases nm primes
      Form _ -> []
      SymM -> symRank2Aliases nm primes
      AntiM -> antiRank2Aliases nm primes
      Tensor2 _ -> fullRank2Aliases nm primes
    primedBase nm primes = nm ++ replicate primes '\''
    rank1Aliases nm primes =
      [ "def " ++ tensorInternalBase nm [v] ++ replicate primes '\'' ++ "_i := "
        ++ primedBase nm primes ++ "_i"
      | v <- [VUp, VDown] ]
    symRank2Aliases nm primes =
      [ "def " ++ tensorInternalBase nm vars ++ replicate primes '\'' ++ "_i_j := "
        ++ "generateTensor (\\[i, j] -> if i <= j then "
        ++ primedBase nm primes ++ "_i_j else "
        ++ primedBase nm primes ++ "_j_i) [feDim, feDim]"
      | vars <- [[VUp, VUp], [VUp, VDown], [VDown, VUp], [VDown, VDown]] ]
    antiRank2Aliases nm primes =
      [ "def " ++ tensorInternalBase nm vars ++ replicate primes '\'' ++ "_i_j := "
        ++ "generateTensor (\\[i, j] -> if i = j then 0 else if i < j then "
        ++ primedBase nm primes ++ "_i_j else 0 - "
        ++ primedBase nm primes ++ "_j_i) [feDim, feDim]"
      | vars <- [[VUp, VUp], [VUp, VDown], [VDown, VUp], [VDown, VDown]] ]
    fullRank2Aliases nm primes =
      [ "def " ++ tensorInternalBase nm vars ++ replicate primes '\'' ++ "_i_j := "
        ++ primedBase nm primes ++ "_i_j"
      | vars <- [[VUp, VUp], [VUp, VDown], [VDown, VUp], [VDown, VDown]] ]
    stepDefs lets st = case sk st of
      KLet | isIndexI (sIdx st) -> do
               e <- rewrite m lets Nothing (sEx st)
               let nm = sNm st
               return (("def " ++ nm ++ "_i := withSymbols [i] " ++ e)
                       : tensorAliases nm 0 (Vector False))
           | otherwise -> do
               e <- rewriteScalar m lets (sEx st)
               return ["def " ++ sNm st ++ " := " ++ e]
      KEq
        | not (null (sIdx st)), isIndexKind (kindOf m (sNm st)) -> indexDefs m lets st
        | isIndexI (sIdx st) -> do
            e <- rewrite m lets Nothing (sEx st)
            return ["def feq" ++ sNm st ++ "_i := withSymbols [i] " ++ e]
        | kindOf m (sNm st) == Just (Vector False) && null (sIdx st) -> do
            e <- rewrite m lets (Just "i") (sEx st)
            return ["def feq" ++ sNm st ++ "_i := withSymbols [i] " ++ e]
      _ -> return []
    stepItem lets st = case sk st of
      KLet -> return Nothing
      KLocal -> do
        e <- rewriteScalar m lets (sEx st)
        return (Just ("[fmrEq \"" ++ sNm st ++ "\" (" ++ e ++ ")]"))
      KEq
        | Just (Vector True) <- kindOf m (sNm st) ->
            let nm = sNm st
                names = egiStringList (componentStorageNamesOf m nm)
            in return (Just ("componentEqs " ++ names ++ " "
                             ++ egiMathList ["feq" ++ nm ++ show a
                                            | a <- axisRange m]))
          | Just SymM <- kindOf m (sNm st) ->
              let nm = sNm st
                  names = egiStringList (componentStorageNamesOf m nm)
              in return (Just ("componentEqs " ++ names ++ " "
                               ++ egiMathList ["feq" ++ nm ++ show a ++ show b
                                              | (a, b) <- rank2Pairs (symComponentIndices (mDim m))]))
        | Just AntiM <- kindOf m (sNm st) ->
            let nm = sNm st
                names = egiStringList (componentStorageNamesOf m nm)
            in return (Just ("componentEqs " ++ names ++ " "
                             ++ egiMathList ["feq" ++ nm ++ show a ++ show b
                                            | (a, b) <- rank2Pairs (antiComponentIndices (mDim m))]))
        | Just (Tensor2 _) <- kindOf m (sNm st) ->
            let nm = sNm st
                names = egiStringList (componentStorageNamesOf m nm)
            in return (Just ("componentEqs " ++ names ++ " "
                             ++ egiMathList ["feq" ++ nm ++ show a ++ show b
                                            | (a, b) <- rank2Pairs (componentIndices (mDim m) (Tensor2 False))]))
        | not (null (sIdx st)) || kindOf m (sNm st) == Just (Vector False) ->
            let nm = sNm st
                names = egiStringList (componentStorageNamesOf m nm)
            in return (Just ("componentEqs " ++ names ++ " "
                             ++ egiMathList ["feq" ++ nm ++ "_" ++ show a
                                            | a <- axisRange m]))
        | Just (Form _) <- kindOf m (sNm st) -> do
            let names = componentStorageNamesOf m (sNm st)
            cs <- mapM (\k -> rewrite m lets (Just (show k)) (sEx st)) [1 .. length names]
            return (Just ("componentEqs " ++ egiStringList names ++ " "
                          ++ egiMathList ["(" ++ c ++ ")" | c <- cs]))
        | otherwise -> do
            e <- rewriteScalar m lets (sEx st)
            return (Just ("scalarEq \"" ++ sNm st ++ "\" (" ++ e ++ ")"))
    initLine lets it = case it of
      IRaw nm rhs -> return ["\"  " ++ firstComponentStorageName m nm
                             ++ rawGridPoint ++ " = " ++ escQ rhs ++ "\""]
      IVec nm els -> return [ "\"  " ++ lhs ++ rawGridPoint ++ " = " ++ escQ el ++ "\""
                            | (lhs, el) <- zip (componentStorageNamesOf m nm) els ]
      ISym nm els -> return [ "\"  " ++ lhs ++ rawGridPoint ++ " = " ++ escQ el ++ "\""
                            | (lhs, el) <- zip (componentStorageNamesOf m nm) els ]
      IAnti nm els -> return [ "\"  " ++ lhs ++ rawGridPoint ++ " = " ++ escQ el ++ "\""
                             | (lhs, el) <- zip (componentStorageNamesOf m nm) els ]
      ITensor2 nm els -> return [ "\"  " ++ lhs ++ rawGridPoint ++ " = " ++ escQ el ++ "\""
                                | (lhs, el) <- zip (componentStorageNamesOf m nm) els ]
      ICas nm ex -> do
        e <- rewriteScalar m lets ex
        return ["fmrInit \"" ++ nm ++ "\" (" ++ e ++ ")"]
      ICasIndex nm lhsIx ex -> indexedInitLines lets nm lhsIx ex

    indexedInitLines lets nm lhsIx ex = do
      strictEinstein m lets lhsIx pre
      case (kindOf m nm, lhsIx) of
        (Just (Vector staggered), [fi]) ->
          mapM (\a -> comp [a] [(ixName fi, a)]
                       (if staggered then placeV m a else zeroPlaceM m))
               (axisRange m)
        (Just SymM, [fi, fj]) ->
          mapM (\(a, b) -> comp [a, b] [(ixName fi, a), (ixName fj, b)] (placeS m a b))
               (rank2Pairs (symComponentIndices (mDim m)))
        (Just AntiM, [fi, fj]) ->
          mapM (\(a, b) -> comp [a, b] [(ixName fi, a), (ixName fj, b)] (placeS m a b))
               (rank2Pairs (antiComponentIndices (mDim m)))
        (Just (Tensor2 staggered), [fi, fj]) ->
          mapM (\(a, b) -> comp [a, b] [(ixName fi, a), (ixName fj, b)]
                       (if staggered then placeS m a b else zeroPlaceM m))
               (rank2Pairs (componentIndices (mDim m) (Tensor2 staggered)))
        _ -> fatal ("indexed CAS initializer has wrong indices for its field kind: " ++ nm)
      where
        pre = stepPre m ex
        kind = case kindOf m nm of
                 Just k -> k
                 Nothing -> Scalar
        comp inds env anchor = do
          e <- ixExpand m lets env anchor pre
          let lhs = componentStorageName m nm kind inds
          return ("fmrInit \"" ++ lhs ++ "\" (" ++ shiftTo anchor e ++ ")")
        shiftTo anchor e =
          "substitute (map (\\a -> (feCoords_a, feCoords_a + nth a "
          ++ anchor ++ " * feHsteps_a)) feAxisIds) (" ++ e ++ ")"
    rawGridPoint = "[" ++ intercalate "," (internalIndexNames m) ++ "]"

-- Unicode input: Greek letters transliterate to their ASCII names.  A
-- partial-derivative sign followed immediately by an identifier is the
-- coordinate derivative operator (`∂x`); a subscripted partial
-- (`∂_i`) is the indexed derivative.  `∂_x` is therefore rejected when
-- x is a declared axis.  A bare partial sign still becomes d.  The small delta becomes the
-- codifferential, and the minus sign becomes '-'.  The capital delta
-- (Laplacian) is model-dependent and resolved in mathOps instead.
transliterate :: String -> String
transliterate = go
  where
    go [] = []
    go ('\8706':'_':cs) = "d_" ++ go cs
    go ('\8706':cs@(c:_))
      | isAlpha c =
          let (nm, rest) = span isW cs
          in "pd_" ++ concatMap tr nm ++ go rest
    go ('\8706':cs) = "d" ++ go cs
    go (c:cs) = tr c ++ go cs

    tr '\952' = "theta"    -- θ
    tr '\966' = "phi"      -- φ
    tr '\961' = "rho"      -- ρ
    tr '\964' = "tau"      -- τ
    tr '\954' = "kappa"    -- κ
    tr '\955' = "lambda"   -- λ
    tr '\956' = "mu"       -- μ
    tr '\957' = "nu"       -- ν
    tr '\949' = "epsilon"  -- ε
    tr '\963' = "sigma"    -- σ
    tr '\968' = "psi"      -- ψ
    tr '\969' = "omega"    -- ω
    tr '\945' = "alpha"    -- α
    tr '\946' = "beta"     -- β
    tr '\947' = "gamma"    -- γ
    tr '\951' = "eta"      -- η
    tr '\958' = "xi"       -- ξ
    tr '\950' = "zeta"     -- ζ
    tr '\967' = "chi"      -- χ
    tr '\960' = "pi"       -- π
    tr '\948' = "delta"    -- δ
    tr '\8722' = "-"       -- − (minus sign)
    tr c = [c]

-- nabla combinations, resolved before parsing: ∇^2 (or ∇²) is the
-- Laplacian (the capital delta, so lap or lb by geometry), ∇× is curl,
-- ∇· (or ∇.) is divergence.  A space after ∇ is allowed.  A bare ∇
-- passes through (and fails downstream) -- gradients of scalars are
-- written d u (forms) instead.
nablaPass :: String -> String
nablaPass = go
  where
    go [] = []
    go ('\8711':cs) =
      case dropWhile (== ' ') cs of
        ('^':'2':r)  -> '\916' : go r
        ('\178':r)   -> '\916' : go r
        ('\215':r)   -> " curl " ++ go r
        ('\183':r)   -> " divg " ++ go r
        ('.':r)      -> " divg " ++ go r
        _            -> '\8711' : go cs
    go (c:cs) = c : go cs

main :: IO ()
main = do
  args <- getArgs
  case args of
    [path] -> do
      txt <- fmap (nablaPass . transliterate) (readFile path)
      let name = takeWhile (/= '.') (reverse (takeWhile (/= '/') (reverse path)))
      m <- parseFe name txt
      out <- emit m
      putStr out
    _ -> fatal "usage: fec model.fe > model.egi"
