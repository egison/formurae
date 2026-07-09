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
--                                    made available to this file; these are
--                                    library-level operators such as
--                                    exterior-calculus { d, delta } and
--                                    vector-calculus { curl, divg }.
--   def NAME ARG... = EXPR          user-defined operator, expanded at use
--                                    sites (file scope; a body may use only
--                                    operators defined before it).  Operator
--                                    definitions follow Egison: result indices
--                                    are not written in the head; use
--                                    withSymbols for newly introduced free
--                                    indices and contractWith / `.` for
--                                    contraction.
--   def (.) A B = EXPR              user-defined tensor dot operator.
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
-- phi, ...); coordinate derivatives are written as ∂ order radius axis expr
-- in Formurae (with ∂x expr kept as the first-derivative shorthand) and
-- lower to the generated Egison operator ∂ order radius axis expr.  The
-- indexed derivative ∂_i remains distinct.  A bare small delta is the
-- codifferential, indexed delta is Kronecker's delta, and the minus sign is
-- '-'.  Higher mathematical
-- operators such as Δ or Δ4 are ordinary user definitions over these
-- derivative primitives rather than built-in aliases.
-- In index equations superscripts (~i) and subscripts (_i) are kept
-- distinct.  Kronecker's delta is the mixed identity (delta~i_j, or with
-- the small delta sign), while the metric tensor name declared by
-- `metric NAME` lowers to generated tensors according to variance:
-- NAME~i~j, NAME~i_j, NAME_i~j, NAME_i_j.  The fused delta_ij is rejected.
--
-- A vector update may be written without indices (E' = E + dt * curl B).
-- fec lowers it to component extraction from Egison vector values, while
-- the mathematical definition of curl/divg itself stays in generated Egison
-- code.  X' in a RHS refers to the updated field (Formura's primed array),
-- so B' = B - dt * curl E' is the symplectic pair.

import Data.Char (isAlpha, isAlphaNum, isDigit, isSpace)
import Data.List (dropWhileEnd, intercalate, permutations, sort, nub, stripPrefix)
import Control.Monad (foldM)
import System.Environment (getArgs)
import System.IO (hPutStrLn, stderr)

import Formurae.Common
import Formurae.Index
import Formurae.Syntax

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

standardDefs :: [Def]
standardDefs =
  [ Def "." ["A", "B"] "contractWith (+) (A * B)"
  ]

-- ---------------------------------------------------------------- model

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
  ++ map tdBody (mTensorDefs m)
  ++ map defBody (mDefs m)
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

metricNameConflicts :: Model -> [(String, String)]
metricNameConflicts m =
  [("param", nm) | (nm, _) <- mParams m]
  ++ [("field", nm) | (nm, _) <- mFlds m]

validateMetricName :: Model -> IO ()
validateMetricName m =
  case mMetricName m of
    Nothing -> return ()
    Just "delta" ->
      fatal "metric δ is reserved for Kronecker delta; use metric g for the metric tensor"
    Just nm -> do
      let conflicts = nub [kind | (kind, x) <- metricNameConflicts m, x == nm]
      case conflicts of
        [] -> return ()
        _ ->
          hPutStrLn stderr
            ("fec: warning: metric name '" ++ nm ++ "' also appears as "
             ++ intercalate "/" conflicts
             ++ "; bare " ++ nm ++ " keeps that meaning, two-index "
             ++ nm ++ "_i_j/" ++ nm ++ "~i~j is treated as the metric")

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

-- def NAME PARAM... = BODY
-- def (.) A B = BODY
--
-- Operator definitions follow Egison: the result index is not written in the
-- head.  Indices that appear on parameters in the body are views of the
-- argument, not result indices.
defForm :: String -> Maybe Def
defForm r = do
  (nm, r1) <- defNameP (strip r)
  let (lhs, rhs0) = break (== '=') r1
  rhs <- case rhs0 of
           '=':body0 -> Just (strip body0)
           _ -> Nothing
  params <- parseParams (words lhs)
  if null rhs || null params
    then Nothing
    else Just (Def nm params rhs)
  where
    defNameP ('(':'.':')':rest) = Just (".", rest)
    defNameP s = identU s
    identU (c:cs) | isAlpha c = let (a, b) = span isW cs in Just (c : a, b)
    identU _ = Nothing
    parseParams ps =
      if all validParam ps && length ps == length (nub ps)
        then Just ps
        else Nothing
    validParam p =
      validSurfaceName p && null (snd (parseIndexedIdent p))

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
  [ ("exterior-calculus", ["d", "delta", "codiff", "dForm", "hodge"])
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
parseFe name txt = go STop (Model name 0 [] Nothing [] [] [] [] [] [] [] Nothing Nothing Nothing [] [])
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
          mapM_ (\df ->
                    checkUserSurface mUse (defParams df)
                      ("in def " ++ defName df) (defBody df))
                (mDefs mUse)
          mapM_ (\td ->
                    checkUserSurface mUse [tdParam td]
                      ("in def " ++ tdName td) (tdBody td))
                (mTensorDefs mUse)
          mapM_ (\st ->
                    checkUserSurface mUse []
                      ("in step expression: " ++ sEx st) (sEx st))
                (mSteps mUse)
          mapM_ (checkInitUse mUse) (mInits mUse)
          -- resolve user-defined operators (definition order; a body may
          -- use only operators defined before it) and expand all uses.
          -- The tensor dot is a standard prelude operator, not a core
          -- primitive; a user definition later in the file shadows it.
          defs <- resolveDefs (standardDefs ++ reverse (mDefs mUse))
          tensorDefs <- resolveTensorDefs defs (reverse (mTensorDefs mUse))
          let mDef = mUse { mDefs = defs, mTensorDefs = tensorDefs }
          steps' <- mapM (\st -> do ex <- applyDefs defs (sEx st)
                                    return st { sEx = ex })
                         (reverse (mSteps mUse))
          inits' <- mapM (expandInit defs) (reverse (mInits mUse))
          mapM_ (\df ->
                    checkGeneratedSurface mDef (defParams df)
                      ("in def " ++ defName df) (defBody df))
                defs
          mapM_ (\td ->
                    checkGeneratedSurface mDef [tdParam td]
                      ("in def " ++ tdName td) (tdBody td))
                tensorDefs
          mapM_ (\st ->
                    checkGeneratedSurface mDef []
                      ("in step expression: " ++ sEx st) (sEx st))
                steps'
          return mDef { mParams = reverse (mParams mDef), mHelp = reverse (mHelp mDef)
                   , mFlds = reverse (mFlds mDef)
                   , mFieldDecls = reverse (mFieldDecls mDef), mInits = inits'
                   , mSteps = steps' }

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
        allNames = map defName ds
        goD acc [] = return acc
        goD acc (df : more) = do
          body' <- applyDefs acc (defBody df)
          case [w | TId w _ <- tokenize body', w `elem` allNames] of
            (w:_) -> fatal ("def " ++ defName df ++ " uses " ++ w
                            ++ " which is not defined before it")
            [] -> goD (df { defBody = body' } : acc) more

    resolveTensorDefs defs = mapM resolveOne
      where
        resolveOne td = do
          body' <- applyDefs defs (tdBody td)
          return td { tdBody = body' }

    -- expand operator applications.  Bodies are def-free after resolveDefs,
    -- so one pass suffices; arguments are expanded first.
    applyDefs defs s = fmap untok (goE (tokenize s))
      where
        goE ts
          | Just (lhs, op, rhs) <- splitTopAddT ts = do
              lhs' <- goE lhs
              rhs' <- goE rhs
              return (lhs' ++ [TC ' ', TC op, TC ' '] ++ rhs')
        goE ts
          | Just dotDef <- lookupDef "." defs
          , Just parts <- splitTopDotT ts =
              fmap tokenize (expandDot dotDef parts)
        goE [] = return []
        goE (TId nm False : ts)
          | Just df <- lookupDef nm defs = do
              (args, rest') <- parseArgs (length (defParams df)) ts
              args' <- mapM (fmap untok . goE . tokenize) args
              let bodyT = tokenize (substDef df args')
              fmap ((TC '(' : bodyT ++ [TC ')']) ++) (goE rest')
        goE (t : ts) = fmap (t :) (goE ts)

        lookupDef nm defs' =
          case [df | df <- defs', defName df == nm] of
            df:_ -> Just df
            [] -> Nothing

        splitTopAddT ts = goA (0 :: Int) [] ts
          where
            goA _ _ [] = Nothing
            goA d acc (t@(TC c) : rest)
              | c `elem` "([" = goA (d + 1) (t : acc) rest
              | c `elem` ")]" = goA (d - 1) (t : acc) rest
              | d == 0
              , c `elem` "+-"
              , binaryAddOp acc =
                  Just (trimTok (reverse acc), c, trimTok rest)
            goA d acc (t : rest) = goA d (t : acc) rest

        binaryAddOp acc =
          case dropWhile isSpTok acc of
            [] -> False
            TC p : _ | p `elem` "([,+-*/^=" -> False
            TId e False : _ | e == "e" || e == "E" -> False
            _ -> True

        expandDot _ [] = return ""
        expandDot dotDef (p:ps) = do
          first <- fmap untok (goE p)
          foldM (dotApply dotDef) first ps

        dotApply dotDef lhs rhsT = do
          rhs <- fmap untok (goE rhsT)
          return ("(" ++ substDef dotDef [lhs, rhs] ++ ")")

        splitTopDotT ts =
          case goD (0 :: Int) [] ts of
            [_] -> Nothing
            parts -> Just parts
          where
            goD _ acc [] = [trimTok (reverse acc)]
            goD d acc (t@(TC c) : rest)
              | c `elem` "([" = goD (d + 1) (t : acc) rest
              | c `elem` ")]" = goD (d - 1) (t : acc) rest
              | d == 0
              , c == '.'
              , leftSpaceT acc
              , rightSpaceT rest =
                  trimTok (reverse acc) : goD d [] rest
            goD d acc (t : rest) = goD d (t : acc) rest

        leftSpaceT (TC c : _) = isSpace c
        leftSpaceT _ = False

        rightSpaceT (TC c : _) = isSpace c
        rightSpaceT _ = False

        trimTok = dropWhile isSpTok . reverse . dropWhile isSpTok . reverse . dropWhile isSpTok

        parseArgs 0 ts = return ([], ts)
        parseArgs n ts = do
          let rest = dropWhile isSpTok ts
          (arg, rest') <- parseArg rest
          (args, rest'') <- parseArgs (n - 1) rest'
          return (arg : args, rest'')

        parseArg (TC '(' : r) =
          case closeParenT 1 r [] of
            Just (inner, r') ->
              let (suffix, r'') = indexedSuffixT r'
              in return ("(" ++ untok inner ++ ")" ++ suffix, r'')
            Nothing -> fatal "unbalanced argument to operator"
        parseArg (TId a pr : r) =
          let (suffix, r') = indexedSuffixT r
          in return (a ++ (if pr then "'" else "") ++ suffix, r')
        parseArg _ = fatal "operator application needs an argument"

        indexedSuffixT (TC m : TId ix False : rest)
          | m == '~' || m == '_' =
              let (more, rest') = indexedSuffixT rest
              in (m : ix ++ more, rest')
        indexedSuffixT ts = ("", ts)

        substDef df args =
          let env = zip (defParams df) (map parseArgInfo args)
          in substIToks env (itok (defBody df))

        substIToks _ [] = []
        substIToks env (II w : IC '.' : IC '.' : IC '.' : rest) =
          let (appendParts, rest') = indexedSuffixI rest
              (base0, parts) = parseIndexedIdent w
              (base, primes) = fieldBaseOf base0
              headText =
                case lookup base env of
                  Just arg -> argWithAppendParts arg primes parts appendParts
                  Nothing -> w ++ "..." ++ concatMap ixSuffix appendParts
          in headText ++ substIToks env rest'
        substIToks env (tok : rest) =
          substITok env tok ++ substIToks env rest

        substITok _ (IC c) = [c]
        substITok env (II w) =
          let (base0, parts) = parseIndexedIdent w
              (base, primes) = fieldBaseOf base0
          in case lookup base env of
               Just arg | null parts -> argWithPrimes arg primes
                        | otherwise -> argWithParts arg primes parts
               Nothing -> w

        parseArgInfo arg =
          let sArg = strip arg
              simple = all (\c -> isAlphaNum c || c `elem` "_~'") sArg
              (base0, parts) = parseIndexedIdent sArg
              (base, primes) = fieldBaseOf base0
          in (sArg, simple, base, primes, parts)

        argWithPrimes (arg, simple, base, primes0, parts) primes
          | simple = base ++ replicate (primes0 + primes) '\'' ++ concatMap ixSuffix parts
          | primes == 0 = arg
          | otherwise = "(" ++ arg ++ ")" ++ replicate primes '\''

        argWithParts (arg, simple, base, primes0, _) primes parts
          | Just body <- reindexWithSymbols arg parts =
              if primes == 0 then body else "(" ++ body ++ ")" ++ replicate primes '\''
          | simple = base ++ replicate (primes0 + primes) '\'' ++ concatMap ixSuffix parts
          | otherwise = "(" ++ arg ++ ")" ++ concatMap ixSuffix parts

        argWithAppendParts (arg, simple, base, primes0, argParts) primes parts appendParts =
          let keptParts = if null parts then argParts else parts
          in if simple
               then base ++ replicate (primes0 + primes) '\''
                    ++ concatMap ixSuffix (keptParts ++ appendParts)
               else "(" ++ arg ++ ")" ++ concatMap ixSuffix (keptParts ++ appendParts)

        indexedSuffixI (IC m : II nm : rest)
          | m == '~' || m == '_' =
              case parseMarkedPrefix (m : nm) of
                Just (parts, suffixRest) | null suffixRest ->
                  let (more, rest') = indexedSuffixI rest
                  in (parts ++ more, rest')
                _ -> ([], IC m : II nm : rest)
        indexedSuffixI ts = ([], ts)

        reindexWithSymbols arg parts = do
          (names, body) <- parseWithSymbolsArg (stripOuterParensI (itok arg))
          if length names == length parts
            then Just (untokI (map (renameLocalIx (zip names parts)) body))
            else Nothing

        parseWithSymbolsArg ts =
          case dropWhile isSpaceI ts of
            II "withSymbols" : rest -> parseSymbolListI (dropWhile isSpaceI rest)
            _ -> Nothing

        parseSymbolListI (IC '[' : rest) =
          let (inside, rest1) = breakSymbolListI (0 :: Int) [] rest
          in Just (symbolNamesI inside, dropWhile isSpaceI rest1)
        parseSymbolListI _ = Nothing

        breakSymbolListI _ acc [] = (reverse acc, [])
        breakSymbolListI d acc (IC ']' : rest)
          | d == 0 = (reverse acc, rest)
          | otherwise = breakSymbolListI (d - 1) (IC ']' : acc) rest
        breakSymbolListI d acc (IC '[' : rest) =
          breakSymbolListI (d + 1) (IC '[' : acc) rest
        breakSymbolListI d acc (t : rest) = breakSymbolListI d (t : acc) rest

        symbolNamesI = collectSymbolNames
          where
            collectSymbolNames [] = []
            collectSymbolNames (II nm : rest)
              | validSurfaceName nm = nm : collectSymbolNames rest
            collectSymbolNames (_ : rest) = collectSymbolNames rest

        renameLocalIx aliases (II w) =
          let (base0, parts0) = parseIndexedIdent w
              parts1 = map renamePart parts0
          in II (base0 ++ concatMap ixSuffix parts1)
          where
            renamePart p@(IxPart _ nm) =
              case lookup nm aliases of
                Just p' -> p'
                Nothing -> p
        renameLocalIx _ tok = tok

        stripOuterParensI ts =
          case trimIToksLocal ts of
            IC '(' : rest ->
              case closeOuterI (0 :: Int) [] rest of
                Just (inner, rest') | all isSpaceI rest' -> stripOuterParensI inner
                _ -> trimIToksLocal ts
            trimmed -> trimmed

        closeOuterI _ _ [] = Nothing
        closeOuterI d acc (IC ')' : rest)
          | d == 0 = Just (reverse acc, rest)
          | otherwise = closeOuterI (d - 1) (IC ')' : acc) rest
        closeOuterI d acc (IC '(' : rest) =
          closeOuterI (d + 1) (IC '(' : acc) rest
        closeOuterI d acc (t : rest) = closeOuterI d (t : acc) rest

        trimIToksLocal = dropWhile isSpaceI . reverse . dropWhile isSpaceI . reverse . dropWhile isSpaceI

        untokI = concatMap outI
          where
            outI (II w) = w
            outI (IC c) = [c]

        isSpaceI (IC c) = isSpace c
        isSpaceI _ = False

    expandInit defs it = case it of
      ICas nm ex -> do ex' <- applyDefs defs ex
                       return (ICas nm ex')
      ICasIndex nm ix ex -> do ex' <- applyDefs defs ex
                               return (ICasIndex nm ix ex')
      _ -> return it

    checkUserSurface m' locals context body =
      case surfaceBanned m' locals body of
        Just bad -> fatal (bad ++ " " ++ context)
        Nothing ->
          case missingUse m' body of
            Just bad -> fatal (bad ++ " " ++ context)
            Nothing -> return ()

    checkGeneratedSurface m' locals context body =
      case surfaceBanned m' locals body of
        Just bad -> fatal (bad ++ " " ++ context)
        Nothing -> return ()

    checkInitUse m' it = case it of
      ICas nm ex -> checkUserSurface m' [] ("in init expression: " ++ nm) ex
      ICasIndex nm ix ex ->
        checkUserSurface m' [] ("in init expression: " ++ nm ++ showIxParts ix) ex
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
            Just df -> do
              rejectReservedName ln (defName df)
              mapM_ (rejectReservedName ln) (defParams df)
              return m { mDefs = df : mDefs m }
            Nothing -> fatal ("bad def (line " ++ show ln
                              ++ "): def NAME ARG... = EXPR")
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
        banned = surfaceBanned m [] s

surfaceBanned :: Model -> [String] -> String -> Maybe String
surfaceBanned m locals s =
  bareIndexedField (tokenize s)
  `orElse`
  foldr (\t acc -> checkTok t `orElse` acc) Nothing (tokenize s)
  `orElse`
  foldr (\t acc -> checkIndexTok t `orElse` acc) Nothing (itok s)
  where
    bareIndexedField [] = Nothing
    bareIndexedField (TId nm _ : rest)
      | isBareIndexedFieldName nm
      , nm `notElem` locals
      , not (indexedAfter rest) =
          Just ("indexed tensor field " ++ nm
                ++ " must be referenced with indices")
    bareIndexedField (_ : rest) = bareIndexedField rest

    isBareIndexedFieldName nm =
      case parseIndexedIdent nm of
        (base0, []) ->
          let (base, _) = fieldBaseOf base0
          in case fieldDeclOf m base of
               Just fd -> fdIndex fd /= Nothing
               Nothing -> False
        _ -> False

    indexedAfter (TC '~' : _) = True
    indexedAfter (TC '_' : _) = True
    indexedAfter _ = False

    checkTok (TId nm _)
      | Just msg <- invalidDerivativeOp m nm =
          Just msg
      | nm == "badPartialDerivative" =
          Just "coordinate derivative must be written ∂ order radius axis expr, e.g. ∂ 2 1 x u; ∂x u is the only compact shorthand"
      | Just ax <- stripPrefix "d_" nm, ax `elem` mAxes m =
          Just ("coordinate derivative must be written ∂" ++ ax
                ++ "; ∂_" ++ ax ++ " and d_" ++ ax ++ " are not part of Formurae")
      | Just ax <- stripPrefix "d2_" nm, ax `elem` mAxes m =
          Just ("d2 is not an operator; write ∂ 2 1 " ++ ax
                ++ " u for the compact second difference: " ++ nm)
      | take 3 nm == "d2_" =
          Just ("d2 is not an operator; write ∂ 2 1 a u for the compact second difference: " ++ nm)
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

tokenize :: String -> [Tok]
tokenize [] = []
tokenize (c:cs)
  | isAlpha c =
      let (a, b) = span isW cs
      in case b of
           ('\'':b') -> TId (c : a) True : tokenize b'
           _ -> TId (c : a) False : tokenize b
  | otherwise = TC c : tokenize cs

-- the field to which lb is applied, if any (scans the same
-- preprocessed form the rewriter uses, so a user-defined Δ can expand
-- to lb u before this pass)
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
-- Free indices come from the left-hand side.  Repeated upper/lower index
-- letters form diagonal axes; only contractWith, or `.` via contractWith,
-- folds those axes.
-- δ~i_j is Kronecker's delta, and epsilon~i~j~k is the 3D Levi-Civita
-- symbol.
-- ∂_a applied to a staggered field component is the
-- half-cell difference anchored at the placement of the TARGET
-- component (Virieux/Yee); symmetric components are canonicalized
-- (s_2_1 means s_1_2).

strictEinstein :: Model -> [String] -> [IxPart] -> String -> IO ()
strictEinstein m lets lhs expr = do
  alts <- regionOccurrences [] (itok expr)
  mapM_ checkTerm alts
  where
    regionOccurrences aliases ts =
      fmap concat (mapM (termOccurrences aliases) (splitTerms ts))

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

    termOccurrences aliases ts = go [[]] ts
      where
        go acc [] = return acc
        go acc (II "withSymbols" : rest) =
          case parseWithSymbolsBody rest of
            Just (names, body) -> do
              let aliases' = zip names (map ixName lhs) ++ aliases
              innerAlts <- regionOccurrences aliases' body
              return [a ++ b | a <- acc, b <- innerAlts]
            Nothing -> go acc rest
        go acc (II w : rest) = do
          occ <- identOccurrences w
          go (map (++ map (renameIx aliases) occ) acc) rest
        go acc (IC '(' : rest) = do
          let (inner, rest') = matchGroup ')' rest
          innerAlts <- regionOccurrences aliases inner
          go [a ++ b | a <- acc, b <- innerAlts] rest'
        go acc (IC '[' : rest) = do
          let (inner, rest') = matchGroup ']' rest
          innerAlts <- regionOccurrences aliases inner
          go [a ++ b | a <- acc, b <- innerAlts] rest'
        go acc (_ : rest) = go acc rest

    renameIx aliases (IxPart v nm) =
      case lookup nm aliases of
        Just nm' -> IxPart v nm'
        Nothing -> IxPart v nm

    parseWithSymbolsBody rest =
      case dropWhile isSpaceI rest of
        IC '[' : rest1 ->
          let (inside, body) = breakSymbolList (0 :: Int) [] rest1
          in Just (symbolNames inside, dropWhile isSpaceI body)
        _ -> Nothing

    breakSymbolList _ acc [] = (reverse acc, [])
    breakSymbolList d acc (IC ']' : rest)
      | d == 0 = (reverse acc, rest)
      | otherwise = breakSymbolList (d - 1) (IC ']' : acc) rest
    breakSymbolList d acc (IC '[' : rest) =
      breakSymbolList (d + 1) (IC '[' : acc) rest
    breakSymbolList d acc (t : rest) = breakSymbolList d (t : acc) rest

    symbolNames = go
      where
        go [] = []
        go (II nm : rest) | validSurfaceName nm = nm : go rest
        go (_ : rest) = go rest

    isSpaceI (IC c) = isSpace c
    isSpaceI _ = False

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
             | Just metricNm <- mMetricName m
             , base == metricNm
             , length parts == 2
             , all indexedMetricPart parts ->
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
             | Just metricNm <- mMetricName m
             , base == metricNm
             , not (null parts) ->
                 metricOccurrences metricNm parts w
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
            else fatal ("Kronecker delta indices must be mixed, e.g. delta~i_j; use metric g and g~i~j/g_i_j for metric components: " ++ w)
    kroneckerOccurrences _ w =
      fatal ("Kronecker delta takes two single marked indices, e.g. delta~i_j: " ++ w)

    derivativeOccurrences [p] _ = return [p]
    derivativeOccurrences _ w =
      fatal ("indexed derivative takes one marked index, e.g. d_i or d~i: " ++ w)

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
        (Just _, []) ->
          fatal ("indexed tensor field " ++ fdName fd
                 ++ " must be referenced with indices")
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
  ex <- expandTensorDefs m (sEx st)
  strictEinstein m lets (sIdx st) ex
  case (kindOf m (sNm st), sIdx st) of
    (Just (Vector staggered), [fi]) ->
      mapM (\a -> comp ex [(ixName fi, a)]
                         (if staggered then placeVB m a else zeroPlaceB m)
                         (base ++ show a)) (axisRange m)
    (Just SymM, [fi, fj]) ->
      mapM (\(a, b) -> comp ex [(ixName fi, a), (ixName fj, b)] (placeSB m a b) (base ++ show a ++ show b))
           (rank2Pairs (symComponentIndices (mDim m)))
    (Just AntiM, [fi, fj]) ->
      mapM (\(a, b) -> comp ex [(ixName fi, a), (ixName fj, b)] (placeSB m a b) (base ++ show a ++ show b))
           (rank2Pairs (antiComponentIndices (mDim m)))
    (Just (Tensor2 staggered), [fi, fj]) ->
      mapM (\(a, b) -> comp ex [(ixName fi, a), (ixName fj, b)]
                              (if staggered then placeSB m a b else zeroPlaceB m)
                              (base ++ show a ++ show b))
           (rank2Pairs (componentIndices (mDim m) (Tensor2 staggered)))
    _ -> fatal ("index equation has wrong indices for its field kind: " ++ sNm st)
  where
    base = "feq" ++ sNm st
    comp ex' env anchor defnm = do
      e <- ixExpand m lets env anchor ex'
      return ("def " ++ defnm ++ " := " ++ e)

type Placement = [Bool]

zeroPlaceB :: Model -> Placement
zeroPlaceB m = replicate (mDim m) False

placeVB :: Model -> Int -> Placement
placeVB m a = [c == a | c <- axisRange m]

placeSB :: Model -> Int -> Int -> Placement
placeSB m a b
  | a == b = zeroPlaceB m
  | otherwise = [c == a || c == b | c <- axisRange m]

togglePlace :: Int -> Placement -> Placement
togglePlace a =
  zipWith (\idx bit -> if idx == a then not bit else bit) [1 :: Int ..]

placeText :: Placement -> String
placeText = plOf

-- expand one component: parens are independent regions, a repeated
-- index letter is summed over the smallest term containing it, then
-- names and derivatives are resolved
ixExpand :: Model -> [String] -> [(String, Int)] -> Placement -> String -> IO String
ixExpand m lets env anchor expr = expandRegion env (itok expr)
  where
    euclideanDeclaredMetric =
      mMetricName m /= Nothing && mMetric m == Nothing && mEmbed m == Nothing

    metricIdent (base, parts) =
      case mMetricName m of
        Just metricNm | base == metricNm -> Just (metricNm, parts)
        _ -> Nothing

    isMixedPair (IxPart VUp _) (IxPart VDown _) = True
    isMixedPair (IxPart VDown _) (IxPart VUp _) = True
    isMixedPair _ _ = False

    indexedMetricPart (IxPart _ nm) = all isAlphaNum nm && not (null nm)

    metricRef (IxPart v1 _) (IxPart v2 _) a b
      | euclideanDeclaredMetric = if a == b then "1" else "0"
      | otherwise = metricInternalBase v1 v2 ++ "_" ++ show a ++ "_" ++ show b

    -- a region is a +/- separated list of terms
    expandRegion env' ts = goR env' (0 :: Int) [] ts
    goR env' _ cur [] = expandTerm env' (reverse cur)
    goR env' d cur (t@(IC c) : rest)
      | c `elem` "([" = goR env' (d + 1) (t : cur) rest
      | c `elem` ")]" = goR env' (d - 1) (t : cur) rest
      | d == 0 && c `elem` "+-" = do
          e1 <- expandTerm env' (reverse cur)
          e2 <- goR env' 0 [] rest
          return (joinAdd c e1 e2)
    goR env' d cur (t : rest) = goR env' d (t : cur) rest

    -- one term: explicit contraction is handled by contractWith or `.`;
    -- otherwise unresolved diagonal axes are an error.
    expandTerm env' ts =
      case parseWithSymbols ts of
        Just (names, body) -> expandWithSymbols env' names body
        Nothing ->
          case parseContractWith ts of
            Just (reducer, body) -> expandContract env' reducer body
            Nothing ->
              case dotProduct ts of
                Just body -> expandContract env' "+" body
                Nothing -> expandImplicit env' ts

    expandWithSymbols env' names body =
      let vals = map snd env'
          localEnv = zip names vals
          envNoShadow = [(k, v) | (k, v) <- env', k `notElem` names]
      in expandRegion (localEnv ++ envNoShadow) body

    expandImplicit env' ts =
      case levelDummies env' ts of
        (k:_) ->
          fatal ("index " ++ k ++ " is diagonal but not contracted; use contractWith or . in: " ++ expr)
        [] | zeroByIdentityTensor env' ts -> return "0"
           | otherwise -> resolve env' ts

    expandContract env' reducer body =
      let body' = stripOuterGroups body
      in case levelDummies env' body' of
        (k:_) -> do
          parts <- mapM (\n -> expandContract ((k, n) : env') reducer body') (axisRange m)
          return (foldReducerText reducer parts)
        [] | zeroByIdentityTensor env' body' -> return "0"
           | otherwise -> resolve env' body'

    parseContractWith ts =
      case dropWhile isSpaceI ts of
        II "contractWith" : rest ->
          case parseContractWithCall rest of
            Just (reducer, body, rest2)
              | all isSpaceI rest2 -> Just (reducer, body)
            _ ->
              case parseReducerWithRest (dropWhile isSpaceI rest) of
                Just (_, IC '(' : _) -> Nothing
                Just (reducer, body) -> Just (reducer, dropWhile isSpaceI body)
                Nothing -> Nothing
        _ -> Nothing

    isSpaceI (IC c) = isSpace c
    isSpaceI _ = False

    parseWithSymbols ts =
      case dropWhile isSpaceI ts of
        II "withSymbols" : rest -> do
          (names, body) <- parseSymbolList (dropWhile isSpaceI rest)
          Just (names, dropWhile isSpaceI body)
        _ -> Nothing

    parseSymbolList (IC '[' : rest) =
      let (inside, rest1) = breakSymbolList (0 :: Int) [] rest
      in Just (symbolNames inside, rest1)
    parseSymbolList _ = Nothing

    breakSymbolList _ acc [] = (reverse acc, [])
    breakSymbolList d acc (IC ']' : rest)
      | d == 0 = (reverse acc, rest)
      | otherwise = breakSymbolList (d - 1) (IC ']' : acc) rest
    breakSymbolList d acc (IC '[' : rest) =
      breakSymbolList (d + 1) (IC '[' : acc) rest
    breakSymbolList d acc (t : rest) = breakSymbolList d (t : acc) rest

    symbolNames = go
      where
        go [] = []
        go (II nm : rest) | validSurfaceName nm = nm : go rest
        go (_ : rest) = go rest

    parseContractWithCall rest = do
      (reducer, rest1) <- parseReducerWithRest (dropWhile isSpaceI rest)
      case dropWhile isSpaceI rest1 of
        IC '(' : bodyRest ->
          let (body, rest2) = matchParen (0 :: Int) [] bodyRest
          in Just (reducer, body, rest2)
        _ -> Nothing

    parseReducerWithRest (IC '(' : rest0) =
      case dropWhile isSpaceI rest0 of
        IC op : rest1 | op `elem` "+*" ->
          case dropWhile isSpaceI rest1 of
            IC ')' : rest2 -> Just ([op], rest2)
            _ -> Nothing
        _ -> Nothing
    parseReducerWithRest (II nm : rest)
      | validSurfaceName nm = Just (nm, rest)
    parseReducerWithRest _ = Nothing

    dotProduct ts =
      case splitTopDots ts of
        [_] -> Nothing
        parts -> Just (joinMulToks parts)

    splitTopDots ts = go (0 :: Int) [] ts
      where
        go _ acc [] = [trimIToks (reverse acc)]
        go d acc (t@(IC c) : rest)
          | c `elem` "([" = go (d + 1) (t : acc) rest
          | c `elem` ")]" = go (d - 1) (t : acc) rest
          | d == 0
          , c == '.'
          , leftSpace acc
          , rightSpace rest =
              trimIToks (reverse acc) : go d [] rest
        go d acc (t : rest) = go d (t : acc) rest

    leftSpace (IC c : _) = isSpace c
    leftSpace _ = False

    rightSpace (IC c : _) = isSpace c
    rightSpace _ = False

    joinMulToks [] = []
    joinMulToks [p] = p
    joinMulToks (p:ps) = p ++ [IC ' ', IC '*', IC ' '] ++ joinMulToks ps

    trimIToks = dropWhile isSpaceI . reverse . dropWhile isSpaceI . reverse . dropWhile isSpaceI

    stripOuterGroups ts =
      case dropWhile isSpaceI (reverse (dropWhile isSpaceI (reverse (dropWhile isSpaceI ts)))) of
        IC '(' : rest ->
          case closeGroup ')' rest [] of
            Just (inner, rest') | all isSpaceI rest' -> stripOuterGroups inner
            _ -> ts
        _ -> ts

    closeGroup close = goG (0 :: Int)
      where
        goG _ _ [] = Nothing
        goG d acc (IC c : rest)
          | c == close && d == 0 = Just (reverse acc, rest)
          | c == close = goG (d - 1) (IC c : acc) rest
          | (close == ')' && c == '(') || (close == ']' && c == '[') =
              goG (d + 1) (IC c : acc) rest
        goG d acc (t : rest) = goG d (t : acc) rest

    sumText parts =
      case filter (/= "0") (map dropOneFactor parts) of
        [] -> "0"
        [p] -> p
        ps -> "(" ++ intercalate " + " ps ++ ")"

    foldReducerText reducer parts =
      case reducer of
        "+" -> sumText parts
        "*" -> productText parts
        _ -> foldFunctionText reducer parts

    productText parts =
      case parts of
        [] -> "1"
        [p] -> p
        ps -> "(" ++ intercalate " * " ps ++ ")"

    foldFunctionText reducer parts =
      case parts of
        [] -> reducer ++ "()"
        [p] -> p
        p:ps -> foldl (\acc q -> reducer ++ "(" ++ acc ++ ", " ++ q ++ ")") p ps

    joinAdd op e1 e2
      | null (strip e1) = [op] ++ e2
      | op == '+' && isZeroText e1 = e2
      | op == '+' && isZeroText e2 = e1
      | op == '-' && isZeroText e2 = e1
      | otherwise = e1 ++ [op] ++ e2

    isZeroText s = strip s == "0"

    dropOneFactor s =
      case stripPrefix "1 * " s of
        Just rest -> rest
        Nothing -> s

    zeroByIdentityTensor env' = go (0 :: Int)
      where
        go _ [] = False
        go d (IC c : rest)
          | c `elem` "([" = go (d + 1) rest
          | c `elem` ")]" = go (d - 1) rest
          | otherwise = go d rest
        go 0 (II w : rest) = isZero w || go 0 rest
        go d (_ : rest) = go d rest

        resolvedDifferent p q =
          case (resolveIx env' (ixName p), resolveIx env' (ixName q)) of
            (Just pv, Just qv) -> pv /= qv
            _ -> False
        isZero w =
          case parseIndexedIdent w of
            ("delta", [p, q])
              | all isSingleAlphaIx [p, q], isMixedPair p q ->
                  resolvedDifferent p q
            (base, [p, q])
              | euclideanDeclaredMetric
              , Just _ <- metricIdent (base, [p, q])
              , indexedMetricPart p
              , indexedMetricPart q ->
                  resolvedDifferent p q
            _ -> False

    levelDummies env' ts = nub (go2 (0 :: Int) ts)
      where
        go2 _ [] = []
        go2 d (IC c : rest)
          | c `elem` "([" = go2 (d + 1) rest
          | c `elem` ")]" = go2 (d - 1) rest
          | otherwise = go2 d rest
        go2 0 (II "withSymbols" : rest) =
          case parseSymbolList (dropWhile isSpaceI rest) of
            Just (_, rest2) -> go2 0 rest2
            Nothing -> []
        go2 0 (II "contractWith" : rest) =
          case parseContractWithCall rest of
            Just (_, _, rest2) -> go2 0 rest2
            Nothing -> []
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
    resolve env' (II "contractWith" : rest) =
      case parseContractWithCall rest of
        Just (reducer, body, rest2) -> do
          e <- expandContract env' reducer body
          fmap (e ++) (resolve env' rest2)
        Nothing ->
          fatal ("contractWith needs a reducer and parenthesized body: " ++ expr)
    resolve env' (II "withSymbols" : rest) =
      case parseSymbolList (dropWhile isSpaceI rest) of
        Just (names, body) -> do
          e <- expandWithSymbols env' names body
          return e
        Nothing ->
          fatal ("withSymbols needs a bracketed symbol list: " ++ expr)
    resolve env' (II w : rest)
      -- Kronecker delta, one index per mark: delta~i_j / \948~i_j.
      -- Same-variance metric components are written with the declared metric
      -- name, for example g_i_j / g~i~j when `metric g` is present.
      | Just (_, [p, q]) <- metricIdent splitIdentW
      , indexedMetricPart p, indexedMetricPart q = do
          pv <- need env' (ixName p)
          qv <- need env' (ixName q)
          fmap ((metricRef p q pv qv) ++) (resolve env' rest)
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
            then fatal ("Kronecker delta indices must be mixed, e.g. delta~i_j; use metric g and g~i~j/g_i_j for metric components: " ++ w)
            else return ()
          pv <- need env' (ixName p)
          qv <- need env' (ixName q)
          fmap ((if pv == qv then "1" else "0") ++) (resolve env' rest)
      | ("delta", _ : _) <- splitIdentW =
          fatal ("Kronecker delta takes two single marked indices, e.g. delta~i_j: " ++ w)
      | ("epsilon", _ : _) <- splitIdentW =
          fatal ("epsilon takes three single marked indices, e.g. epsilon~i~j~k: " ++ w)
      | ("d", [k]) <- splitIdentW = do
          (ks, opw, rest2) <- derivativeOperand [k] rest
          ns <- mapM (need env' . ixName) ks
          ref <- fieldRef env' opw
          let (e, _) = deriveChain ns anchor ref
          fmap (e ++) (resolve env' rest2)
      | isField = do
          ref <- fieldRef env' w
          fmap (fst ref ++) (resolve env' rest)
      | Just (metricNm, _ : _) <- metricIdent splitIdentW =
          fatal ("metric tensor " ++ metricNm ++ " needs exactly two marked indices: " ++ w
                 ++ " (examples: " ++ metricNm ++ "~i~j, " ++ metricNm ++ "~i_j, "
                 ++ metricNm ++ "_i~j, " ++ metricNm ++ "_i_j)")
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
                  if staggered then placeVB m a else zeroPlaceB m)
        (Just (Form _), [a]) ->
          return (fname ++ replicate primes '\'' ++ "_" ++ show a,
                  zeroPlaceB m)
        (Just SymM, [a, b2]) ->
          let (lo, hi) = (min a b2, max a b2)
          in return (fname ++ replicate primes '\'' ++ "_" ++ show lo ++ "_" ++ show hi,
                     placeSB m a b2)
        (Just AntiM, [a, b2]) ->
          let (lo, hi) = (min a b2, max a b2)
              comp = fname ++ replicate primes '\'' ++ "_" ++ show lo ++ "_" ++ show hi
              signed | a == b2 = "0"
                     | a < b2 = comp
                     | otherwise = "(0 - " ++ comp ++ ")"
          in return (signed, placeSB m a b2)
        (Just (Tensor2 staggered), [a, b2]) ->
          return (fname ++ replicate primes '\'' ++ "_" ++ show a ++ "_" ++ show b2,
                  if staggered then placeSB m a b2 else zeroPlaceB m)
        (Just Scalar, []) ->
          return (fname ++ replicate primes '\'', zeroPlaceB m)
        (Nothing, [a]) | fname `elem` lets, primes == 0 ->
          return (fname ++ "_" ++ show a, zeroPlaceB m)
        _ -> fatal ("bad field reference in index equation: " ++ w)

    derivativeOperand ks rest =
      case dropWhile isSp rest of
        II w2 : rest2
          | ("d", [k2]) <- parseIndexedIdent w2 ->
              derivativeOperand (ks ++ [k2]) rest2
          | otherwise -> return (ks, w2, rest2)
        _ ->
          let label =
                case ks of
                  k0:_ -> "d_" ++ ixName k0
                  [] -> "indexed derivative"
          in fatal (label ++ " needs a field operand: " ++ expr)

    deriveChain [] _ _ = error "empty derivative chain"
    deriveChain [n1, n2] target ref@(_, src)
      | n1 == n2 && target == src =
          ("∂ 2 1 " ++ axisSymbol n1 ++ " " ++ operandExpr (fst ref), target)
    deriveChain [n] target ref =
      let e = derivAt n target ref
      in (e, target)
    deriveChain (n:ns) target ref =
      let innerTarget = naturalPlace ns (snd ref)
          innerRef = deriveChain ns innerTarget ref
          e = derivAt n target innerRef
      in (e, target)

    naturalPlace ns src = foldl (flip togglePlace) src ns

    derivAt n target (comp, place) =
      "dYee " ++ show n ++ " " ++ placeText target
      ++ " (" ++ comp ++ ", " ++ placeText place ++ ")"

    axisSymbol n =
      case drop (n - 1) (internalCoordNames m) of
        a:_ -> a
        [] -> "x"

    operandExpr e
      | all (\c -> isAlphaNum c || c == '_' || c == '\'') e = e
      | otherwise = "(" ++ e ++ ")"

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
    axmap = zip (mAxes m) (internalCoordNames m)
    out (TId nm pr)
      | not pr, Just (ordr, radius, ax) <- derivativeOpParts nm
      , Just axis <- lookup ax axmap =
          derivativeCall ordr radius axis
      | not pr, Just rest <- stripPrefix "pd2_" nm, Just axis <- lookup rest axmap =
          derivativeCall 2 1 axis
      | not pr, Just rest <- stripPrefix "pd_" nm, Just axis <- lookup rest axmap =
          derivativeCall 1 1 axis
      | otherwise = nm ++ (if pr then "'" else "")
    out (TC c) = [c]
    derivativeCall :: Int -> Int -> String -> String
    derivativeCall ordr radius axis =
      "∂ " ++ show ordr ++ " " ++ show radius ++ " " ++ axis

derivativeOpParts :: String -> Maybe (Int, Int, String)
derivativeOpParts nm = do
  rest0 <- stripPrefix "pd" nm
  let (mDigits, rest1) = span isDigit rest0
  if null mDigits then Nothing else do
    rest2 <- stripPrefix "r" rest1
    let (rDigits, rest3) = span isDigit rest2
    ax <- stripPrefix "_" rest3
    if null rDigits || null ax
      then Nothing
      else Just (read mDigits, read rDigits, ax)

invalidDerivativeOp :: Model -> String -> Maybe String
invalidDerivativeOp m nm =
  case derivativeOpParts nm of
    Nothing -> Nothing
    Just (ordr, radius, ax)
      | ax `notElem` mAxes m ->
          Just ("unknown coordinate derivative axis in " ++ nm)
      | ordr < 1 ->
          Just ("coordinate derivative order must be at least 1: " ++ nm)
      | radius < 1 ->
          Just ("coordinate derivative stencil radius must be at least 1: " ++ nm)
      | ordr >= 2 * radius + 1 ->
          Just ("coordinate derivative ∂" ++ show ordr ++ "," ++ show radius ++ ax
                ++ " has too few stencil points")
      | otherwise -> Nothing

-- shared step-expression preprocessing: rename axes, then resolve the
-- small coordinate derivative primitives.
stepPre :: Model -> String -> String
stepPre m = mathOps m . rewriteCompose . renameAxes m

isSpTok :: Tok -> Bool
isSpTok (TC c) = isSpace c
isSpTok _ = False

untok :: [Tok] -> String
untok = concatMap out
  where
    out (TId nm pr) = nm ++ (if pr then "'" else "")
    out (TC c) = [c]

rewriteCompose :: String -> String
rewriteCompose = untok . go . tokenize
  where
    go [] = []
    go (TId "compose" False : rest) =
      let (_, rest1) = span isSpTok rest
      in case rest1 of
           TId f fp : restF ->
             let (_, rest2) = span isSpTok restF
             in case rest2 of
                  TId g gp : restG ->
                    TC '(' : TId f fp : TC '.' : TId g gp : TC ')' : go restG
                  _ -> TId "compose" False : go rest
           _ -> TId "compose" False : go rest
    go (t : rest) = t : go rest

-- collect tokens up to the ')' closing an already-consumed '('
closeParenT :: Int -> [Tok] -> [Tok] -> Maybe ([Tok], [Tok])
closeParenT _ [] _ = Nothing
closeParenT n (TC '(' : ts) acc = closeParenT (n + 1) ts (TC '(' : acc)
closeParenT n (TC ')' : ts) acc
  | n == 1 = Just (reverse acc, ts)
  | otherwise = closeParenT (n - 1) ts (TC ')' : acc)
closeParenT n (t : ts) acc = closeParenT n ts (t : acc)

expandTensorDefs :: Model -> String -> IO String
expandTensorDefs m = go . itok
  where
    go [] = return ""
    go (II nm : rest)
      | Just td <- lookupTensorDef nm = do
          let (_, rest1) = span isSpaceI rest
          case rest1 of
            II argTok : rest2 -> do
              body <- instantiate td argTok
              body' <- expandTensorDefs m body
              tail' <- go rest2
              return ("(" ++ body' ++ ")" ++ tail')
            _ -> fatal ("tensor operator " ++ nm ++ " needs an indexed result argument")
      | otherwise = fmap (nm ++) (go rest)
    go (IC c : rest) = fmap (c :) (go rest)

    lookupTensorDef nm =
      case [td | td <- mTensorDefs m, tdName td == nm] of
        td:_ -> Just td
        [] -> Nothing

    instantiate td argTok = do
      let (argBase, callIx) = parseIndexedIdent argTok
          resultIx = tdResultIx td
      if null argBase
        then fatal ("bad argument to tensor operator " ++ tdName td ++ ": " ++ argTok)
        else return ()
      if length callIx /= length resultIx
        then fatal ("tensor operator " ++ tdName td ++ " expects result suffix "
                    ++ showIxParts resultIx ++ " but got " ++ argTok)
        else return ()
      mapM_ (uncurry sameVariance) (zip resultIx callIx)
      let env = zip (map ixName resultIx) callIx
      return (concatMap (substTok td argBase env) (itok (tdBody td)))

    sameVariance (IxPart v1 _) (IxPart v2 _)
      | v1 == v2 = return ()
      | otherwise = fatal "tensor operator result index variance mismatch"

    substTok _ _ _ (IC c) = [c]
    substTok td argBase env (II w) =
      let (base, parts) = parseIndexedIdent w
          (fname, primes) = fieldBaseOf base
          base' = if fname == tdParam td
                    then argBase ++ replicate primes '\''
                    else base
          parts' = map (substIx env) parts
      in base' ++ concatMap ixSuffix parts'

    substIx env (IxPart v nm) =
      case lookup nm env of
        Just (IxPart _ nm') -> IxPart v nm'
        Nothing -> IxPart v nm

    isSpaceI (IC c) = isSpace c
    isSpaceI _ = False

rewrite :: Model -> [String] -> Maybe String -> String -> IO String
rewrite m lets mk expr = do
  exprT <- expandTensorDefs m expr
  fmap concat (mapM render (attach (elems exprT)))
  where
    elems exprT = lbPass (opPass m lets (tokenize (stepPre m exprT)))
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
rewriteScalar m lets expr = do
  exprT <- expandTensorDefs m expr
  let pre = stepPre m exprT
  if hasIndexSyntax m pre
    then strictEinstein m lets [] pre
         >> ixExpand m lets [] (zeroPlaceB m) pre
    else rewrite m lets Nothing exprT

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
      needsIndexedDerivativeContext = any usesIndexedDerivative (modelExprTexts m)
      needsYeeContext = mtx /= Nothing || needsFormContext || needsStaggeredContext
                        || needsIndexedDerivativeContext
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
      usesIndexedDerivative s =
        any isIndexedDerivative (itok s)
      isIndexedDerivative (II w) =
        case parseIndexedIdent w of
          ("d", [_]) -> True
          _ -> False
      isIndexedDerivative _ = False
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
            , "def dTaylor (m: Integer) (ks: [MathValue]) (a: Integer) (u: MathValue) : MathValue :="
            , "  sum (map (\\(c, k) -> c * shift a k u) (zip (taylorStencil m ks) ks)) / (feHsteps_a ^ m)"
            ]
            ++ [ "def axisId (axis: MathValue) : Integer :="
               , "  match axis as mathValue with"
               , "    | symbol $v _ ->"
               , "        match v as string with"
               ]
            ++ [ "          | #\"" ++ c ++ "\" -> " ++ show a
               | (c, a) <- zip internalCoords axisIds ]
            ++ [ "          | _ -> 0"
               , "def ∂ (m: Integer) (r: Integer) (axis: MathValue) (u: MathValue) : MathValue :="
               , "  let a := axisId axis"
               , "   in if m = 1 && r = 1 then dC a u"
               , "      else if m = 2 && r = 1 then dC2 a u"
               , "      else dTaylor m (between (0 - r) r) a u"
               ]
      vectorContextDecls =
            dGradDecls
            ++ (if hasUse m "vector-calculus" "curl" then curlDecls else [])
            ++ (if hasUse m "vector-calculus" "divg" then divgDecls else [])
      dGradDecls =
            [ "def dGrad (X: Vector MathValue) : Matrix MathValue :="
            , "  generateTensor (\\[a, b] -> dC a X_b) [feDim, feDim]"
            ]
      curlDecls =
            [ "def curl (X: Vector MathValue) : Vector MathValue :="
            , "  withSymbols [i, j, k] (\949 3)~i~j~k . (dGrad X)_j_k"
            ]
      divgDecls =
            [ "def divg (X: Vector MathValue) : MathValue := trace (dGrad X)"
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
        | not (null (sIdx st)) ->
            let nm = sNm st
                names = egiStringList (componentStorageNamesOf m nm)
            in return (Just ("componentEqs " ++ names ++ " "
                             ++ egiMathList ["feq" ++ nm ++ show a
                                            | a <- axisRange m]))
        | kindOf m (sNm st) == Just (Vector False) ->
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
      exT <- expandTensorDefs m ex
      let pre = stepPre m exT
      strictEinstein m lets lhsIx pre
      case (kindOf m nm, lhsIx) of
        (Just (Vector staggered), [fi]) ->
          mapM (\a -> comp pre [a] [(ixName fi, a)]
                       (if staggered then placeVB m a else zeroPlaceB m))
               (axisRange m)
        (Just SymM, [fi, fj]) ->
          mapM (\(a, b) -> comp pre [a, b] [(ixName fi, a), (ixName fj, b)] (placeSB m a b))
               (rank2Pairs (symComponentIndices (mDim m)))
        (Just AntiM, [fi, fj]) ->
          mapM (\(a, b) -> comp pre [a, b] [(ixName fi, a), (ixName fj, b)] (placeSB m a b))
               (rank2Pairs (antiComponentIndices (mDim m)))
        (Just (Tensor2 staggered), [fi, fj]) ->
          mapM (\(a, b) -> comp pre [a, b] [(ixName fi, a), (ixName fj, b)]
                       (if staggered then placeSB m a b else zeroPlaceB m))
               (rank2Pairs (componentIndices (mDim m) (Tensor2 staggered)))
        _ -> fatal ("indexed CAS initializer has wrong indices for its field kind: " ++ nm)
      where
        kind = case kindOf m nm of
                 Just k -> k
                 Nothing -> Scalar
        comp pre' inds env anchor = do
          e <- ixExpand m lets env anchor pre'
          let lhs = componentStorageName m nm kind inds
          return ("fmrInit \"" ++ lhs ++ "\" (" ++ shiftTo anchor e ++ ")")
        shiftTo anchor e =
          "substitute (map (\\a -> (feCoords_a, feCoords_a + nth a "
          ++ placeText anchor ++ " * feHsteps_a)) feAxisIds) (" ++ e ++ ")"
    rawGridPoint = "[" ++ intercalate "," (internalIndexNames m) ++ "]"

-- Unicode input: Greek letters transliterate to their ASCII names.  A
-- partial-derivative sign followed by `order radius axis` is a coordinate
-- derivative: `∂ 2 1 x u`, `∂ 2 2 x u`.  The compact spelling `∂x` is
-- kept as the first-derivative shorthand.  A marked partial (`∂_i` or
-- `∂~i`) is the indexed derivative.  `∂_x` is therefore rejected when x is a
-- declared axis.  A bare partial sign still becomes d.  The small delta
-- becomes the codifferential, and the minus sign becomes '-'.
transliterate :: String -> String
transliterate = go
  where
    go [] = []
    go ('\8706':'_':cs) = "d_" ++ go cs
    go ('\8706':cs) =
      case coordDerivative cs of
        Just ((ordr, radius, ax), rest) ->
          "pd" ++ show ordr ++ "r" ++ show radius ++ "_"
          ++ concatMap tr ax ++ go rest
        Nothing | oldCompactDerivative cs ->
          "badPartialDerivative " ++ go cs
        Nothing -> "d" ++ go cs
    go (c:cs) = tr c ++ go cs

    coordDerivative cs =
      spacedDerivative cs `orElse` firstDerivativeShorthand cs

    firstDerivativeShorthand cs =
      case cs of
        c:_ | isAlpha c ->
          let (ax, rest) = span isW cs
          in Just ((1 :: Int, 1 :: Int, ax), rest)
        _ -> Nothing

    oldCompactDerivative cs =
      case dropWhile isSpace cs of
        c:_ -> isDigit c
        _ -> False

    spacedDerivative cs = do
      let r0 = dropWhile isSpace cs
      (mDigits, r1) <- digits r0
      let r2 = dropWhile isSpace r1
      (rDigits, r3) <- digits r2
      let r4 = dropWhile isSpace r3
      case r4 of
        a:_ | isAlpha a ->
          let (ax, rest) = span isW r4
          in Just ((read mDigits, read rDigits, ax), rest)
        _ -> Nothing

    digits s =
      let (ds, rest) = span isDigit s
      in if null ds then Nothing else Just (ds, rest)

    orElse (Just x) _ = Just x
    orElse Nothing y = y

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

main :: IO ()
main = do
  args <- getArgs
  case args of
    [path] -> do
      txt <- fmap transliterate (readFile path)
      let name = takeWhile (/= '.') (reverse (takeWhile (/= '/') (reverse path)))
      m <- parseFe name txt
      out <- emit m
      putStr out
    _ -> fatal "usage: fec model.fe > model.egi"
