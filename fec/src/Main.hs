-- fec -- the Formurae compiler.
--
-- Formurae (.fme) is the mathematical surface language of this repo,
-- named after Muranushi's Formura (its Latin-looking plural, and a pun
-- on "formulae").  fec translates it into the embedded DSL form: an
-- Egison program that carries its own coordinate context, mathematical
-- operators, and .fmr printer, while using lib/fmrgen.egi only for
-- small coordinate-free helpers.  Tensor index notation, differential
-- forms, CAS expansion, and printing are still expressed as generated
-- Egison code; this is a thin, line-oriented translator.  Base library
-- only; build and run with
--
--   cabal run -v0 fec -- model.fme > model.egi
--   egison -l lib/fmrgen.egi model.egi > model.fmr
--
-- Formurae grammar (v1):
--   mode collocated|dec             REQUIRED; spatial discretization and standard prelude
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
-- phi, ...); coordinate derivatives are written as ∂_axis expr or
-- ∂^order_axis expr in Formurae (with apostrophes after ∂ increasing the
-- stencil radius) and lower to the generated Egison operator
-- ∂ order radius axis expr.  The indexed derivative ∂_i remains distinct
-- when i is not a declared axis.  A bare small delta is the
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
-- X' in a RHS refers to the updated field (Formura's primed array), so
-- B' = B - dt * curl E' is the symplectic pair.

import Data.Char (isAlpha, isAlphaNum, isDigit, isSpace)
import Data.List (dropWhileEnd, intercalate, permutations, sort, nub, stripPrefix)
import System.Environment (getArgs)
import System.IO (hPutStrLn, stderr)

import Formurae.Common
import Formurae.Index
import Formurae.Syntax
import Formurae.TensorExpr
  ( expandDefs
  , expandTensorDefs
  , ixExpand
  , placeSB
  , placeText
  , placeVB
  , preprocessTensorExpr
  , strictEinstein
  , validateFieldRefParts
  , zeroPlaceB
  )

formOps, deltaOps :: [String]
formOps = ["d", "dForm", "delta", "codiff", "\948", "hodge"]
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

standardDefs :: Model -> [Def]
standardDefs m =
  [ Def "." ["A", "B"] "contractWith (+) (A * B)"
  ]
  ++ modeStandardDefs m

modeStandardDefs :: Model -> [Def]
modeStandardDefs m =
  case selectedMode m of
    CollocatedMode -> collocatedPreludeDefs
    DecMode -> []

-- These are ordinary TensorExpr definitions rather than special lowering
-- cases.  In particular curl and divg are expressed only with indexed
-- derivatives, context tensors, withSymbols, and explicit contraction.
collocatedPreludeDefs :: [Def]
collocatedPreludeDefs =
  [ Def "grad" ["u"] "withSymbols [i] (∂_i u)"
  , Def "dGrad" ["X"] "withSymbols [i, j] (∂_i X_j)"
  , Def "divg" ["X"]
      ("withSymbols [i, j] (" ++ metricPreludeName ++ "~i~j . ∂_i X_j)")
  , Def "curl" ["X"]
      "withSymbols [i, j, k] (epsilon_i~j~k . ∂_j X_k)"
  , Def "lap" ["u"]
      ("withSymbols [i, j] (" ++ metricPreludeName ++ "~i~j . ∂_i ∂_j u)")
  , Def "Δ" ["u"] "lap u"
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

validateDimensionFeatures :: Model -> IO ()
validateDimensionFeatures m
  | selectedMode m == CollocatedMode
  , any isFormField (mFlds m) =
      fatal "differential-form fields require mode dec"
  | selectedMode m == CollocatedMode
  , mDd m /= Nothing =
      fatal "assert-dd-zero requires mode dec"
  | any isAntiField (mFlds m) && mDim m < 2 =
      fatal "antisymmetric rank-2 fields require dimension at least 2"
  | Just k <- firstBadFormDegree =
      fatal (show k ++ "-form fields require dimension at least " ++ show k)
  | otherwise = return ()
  where
    isAntiField (_, AntiM) = True
    isAntiField _ = False
    isFormField (_, Form _) = True
    isFormField _ = False
    firstBadFormDegree =
      case [k | (_, Form k) <- mFlds m, k < 0 || k > mDim m] of
        k:_ -> Just k
        [] -> Nothing

unavailableOperator :: Model -> String -> Maybe String
unavailableOperator m s = go (tokenize s)
  where
    userDefined nm =
      any ((== nm) . defName) (mDefs m)
      || any ((== nm) . tdName) (mTensorDefs m)
    go [] = Nothing
    go (t:ts) = check t ts `orElse` go ts
    check (TId "d" _) rest
      | indexedAfter rest = Nothing
      | userDefined "d" = Nothing
      | selectedMode m /= DecMode =
      Just "exterior derivative d requires mode dec"
    check (TId "delta" _) rest
      | indexedAfter rest = Nothing
      | userDefined "delta" = Nothing
      | selectedMode m /= DecMode =
      Just "δ requires mode dec"
    check (TId "codiff" _) _
      | not (userDefined "codiff") && selectedMode m /= DecMode =
      Just "codiff requires mode dec"
    check (TId "dForm" _) _
      | not (userDefined "dForm") && selectedMode m /= DecMode =
      Just "dForm requires mode dec"
    check (TId "hodge" _) _
      | not (userDefined "hodge") && selectedMode m /= DecMode =
      Just "hodge requires mode dec"
    check (TId "curl" _) _
      | not (userDefined "curl") && selectedMode m /= CollocatedMode =
      Just "vector curl is currently available only in mode collocated"
      | not (userDefined "curl") && mDim m /= 3 =
      Just "curl requires dimension 3"
    check (TId "divg" _) _
      | not (userDefined "divg") && selectedMode m /= CollocatedMode =
      Just "vector divg is currently available only in mode collocated"
    check (TId "dGrad" _) _
      | not (userDefined "dGrad") && selectedMode m /= CollocatedMode =
      Just "dGrad is currently available only in mode collocated"
    check (TId "grad" _) _
      | not (userDefined "grad") && selectedMode m /= CollocatedMode =
      Just "vector grad is currently available only in mode collocated"
    check (TId "lap" _) _
      | not (userDefined "lap") && selectedMode m /= CollocatedMode =
      Just "lap is currently available only in mode collocated"
    check (TId "\916" _) _
      | not (userDefined "\916") && selectedMode m /= CollocatedMode =
      Just "Δ is currently available only in mode collocated"
    check (TId "flat" _) _ | not (userDefined "flat") =
      Just "flat is not implemented yet; discrete vector/form conversion needs an explicit reconstruction policy"
    check (TId "sharp" _) _ | not (userDefined "sharp") =
      Just "sharp is not implemented yet; discrete vector/form conversion needs an explicit reconstruction policy"
    check _ _ = Nothing
    indexedAfter rest =
      case dropWhile isSpTok rest of
        TC '~' : _ -> True
        TC '_' : _ -> True
        _ -> False
    orElse (Just x) _ = Just x
    orElse Nothing y = y

parseFe :: String -> String -> IO Model
parseFe name txt = go STop initialModel
                      (zip [1 :: Int ..] (lines txt))
  where
    initialModel = Model
      { mName = name
      , mDim = 0
      , mAxes = []
      , mMode = Nothing
      , mMetricName = Nothing
      , mParams = []
      , mHelp = []
      , mFlds = []
      , mFieldDecls = []
      , mInits = []
      , mSteps = []
      , mDd = Nothing
      , mMetric = Nothing
      , mEmbed = Nothing
      , mTensorDefs = []
      , mDefs = []
      }
    -- dimension and axes are required: they fix the coordinate frame
    -- that gives the operators their meaning (which axis ∂_theta is,
    -- what an index letter in ∂_j ranges over)
    go _ m []
      | mDim m == 0 = fatal "dimension declaration is required (dimension 1, 2, or 3)"
      | null (mAxes m) = fatal "axes declaration is required (e.g. axes x, y, z)"
      | length (mAxes m) /= mDim m =
          fatal ("axes declares " ++ show (length (mAxes m))
                 ++ " names for dimension " ++ show (mDim m))
      | mMode m == Nothing = fatal "mode declaration is required (mode collocated or mode dec)"
      | otherwise = do
          let mUse = m
          validateMetricName mUse
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
          -- Prelude operators are ordinary defs; a user definition later in
          -- the file shadows the prelude name.
          defs <- resolveDefs mUse (standardDefs mUse ++ reverse (mDefs mUse))
          tensorDefs <- resolveTensorDefs mUse defs (reverse (mTensorDefs mUse))
          let mDef = mUse { mDefs = defs, mTensorDefs = tensorDefs }
          steps' <- mapM (\st -> do ex0 <- preprocessTensorExpr mUse (sEx st)
                                    ex <- expandDefs defs ex0
                                    return st { sEx = ex })
                         (reverse (mSteps mUse))
          inits' <- mapM (expandInit mUse defs) (reverse (mInits mUse))
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

    resolveDefs mUse ds = goD [] ds
      where
        -- earlier defs are expanded into the body, so a resolved body
        -- may contain no def name at all: any survivor is a self or
        -- forward reference
        allNames = map defName ds
        goD acc [] = return acc
        goD acc (df : more) = do
          body0 <- preprocessTensorExpr mUse (defBody df)
          body' <- expandDefs acc body0
          case [w | TId w _ <- tokenize body', w `elem` allNames] of
            (w:_) -> fatal ("def " ++ defName df ++ " uses " ++ w
                            ++ " which is not defined before it")
            [] -> goD (df { defBody = body' } : acc) more

    resolveTensorDefs mUse defs = mapM resolveOne
      where
        resolveOne td = do
          body0 <- preprocessTensorExpr mUse (tdBody td)
          body' <- expandDefs defs body0
          return td { tdBody = body' }

    expandInit mUse defs it = case it of
      ICas nm ex -> do ex0 <- preprocessTensorExpr mUse ex
                       ex' <- expandDefs defs ex0
                       return (ICas nm ex')
      ICasIndex nm ix ex -> do ex0 <- preprocessTensorExpr mUse ex
                               ex' <- expandDefs defs ex0
                               return (ICasIndex nm ix ex')
      _ -> return it

    checkUserSurface m' locals context body =
      case surfaceBanned m' locals body of
        Just bad -> fatal (bad ++ " " ++ context)
        Nothing ->
          case unavailableOperator m' body of
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
      | Just r <- stripPrefix "mode " s =
          case strip r of
            "collocated" -> setMode CollocatedMode
            "dec" -> setMode DecMode
            bad -> fatal ("unknown mode " ++ bad ++ " (line " ++ show ln
                          ++ "); expected mode collocated or mode dec")
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
        setMode mode =
          case mMode m of
            Nothing -> return m { mMode = Just mode }
            Just _ -> fatal ("mode may be declared only once (line " ++ show ln ++ ")")
        addField fd =
          return m { mFlds = (fdName fd, kindFromFieldDecl fd) : mFlds m
                   , mFieldDecls = fd : mFieldDecls m }
        dim r | all isDigit (strip r), n <- read (strip r) =
                  if n < (1 :: Int) || n > 3
                    then fatal ("Formurae currently supports dimension 1, 2, or 3 (got "
                                ++ show n ++ ")")
                    else return m { mDim = n }
              | otherwise = fatal ("bad dimension (line " ++ show ln ++ ")")
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
          Just "coordinate derivative must be written with subscript notation, e.g. ∂_x u, ∂^2_x u, or ∂'^2_x u"
      | ("delta" : ps) <- splitOn '_' nm, any ((> 1) . length) ps =
          Just ("Kronecker delta takes one index per mark (delta~i_j): " ++ nm)
    checkTok _ = Nothing
    checkIndexTok (II nm) =
      case parseIndexedIdent nm of
        ("delta", parts@(_:_))
          | not (length parts == 2 && all isAlphaNumIx parts) ->
              Just ("Kronecker delta takes two marked indices, e.g. delta~i_j or delta_i~1: " ++ nm)
        ("epsilon", parts@(_:_))
          | not (length parts == 3 && all isSingleAlphaIx parts) ->
              Just ("epsilon takes three single marked indices, e.g. epsilon~i~j~k: " ++ nm)
        _ -> Nothing
    checkIndexTok _ = Nothing
    isAlphaNumIx (IxPart _ ix) = not (null ix) && all isAlphaNum ix
    orElse (Just x) _ = Just x
    orElse Nothing y = y

-- the field to which lb is applied, if any (scans the same
-- preprocessed form the rewriter uses, so a user-defined Δ can expand
-- to lb u before this pass)
lbTarget :: Model -> Maybe String
lbTarget m = case concatMap scan (mSteps m) of
               (nm:_) -> Just nm
               [] -> Nothing
  where
    scan st = go (tokenize (sEx st))
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
indexDefs :: Model -> [String] -> Step -> IO [String]
indexDefs m lets st = do
  validateFieldRefParts m lets (sNm st ++ concatMap ixSuffix (sIdx st))
  ex0 <- expandTensorDefs m (sEx st)
  ex <- preprocessTensorExpr m ex0
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

implicitVectorDefs :: Model -> [String] -> Step -> IO [String]
implicitVectorDefs m lets st = do
  ex0 <- expandTensorDefs m (sEx st)
  ex <- preprocessTensorExpr m ex0
  if hasIndexSyntax m ex
    then do
      strictEinstein m lets [lhsIx] ex
      mapM (comp ex) (axisRange m)
    else do
      mapM scalarComp (axisRange m)
  where
    lhsIx = IxPart VDown "i"
    anchor = zeroPlaceB m
    comp ex' a = do
      e <- ixExpand m lets [(ixName lhsIx, a)] anchor ex'
      return ("def feq" ++ sNm st ++ show a ++ " := " ++ e)
    scalarComp a = do
      e <- rewrite m lets (Just (show a)) (sEx st)
      return ("def feq" ++ sNm st ++ show a ++ " := " ++ e)

-- names X whose updated value X' is referenced in some step RHS
primedRefs :: Model -> [String]
primedRefs m = sort (nub [nm | st <- mSteps m, TId nm True <- tokenize (sEx st)
                             , kindOf m nm /= Nothing])

opPass :: Model -> [Tok] -> [Elem]
opPass m = go
  where
    forms = [(n, d) | (n, Form d) <- mFlds m]
    go [] = []
    go input@(TId op False : _)
      | op `elem` formOps
      , Just (formValue, rest) <- parseFormValue input =
          EMarkL ("formComps (" ++ formValue ++ ")") : go rest
    go (t : ts) = toElem t : go ts

    parseFormValue (TId nm pr : rest)
      | Just _ <- lookup nm forms =
          Just (nm ++ (if pr then "fN" else "f"), rest)
    parseFormValue (TId op False : rest)
      | op `elem` formOps
      , (_ : _, operand) <- span isSpaceTok rest
      , Just (value, remaining) <- parseFormValue operand =
          Just (formFunction op ++ " " ++ parenthesizeFormValue value, remaining)
      | op `elem` formOps = Nothing
    parseFormValue (TC '(' : rest) = do
      (inside, remaining) <- closeParenT 1 rest []
      (value, insideRest) <- parseFormValue (dropWhile isSpaceTok inside)
      if all isSpaceTok insideRest
        then Just (value, remaining)
        else Nothing
    parseFormValue _ = Nothing

    formFunction op
      | op `elem` deltaOps = "codiff"
      | op == "hodge" = "hodge"
      | otherwise = "dForm"
    parenthesizeFormValue value
      | all isAlphaNum value = value
      | otherwise = "(" ++ value ++ ")"
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

invalidDerivativeOp :: Model -> String -> Maybe String
invalidDerivativeOp _ nm =
  case derivativeOpParts nm of
    Nothing -> Nothing
    Just (ordr, radius, part)
      | ordr < 1 ->
          Just ("coordinate derivative order must be at least 1: " ++ nm)
      | radius < 1 ->
          Just ("coordinate derivative stencil radius must be at least 1: " ++ nm)
      | ordr >= 2 * radius + 1 ->
          Just ("coordinate derivative ∂" ++ show ordr ++ "," ++ show radius ++ ixName part
                ++ " has too few stencil points")
      | otherwise -> Nothing

rewrite :: Model -> [String] -> Maybe String -> String -> IO String
rewrite m lets mk expr = do
  exprT0 <- expandTensorDefs m expr
  exprT <- preprocessTensorExpr m exprT0
  fmap concat (mapM render (attach (elems exprT)))
  where
    elems exprT = lbPass (opPass m (tokenize exprT))
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
  pre <- preprocessTensorExpr m exprT
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
      take 2 nm == "d_"
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
      needsFormContext = selectedMode m == DecMode
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
            case (mMetricName m, mMetric m, mEmbed m) of
              (Nothing, Nothing, Nothing) -> []
              _ ->
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
            ++ ".fme -- edit the .fme, not this file"
        , "-- mode " ++ modeSurfaceName (selectedMode m)
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
            implicitVectorDefs m lets st
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
                             ++ egiMathList ["feq" ++ nm ++ show a
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
      pre <- preprocessTensorExpr m exT
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
-- decorated partial-derivative sign is a coordinate derivative:
-- `∂_x u`, `∂^2_x u`, `∂'^2_x u`.  A plain marked partial (`∂_i` or
-- `∂~i`) remains the indexed derivative when the mark is not a declared
-- axis.  A bare partial sign still becomes d.  The small delta becomes the
-- codifferential, and the minus sign becomes '-'.
transliterate :: String -> String
transliterate = go
  where
    go [] = []
    go ('\8706':cs) =
      case coordDerivative cs of
        Just ((ordr, radius, part), rest) ->
          "pd" ++ show ordr ++ "r" ++ show radius
          ++ renderDerivativePart part ++ go rest
        Nothing | oldCompactDerivative cs ->
          "badPartialDerivative " ++ go cs
        Nothing ->
          case cs of
            '_':rest -> "d_" ++ go rest
            '~':rest -> "d~" ++ go rest
            _ -> "d" ++ go cs
    go (c:cs) = tr c ++ go cs

    coordDerivative cs =
      decoratedDerivative cs

    oldCompactDerivative cs =
      case cs of
        c:_ | isAlpha c || c == '^' || c == '\'' -> True
        _ ->
          case dropWhile isSpace cs of
            c:_ -> isDigit c
            _ -> False

    decoratedDerivative cs = do
      let (quotes, r0) = span (== '\'') cs
          radius = length quotes + 1
      (ordr, r1, hasOrder) <- orderPart r0
      if null quotes && not hasOrder then Nothing else do
        (part, rest) <- markedDerivativeAxis r1
        Just ((ordr, radius, part), rest)

    orderPart ('^':rest) = do
      (ds, rest') <- digits rest
      Just (read ds, rest', True)
    orderPart rest = Just (1 :: Int, rest, False)

    markedDerivativeAxis ('_':rest) = markedAxis VDown rest
    markedDerivativeAxis ('~':rest) = markedAxis VUp rest
    markedDerivativeAxis _ = Nothing

    markedAxis variance rest =
      case rest of
        c:_ | isAlpha c ->
          let (ax, rest') = span isW rest
          in Just (IxPart variance ax, rest')
        _ -> Nothing

    renderDerivativePart (IxPart variance nm) =
      (case variance of
         VUp -> "~"
         VDown -> "_")
      ++ concatMap tr nm

    digits s =
      let (ds, rest) = span isDigit s
      in if null ds then Nothing else Just (ds, rest)

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
    _ -> fatal "usage: fec model.fme > model.egi"
