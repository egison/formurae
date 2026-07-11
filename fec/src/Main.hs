{-# LANGUAGE PatternSynonyms #-}

-- fec -- the Formurae compiler.
--
-- Formurae (.fme) is the mathematical surface language of this repo,
-- named after Muranushi's Formura (its Latin-looking plural, and a pun
-- on "formulae").  fec translates it into the embedded DSL form: an
-- Egison program that carries its own coordinate context and residual
-- mathematical expressions.  Shared tensor semantics, coordinate-free CAS
-- helpers, and the Formura printer live in small Egison libraries; model
-- specific names and expressions remain in the generated file.  Base library
-- only; build and run with
--
--   cabal run -v0 fec -- model.fme > model.egi
--   egison -l lib/formurae-tensor.egi -l lib/fmrgen.egi \
--          -l lib/formurae-runtime.egi model.egi > model.fmr
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
--                                   (`(2 + cos theta)); Egison's
--                                   quote-transparent substitution keeps
--                                   them compact at half-cell placements.
--                                   Enables lb (Laplace-Beltrami): the
--                                   hodge factors sqrt(g)/h_a^2 become
--                                   coefficient FIELDS evaluated by the
--                                   CAS at the half-cell placements.
--   def NAME ARG... = EXPR          user-defined operator.  Its tensor
--                                    semantics are expanded on the TensorExpr
--                                    AST; use
--                                    withSymbols for newly introduced free
--                                    indices and contractWith / `.` for
--                                    contraction.  Tensor primitives left
--                                    after component specialization are
--                                    evaluated by Egison.
--                                    Fixed indexed parameters such as A_i_j and
--                                    the rank-polymorphic marker X... are also
--                                    accepted.
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
-- operators such as Δ use ordinary prelude definitions over these derivative
-- primitives and may be shadowed by user definitions; Δ4 is user-defined.
-- In index equations superscripts (~i) and subscripts (_i) are kept
-- distinct.  Kronecker's delta is the mixed identity (delta~i_j, or with
-- the small delta sign), while the metric tensor name declared by
-- `metric NAME` lowers to generated tensors according to variance:
-- NAME~i~j, NAME~i_j, NAME_i~j, NAME_i_j.  The fused delta_ij is rejected.
--
-- X' in a RHS refers to the updated field (Formura's primed array), so
-- B' = B - dt * curl E' is the symplectic pair.

import Data.Char (isAlpha, isAlphaNum, isDigit, isSpace)
import Data.List (dropWhileEnd, intercalate, sort, nub, stripPrefix, isInfixOf, isPrefixOf, isSuffixOf)
import System.Environment (getArgs)
import System.IO (hPutStrLn, stderr)

import Formurae.BackendPlan
import Formurae.Common
import Formurae.Index
import Formurae.Syntax
import Formurae.TensorExpr
  ( TensorExpr
  , pattern TEIdent
  , pattern TEApply
  , pattern TEUnary
  , pattern TEBinary
  , pattern TEGroup
  , expandDefs
  , ixExpand
  , ixExpandInitializer
  , parseTensorExprEither
  , preprocessTensorExpr
  , renderTensorExpr
  , strictEinstein
  , validateFieldRefParts
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

-- Tensor algebra is an Egison concern.  The generated .egi loads
-- lib/formurae-tensor.egi, which defines the algebraic operators in terms of
-- Egison's Tensor primitives.  Coordinate operators, on the other hand, are
-- ordinary Formurae definitions: registering them before user definitions
-- lets the normal TensorExpr expansion specialize them to the model's axes
-- and placements.  A user definition is subsequently pushed in front of
-- these definitions and therefore shadows the corresponding prelude entry.
standardNames :: [String]
standardNames =
  [ ".", "wedge", "trace", "sym", "antisym"
  , "norm2", "hessian", "grad", "dGrad", "divg", "curl", "lap", "Δ"
  ]

-- A bare generated binding must not reuse an Egison keyword or an
-- unqualified helper referenced by the generated program.  Indexed bindings
-- used to avoid some of these collisions accidentally; bare tensors make the
-- value namespace explicit, so reject them at the Formurae boundary.
egisonReservedWords :: [String]
egisonReservedWords =
  [ "True", "False", "loadFile", "load", "def", "declare", "if", "then"
  , "else", "seq", "capply", "memoizedLambda", "cambda", "let", "in"
  , "where", "withSymbols", "loop", "forall", "match", "matchDFS"
  , "matchAll", "matchAllDFS", "as", "with", "matcher", "do", "something"
  , "undefined", "algebraicDataMatcher", "generateTensor", "tensor"
  , "contract", "tensorMap", "tensorMap2", "transpose", "flipIndices"
  , "subrefs", "subrefs!", "suprefs", "suprefs!", "userRefs", "userRefs!"
  , "function", "infixl", "infixr", "infix", "simplify", "using"
  ]

generatedEgisonDependencies :: [String]
generatedEgisonDependencies =
  [ "FMR", "print", "substitute", "taylorStencil", "between", "nth", "zip"
  , "filter", "any", "head", "length", "foldl", "map", "sum", "product"
  , "sqrt", "contractWith"
  ]

coordinatePreludeDefs :: Model -> [Def]
coordinatePreludeDefs m =
  [ Def "grad" ["u"] "withSymbols [i] ∂_i u"
  , Def "dGrad" ["X"] "withSymbols [i, j] ∂_i X_j"
  , Def "divg" ["X"] "contractWith (+) (∂_i X~i)"
  ]
  ++ [ Def "curl" ["X"]
         "withSymbols [i, j, k] (epsilon_i~j~k . ∂_j X_k)"
     | mDim m == 3
     ]
  ++ [ Def "lap" ["u"] "divg (grad u)"
     , Def "Δ" ["u"] "lap u"
     , Def "hessian" ["u"] "withSymbols [i, j] ∂_i ∂_j u"
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
  , required nm
  ]
  where
    declared = declaredExterns helps
    required nm =
      any (usesFunctionName nm) (modelExprTexts m)
      || nm `elem` embeddingDerivativeDependencies
    embeddingDerivativeDependencies =
      concat
        [ deps
        | (fn, deps) <- [("sin", ["cos"]), ("cos", ["sin"])]
        , any (usesFunctionName fn) (maybe [] id (mEmbed m))
        ]

modelExprTexts :: Model -> [String]
modelExprTexts m =
  map snd (mParams m)
  ++ helperExprs (mHelp m)
  ++ concatMap initExpr (mInits m)
  ++ map sEx (mSteps m)
  ++ maybe [] id (mMetric m)
  ++ maybe [] id (mEmbed m)
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

validateValueBindingNames :: Model -> IO ()
validateValueBindingNames m =
  case duplicateBindings of
    [] -> checkGeneratedConflicts
    (name, kinds) : _ ->
      fatal ("value name '" ++ name ++ "' is declared more than once as "
             ++ intercalate "/" kinds)
  where
    bindings =
      [("param", nm) | (nm, _) <- mParams m]
      ++ [("field", nm) | (nm, _) <- mFlds m]
      ++ [("let", sNm st) | st <- mSteps m, sk st == KLet]
      ++ [("local", sNm st) | st <- mSteps m, sk st == KLocal]
    duplicateBindings =
      [(name, map fst matches)
      | name <- nub (map snd bindings)
      , let matches = filter ((== name) . snd) bindings
      , length matches > 1]
    checkGeneratedConflicts =
      case [(kind, name) | (kind, name) <- bindings, isGeneratedValueName name] of
        [] -> return ()
        (kind, name) : _ ->
          fatal ("value name '" ++ name
                 ++ "' is reserved for generated Egison code (" ++ kind ++ ")")
    isGeneratedValueName name =
      name `elem` generatedValueNames || "feq" `isPrefixOf` name
    generatedValueNames =
      internalCoordNames m
      ++ internalHstepNames m
      ++ [ "feDim", "feAxes", "feAxisIds", "feCoords", "feHsteps"
         , "shift", "dC", "dC2", "dTaylor", "axisId", "∂"
         , "yeeRef", "unit3", "dYee"
         , "feFormDerivative"
         , "feLbGradient", "feLbDivergence", "feLbCoefficient", "feLbFlux"
         , "feLbCellPlacement", "feLbFluxPlacement"
         , "feLbStoredFlux", lbResultBindingName
         , "hodge", "dForm", "codiff"
         , "feSymbolNames", "feFieldNames", "feFieldPolicies", "feIndexNames", "fePrinterContext"
         , "fmrEq", "fmrInit", "componentEqs", "tensorEqs", "formEqs", "scalarEq"
         , "feX", "feG", "feH", "feSqrtG", "feDD"
         , "feParams", "feHelpers", "feComps", "feInits", "feSteps", "main"
         , "ca", "cb", "cc", "sg", "f1", "f2", "f3"
         ]
      ++ concat [[name ++ "f", name ++ "fN"]
                | (name, Form _) <- mFlds m]
      ++ standardNames
      ++ scalarIntrinsics
      ++ egisonReservedWords
      ++ generatedEgisonDependencies

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
          case words k of
            "scalar" : attrs -> do
              policy <- parsePolicyAttrs Collocated attrs
              return (FieldDecl nm Nothing ScalarLayout policy Scalar)
            "vector" : attrs -> do
              policy <- parsePolicyAttrs Collocated attrs
              return (FieldDecl nm Nothing Rank1Layout policy Vector)
            "symmetric" : attrs -> do
              policy <- parsePolicyAttrs Collocated attrs
              return (FieldDecl nm Nothing SymRank2Layout policy SymM)
            form : attrs | Just deg <- formKind form -> do
              policy <- parsePolicyAttrs Primal attrs
              return (FieldDecl nm Nothing Rank1Layout policy (Form deg))
            _ -> fatal ("bad field kind: " ++ k ++ " (line " ++ show ln ++ ")")
    indexed =
      case words (strip r) of
        [spec] -> fromSpec spec Collocated
        [spec, "@", policyName] -> parsePolicy policyName >>= fromSpec spec
        _ -> fatal ("bad field decl: field " ++ r ++ " (line " ++ show ln ++ ")")
    fromSpec spec policy =
      case parseFieldSpec spec of
        Nothing -> fatal ("bad field spec: " ++ spec ++ " (line " ++ show ln ++ ")")
        Just (nm, mix) -> do
          rejectReservedName ln nm
          layout <- inferFieldLayout ln spec mix
          return (FieldDecl nm mix layout policy (kindFor layout))

    kindFor ScalarLayout = Scalar
    kindFor Rank1Layout = Vector
    kindFor SymRank2Layout = SymM
    kindFor AntiRank2Layout = AntiM
    kindFor FullRank2Layout = Tensor2
    parsePolicyAttrs defaultPolicy [] = return defaultPolicy
    parsePolicyAttrs _ ["@", policyName] = parsePolicy policyName
    parsePolicyAttrs _ _ = fatal ("bad field policy syntax in: " ++ r ++ " (line " ++ show ln ++ ")")
    parsePolicy "collocated" = return Collocated
    parsePolicy "primal" = return Primal
    parsePolicy "dual" = return Dual
    parsePolicy policyName =
      fatal ("bad grid policy '" ++ policyName ++ "' (expected collocated, primal, or dual) (line "
             ++ show ln ++ ")")
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
      if all validParam ps && length (map defParamBase ps) == length (nub (map defParamBase ps))
        then Just ps
        else Nothing
    validParam p =
      let stem = stripPatternEllipsis p
          (base, parts) = parseIndexedIdent stem
      in validSurfaceName base
         && (isPatternEllipsis p || all validPatternPart parts)
    validPatternPart (IxPart _ nm) = not (null nm) && all isAlphaNum nm

defParamBase :: String -> String
defParamBase p = fst (parseIndexedIdent (stripPatternEllipsis p))

stripPatternEllipsis :: String -> String
stripPatternEllipsis p
  | "..." `isSuffixOf` p = take (length p - 3) p
  | otherwise = p

isPatternEllipsis :: String -> Bool
isPatternEllipsis = ("..." `isSuffixOf`)

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
          validateValueBindingNames mUse
          validateMetricName mUse
          validateDimensionFeatures mUse
          mapM_ (\df ->
                    checkUserSurface mUse (map defParamBase (defParams df))
                      ("in def " ++ defName df) (defBody df))
                (mDefs mUse)
          mapM_ (\st ->
                    checkUserSurface mUse []
                      ("in step expression: " ++ sEx st) (sEx st))
                (mSteps mUse)
          mapM_ (checkInitUse mUse) (mInits mUse)
          -- Resolve the coordinate prelude first, then push user definitions
          -- in source order.  lookupDef chooses the first match, so user
          -- definitions shadow prelude definitions while retaining the same
          -- definition-order rule among themselves.
          preludeDefs <- resolveDefs mUse [] (coordinatePreludeDefs mUse)
          let userDefs0 = reverse (mDefs mUse)
          allDefs <- resolveDefs mUse preludeDefs userDefs0
          let defs = take (length userDefs0) allDefs
          let mDef = mUse { mDefs = defs }
          steps' <- mapM (\st -> do ex0 <- preprocessTensorExpr mUse (sEx st)
                                    ex <- expandDefs allDefs ex0
                                    return st { sEx = ex })
                         (reverse (mSteps mUse))
          inits' <- mapM (expandInit mUse allDefs) (reverse (mInits mUse))
          mapM_ (\df ->
                    checkGeneratedSurface mDef (map defParamBase (defParams df))
                      ("in def " ++ defName df) (defBody df))
                defs
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

    resolveDefs mUse initial ds = goD initial ds
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
            (Just Tensor2, Just (rows, rhsIx)) -> do
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
                              | (a, b) <- rank2Pairs (componentIndices (mDim m) Tensor2)]
                  else fatal ("tensor initializer needs a full matrix (line "
                              ++ show ln ++ ")")
              return m { mInits = ITensor2 nm comps : mInits m }
            (k, Just (elems, rhsIx)) -> do
              validateInitSuffix nm lhsIx rhsIx
              let ok = case k of
                         Just Vector -> True
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
  bareIndexedField [] (tokenize s)
  `orElse`
  foldr (\t acc -> checkTok t `orElse` acc) Nothing (tokenize s)
  `orElse`
  foldr (\t acc -> checkIndexTok t `orElse` acc) Nothing (itok s)
  where
    bareIndexedField _ [] = Nothing
    bareIndexedField seen (TId nm _ : rest)
      | isBareIndexedFieldName nm
      , nm `notElem` locals
      , not (indexedAfter rest)
      , not (tensorArgumentContext seen) =
          Just ("indexed tensor field " ++ nm
                ++ " must be referenced with indices")
    bareIndexedField seen (tok : rest) = bareIndexedField (tok : seen) rest

    tensorArgumentContext seen =
      any isTensorOperator seen
    isTensorOperator (TId nm _) =
      nm == "tensorMap" || nm == "subrefs" || nm == "transpose"
      || nm `elem` standardNames
      || any ((== nm) . defName) (mDefs m)
    isTensorOperator _ = False

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

backendPlanFor :: Model -> IO BackendPlan
backendPlanFor m =
  case collectBackendRequests m >>= planBackend m of
    Right plan -> return plan
    Left msg -> fatal msg

lowerBackendText :: Model -> String -> IO String
lowerBackendText m source = do
  ast <- case parseTensorExprEither source of
           Right parsed -> return parsed
           Left msg -> fatal ("bad backend expression: " ++ msg)
  plan <- backendPlanFor m
  lowered <- case lowerBackendRequests plan ast of
               Right result -> return result
               Left msg -> fatal msg
  return (renderTensorExpr lowered)


-- ------------------------------------ tensor index equations
--
-- v'~i   = v~i + (dt / rho0) * ∂_j s~i_j
indexDefs :: Model -> [String] -> Step -> IO [String]
indexDefs m lets st = do
  validateFieldRefParts m lets (sNm st ++ concatMap ixSuffix (sIdx st))
  pre <- preprocessTensorExpr m (sEx st)
  ex <- lowerBackendText m pre
  strictEinstein m lets (sIdx st) ex
  case (kindOf m (sNm st), sIdx st) of
    (Just Vector, [fi]) -> do
      es <- mapM (\a -> ixExpand m lets [(ixName fi, a)]
                            (componentPlacement m (fieldPolicyOf m (sNm st)) [a]) ex)
                 (axisRange m)
      return ["def " ++ base ++ " := [| " ++ intercalate ", " es ++ " |]"]
    (Just SymM, [fi, fj]) ->
      mapM (\(a, b) -> comp ex [(ixName fi, a), (ixName fj, b)]
                         (componentPlacement m (fieldPolicyOf m (sNm st)) [a, b])
                         (base ++ show a ++ show b))
           (rank2Pairs (symComponentIndices (mDim m)))
    (Just AntiM, [fi, fj]) ->
      mapM (\(a, b) -> comp ex [(ixName fi, a), (ixName fj, b)]
                         (componentPlacement m (fieldPolicyOf m (sNm st)) [a, b])
                         (base ++ show a ++ show b))
           (rank2Pairs (antiComponentIndices (mDim m)))
    (Just Tensor2, [fi, fj]) ->
      mapM (\(a, b) -> comp ex [(ixName fi, a), (ixName fj, b)]
                              (componentPlacement m (fieldPolicyOf m (sNm st)) [a, b])
                              (base ++ show a ++ show b))
           (rank2Pairs (componentIndices (mDim m) Tensor2))
    _ -> fatal ("index equation has wrong indices for its field kind: " ++ sNm st)
  where
    base = "feq" ++ sNm st
    comp ex' env anchor defnm = do
      e <- ixExpand m lets env anchor ex'
      return ("def " ++ defnm ++ " := " ++ e)

implicitVectorDefs :: Model -> [String] -> Step -> IO [String]
implicitVectorDefs m lets st = do
  pre <- preprocessTensorExpr m (sEx st)
  ex <- lowerBackendText m pre
  if hasIndexSyntax m ex
    then do
      strictEinstein m lets [lhsIx] ex
      mapM (comp ex) (axisRange m)
    else do
      mapM scalarComp (axisRange m)
  where
    lhsIx = IxPart VDown "i"
    comp ex' a = do
      let anchor = componentPlacement m (fieldPolicyOf m (sNm st)) [a]
      e <- ixExpand m lets [(ixName lhsIx, a)] anchor ex'
      return ("def feq" ++ sNm st ++ show a ++ " := " ++ e)
    scalarComp a = do
      e <- rewrite m lets (Just (show a)) (sEx st)
      return ("def feq" ++ sNm st ++ show a ++ " := " ++ e)

-- names X whose updated value X' is referenced in some step RHS
primedRefs :: Model -> [String]
primedRefs m = sort (nub [nm | st <- mSteps m, TId nm True <- tokenize (sEx st)
                             , kindOf m nm /= Nothing])

-- Whole-tensor vector equations use the generated primed field family as the
-- structured source of their Formura left-hand-side component names.
tensorEqTargets :: Model -> [String]
tensorEqTargets m =
  [ sNm st
  | st <- mSteps m
  , sk st == KEq
  , not (null (sIdx st))
  , kindOf m (sNm st) == Just Vector
  ]

formEqTargets :: Model -> [String]
formEqTargets m =
  [ sNm st
  | st <- mSteps m
  , sk st == KEq
  , Just (Form _) <- [kindOf m (sNm st)]
  ]

-- rename user axis names to the internal coordinates x,y,z as needed
renameAxes :: Model -> String -> String
renameAxes m = concatMap out . tokenize
  where
    out (TId nm pr) = subst nm ++ (if pr then "'" else "")
    out (TC c) = [c]
    subst nm = case lookup nm (zip (mAxes m) (internalCoordNames m)) of
                 Just v -> v
                 Nothing -> nm

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
  pre <- preprocessTensorExpr m expr
  exprT <- lowerBackendText m pre
  fmap concat (mapM render (attach (elems exprT)))
  where
    elems exprT = map toElem (tokenize exprT)
    toElem (TId n p) = EId n p
    toElem (TC c) = EC c
    forms = [n | (n, Form _) <- mFlds m]
    vecs = [n | (n, Vector) <- mFlds m]
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

rewriteFormValue :: Model -> [String] -> String -> IO String
rewriteFormValue m lets expr = do
  pre <- preprocessTensorExpr m expr
  ast <- case parseTensorExprEither pre of
           Right parsed -> return parsed
           Left msg -> fatal ("bad differential-form expression: " ++ msg)
  rendered <- formValue ast
  case rendered of
    Just value -> return value
    Nothing -> fatal ("differential-form equation must produce a form: " ++ expr)
  where
    formValue :: TensorExpr -> IO (Maybe String)
    formValue ast =
      case ast of
        TEIdent base [] ->
          let (fieldName, primes) = fieldBaseOf base
          in case kindOf m fieldName of
               Just (Form _) ->
                 return (Just (fieldName ++ (if primes == 0 then "f" else "fN")))
               _ -> return Nothing
        TEApply (TEIdent op []) [operand]
          | op `elem` formOps -> do
              value <- requireForm operand
              return (Just (formOperator op ++ " " ++ parenthesize value))
        TEUnary "+" operand -> formValue operand
        TEUnary "-" operand -> do
          value <- requireForm operand
          return (Just ("FE.scaleForm (-1) " ++ parenthesize value))
        TEBinary op lhs rhs
          | op == "+" || op == "-" -> do
              lhsValue <- formValue lhs
              rhsValue <- formValue rhs
              case (lhsValue, rhsValue) of
                (Just lhsForm, Just rhsForm) ->
                  return (Just ((if op == "+" then "FE.addForm " else "FE.subForm ")
                                ++ parenthesize lhsForm ++ " " ++ parenthesize rhsForm))
                (Nothing, Nothing) -> return Nothing
                _ -> fatal ("cannot add a scalar and a differential form: " ++ expr)
          | op == "*" -> scaleProduct lhs rhs
          | op == "/" -> do
              lhsValue <- formValue lhs
              rhsValue <- formValue rhs
              case (lhsValue, rhsValue) of
                (Just lhsForm, Nothing) -> do
                  scalar <- scalarValue rhs
                  return (Just ("FE.scaleForm (1 / (" ++ scalar ++ ")) "
                                ++ parenthesize lhsForm))
                (Nothing, Nothing) -> return Nothing
                _ -> fatal ("form division requires a scalar denominator: " ++ expr)
        TEGroup operand -> formValue operand
        _ -> return Nothing

    scaleProduct lhs rhs = do
      lhsValue <- formValue lhs
      rhsValue <- formValue rhs
      case (lhsValue, rhsValue) of
        (Just lhsForm, Nothing) -> do
          scalar <- scalarValue rhs
          return (Just ("FE.scaleForm (" ++ scalar ++ ") " ++ parenthesize lhsForm))
        (Nothing, Just rhsForm) -> do
          scalar <- scalarValue lhs
          return (Just ("FE.scaleForm (" ++ scalar ++ ") " ++ parenthesize rhsForm))
        (Nothing, Nothing) -> return Nothing
        _ -> fatal ("multiplication of two differential forms needs an explicit wedge: " ++ expr)

    requireForm ast = do
      value <- formValue ast
      case value of
        Just form -> return form
        Nothing -> fatal ("form operator needs a differential-form operand: " ++ expr)

    scalarValue = rewrite m lets Nothing . renderTensorExpr

    formOperator op
      | op `elem` deltaOps = "FE.codiffForm feDim feFormDerivative"
      | op == "hodge" = "FE.hodgeForm feDim"
      | otherwise = "FE.dForm feDim feFormDerivative"

    parenthesize value
      | all isAlphaNum value = value
      | otherwise = "(" ++ value ++ ")"

rewriteScalar :: Model -> [String] -> String -> IO String
rewriteScalar = rewriteScalarAt Collocated

rewriteScalarAt :: GridPolicy -> Model -> [String] -> String -> IO String
rewriteScalarAt targetPolicy m lets expr = do
  pre <- preprocessTensorExpr m expr
  parsed <- case parseTensorExprEither pre of
              Right ast -> return ast
              Left msg -> fatal ("bad scalar expression: " ++ msg)
  if hasIndexSyntax m pre
    then strictEinstein m lets [] pre
         >> ixExpand m lets [] (componentPlacement m targetPolicy []) pre
    else do
      let sourcePolicies = nub
            [fieldPolicyOf m fieldName
            | TId tokenName _ <- tokenize pre
            , let (fieldName, _) = fieldBaseOf tokenName
            , kindOf m fieldName == Just Scalar]
      case [policy | policy <- sourcePolicies, policy /= targetPolicy] of
        policy:_ ->
          fatal ("grid policy mismatch in scalar equation: target is "
                 ++ gridPolicySurfaceName targetPolicy ++ " but source is "
                 ++ gridPolicySurfaceName policy ++ " in: " ++ expr)
        [] -> return ()
      if targetPolicy /= Collocated && hasLbRequest parsed
        then fatal ("lb currently requires a collocated scalar target: " ++ expr)
        else rewrite m lets Nothing expr

rewriteScalarInitializerAt :: GridPolicy -> Model -> [String] -> String -> IO String
rewriteScalarInitializerAt targetPolicy m lets expr = do
  pre <- preprocessTensorExpr m expr
  if hasIndexSyntax m pre
    then strictEinstein m lets [] pre
         >> ixExpandInitializer m lets [] (componentPlacement m targetPolicy []) pre
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

egiStringPairs :: [(String, String)] -> String
egiStringPairs pairs =
  "[" ++ intercalate ", "
    ["(" ++ show source ++ ", " ++ show target ++ ")"
    | (source, target) <- pairs]
  ++ "]"

egiFieldPolicyPairs :: [(String, GridPolicy)] -> String
egiFieldPolicyPairs pairs =
  "[" ++ intercalate ", "
    ["(" ++ show fieldName ++ ", " ++ show policy ++ ")"
    | (fieldName, policy) <- pairs]
  ++ "]"

egiListDef :: String -> String -> [String] -> [String]
egiListDef name emptyTypeAnnotation elems
  | null elems = ["def " ++ name ++ emptyTypeAnnotation ++ " := []"]
  | otherwise =
      ("def " ++ name ++ " :=")
      : [ (if i == (0 :: Int) then "  [ " else "  , ") ++ elemText
        | (i, elemText) <- zip [0 ..] elems ]
      ++ ["  ]"]

egiConcatDef :: String -> [String] -> String
egiConcatDef name elems =
  "def " ++ name ++ " := "
  ++ if null elems then "[]" else intercalate " ++ " elems

emit :: Model -> IO String
emit m = do
  if length (mAxes m) /= mDim m
    then fatal ("axes count (" ++ show (length (mAxes m))
                ++ ") does not match dimension (" ++ show (mDim m) ++ ")")
    else return ()
  let lets = [sNm st | st <- mSteps m, sk st == KLet, isIndexI (sIdx st)]
      prims = sort (nub (primedRefs m ++ tensorEqTargets m ++ formEqTargets m))
  if mMetric m /= Nothing && mEmbed m /= Nothing
    then fatal "declare either 'metric scale' or 'embedding', not both"
    else return ()
  backendPlan <- backendPlanFor m
  let lbPlan = bpLbPlan backendPlan
      metricTarget = lpSource <$> lbPlan
      internalCoords = internalCoordNames m
      internalHsteps = internalHstepNames m
      internalGridSteps = map ("d" ++) (mAxes m)
      internalIndexVars = internalIndexNames m
      coordVec = "[| " ++ intercalate ", " internalCoords ++ " |]"
      hstepVec = "[| " ++ intercalate ", " internalHsteps ++ " |]"
      coordArgs = intercalate ", " internalCoords
      axisIds = axisRange m
      axisList = "[" ++ intercalate ", " (map show axisIds) ++ "]"
      symbolDecl = "declare symbol " ++ intercalate ", " (internalCoords ++ internalHsteps)
      needsFormContext = selectedMode m == DecMode
      symbolNames =
        zip internalHsteps internalGridSteps
        ++ [ (c, "(" ++ ix ++ "*" ++ g ++ ")")
           | (c, ix, g) <- zip3 internalCoords internalIndexVars internalGridSteps ]
      contextDecls =
            [ symbolDecl
            , "def feDim : Integer := " ++ show (mDim m)
            , "def feAxes : [String] := " ++ egiStringList (mAxes m)
            , "def feAxisIds : [Integer] := " ++ axisList
            , "def feCoords : Vector MathValue := " ++ coordVec
            , "def feHsteps : Vector MathValue := " ++ hstepVec
            ]
      scalarContextDecls =
            [ "def shift (a: Integer) (c: MathValue) (u: MathValue) : MathValue :="
            , "  substitute [(feCoords_a, feCoords_a + c * feHsteps_a)] u"
            , "def dC (a: Integer) (u: MathValue) : MathValue :="
            , "  (shift a 1 u - shift a (-1) u) / (2 * feHsteps_a)"
            , "def dC2 (a: Integer) (u: MathValue) : MathValue :="
            , "  (shift a 1 u - 2 * u + shift a (-1) u) / ((feHsteps_a) ^ 2)"
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
            [ "def yeeRef (sT: [MathValue]) (fld: (MathValue, [MathValue])) (disp: [MathValue]) : MathValue :="
            , "  let (fF, sF) := fld"
            , "   in substitute"
            , "        (map (\\a -> (feCoords_a, feCoords_a + (nth a disp + nth a sT - nth a sF) * feHsteps_a)) feAxisIds)"
            , "        fF"
            , "def unit3 (a: Integer) (c: MathValue) : [MathValue] :="
            , "  map (\\b -> if a = b then c else 0) feAxisIds"
            , "def dYee (a: Integer) (sT: [MathValue]) (fld: (MathValue, [MathValue])) : MathValue :="
            , "  (yeeRef sT fld (unit3 a (1 / 2)) - yeeRef sT fld (unit3 a (-1 / 2))) / feHsteps_a"
            ]
      formContextDecls =
            [ "def feFormDerivative"
            , "      (policy: GridPolicy) (targetBasis: [Integer])"
            , "      (axis: Integer) (sourceBasis: [Integer])"
            , "      (value: MathValue) : MathValue :="
            , "  dYee axis (FE.componentPlacement feDim policy targetBasis)"
            , "             (value, FE.componentPlacement feDim policy sourceBasis)"
            ]
      metricContextDecls =
            case (mMetricName m, mMetric m, mEmbed m) of
              (Nothing, Nothing, Nothing) -> []
              _ ->
                let identity = "FE.metricTensor feDim (\\i j -> if i = j then 1 else 0)"
                    gen nm expr =
                      (nm, "def " ++ nm ++ " := " ++ expr)
                    (covExpr, contraExpr) = case (mMetric m, mEmbed m) of
                      (Just _, _) ->
                        ("FE.diagonalMetricTensor feDim feH",
                         "FE.inverseDiagonalMetricTensor feDim feH")
                      (Nothing, Just _) ->
                        ("FE.metricTensor feDim feG",
                         "FE.metricTensor feDim (\\i j -> if i = j then 1 / (feG i i) else 0)")
                      (Nothing, Nothing) -> (identity, identity)
                in [ gen (metricInternalBase VDown VDown) covExpr
                   , gen (metricInternalBase VUp VUp) contraExpr
                   , gen (metricInternalBase VUp VDown) identity
                   , gen (metricInternalBase VDown VUp) identity
                   ]
      fieldNames =
        [ (egisonName, storageName)
        | (egisonName, storageName) <- concatMap (fieldStorageMapEntries m) (mFlds m)
        , egisonName /= storageName
        ]
      fieldPolicies =
        [(fdName fd, fdPolicy fd) | fd <- mFieldDecls m]
      printerContextDecls =
            [ "def feSymbolNames : [(String, String)] := " ++ egiStringPairs symbolNames
            , "def feFieldNames : [(String, String)] := " ++ egiStringPairs fieldNames
            , "def feFieldPolicies : [(String, GridPolicy)] := " ++ egiFieldPolicyPairs fieldPolicies
            , "def feIndexNames : [String] := " ++ egiStringList internalIndexVars
            , "def fePrinterContext := (feSymbolNames, feFieldNames, feIndexNames, feCoords, feHsteps, feAxisIds)"
            , "def fmrEq : String -> MathValue -> String := FMR.eq fePrinterContext"
            , "def fmrInit : String -> MathValue -> String := FMR.init fePrinterContext"
            , "def componentEqs : [String] -> [MathValue] -> [String] := FMR.componentEqs fePrinterContext"
            ]
            ++ [ "def tensorEqs : Tensor MathValue -> Tensor MathValue -> [String] := FMR.tensorEqs fePrinterContext"
               | not (null (tensorEqTargets m)) ]
            ++ [ "def formEqs : (GridPolicy, Tensor MathValue) -> (GridPolicy, Tensor MathValue) -> [String] := FMR.formEqs fePrinterContext"
               | needsFormContext ]
            ++ ["def scalarEq : String -> MathValue -> [String] := FMR.scalarEq fePrinterContext"]
      embeddingDefs = case mEmbed m of
        Nothing -> []
        Just es ->
          [ "def feX : [MathValue] := [" ++ intercalate ", " (map (renameAxes m) es) ++ "]"
          , "def feG (a: Integer) (b: Integer) : MathValue := FE.inducedMetric feCoords feX a b"
          ]
      orthoGate = case mEmbed m of
        Nothing -> []
        Just _ ->
          let offDiag = [(a, b) | a <- axisRange m, b <- axisRange m, a < b]
              cond = intercalate " && "
                       ["feG " ++ show a ++ " " ++ show b ++ " = 0"
                       | (a, b) <- offDiag]
              msg = "# ERROR: the embedding is not orthogonal (off-diagonal metric terms must vanish symbolically); general metrics are not supported yet"
          in if null offDiag then [] else [(cond, msg)]
  body <- mapM (stepDefs lets) (mSteps m)
  items <- mapM (stepItem lets) (mSteps m)
  inits <- mapM (initLine lets) (mInits m)
  let metricAuxFields = maybe [] lpAuxFields lbPlan
      metricStateFields =
        [field | field <- metricAuxFields, afLifetime field == PersistentState]
      metricStepFields =
        [field | field <- metricAuxFields, afLifetime field == StepLocal]
      metricCoeffFields =
        [(axis, field) | field <- metricAuxFields,
                         LbCoefficient axis <- [afRole field]]
      metricFluxFields =
        [(axis, field) | field <- metricAuxFields,
                         LbFlux axis <- [afRole field]]
      metricVolumeField =
        case [field | field <- metricAuxFields, afRole field == LbVolume] of
          field:_ -> Just field
          [] -> Nothing
      metricCoeffNames = [afName field | (_, field) <- metricCoeffFields]
      metricFluxNames = [afName field | (_, field) <- metricFluxFields]
      metricVolumeName = maybe "sg" afName metricVolumeField
      metricCellPlacement =
        maybe (placeText (componentPlacement m Collocated []))
              (placeText . afPlacement) metricVolumeField
      metricFluxPlacements =
        [placeText (afPlacement field) | (_, field) <- metricFluxFields]
      sampleAt field value =
        case [ "(feCoords_" ++ show axis ++ ", feCoords_" ++ show axis
               ++ " + feHsteps_" ++ show axis ++ " / 2)"
             | (axis, shifted) <- zip (axisRange m)
                                      (placementBits (afPlacement field))
             , shifted
             ] of
          [] -> value
          substitutions ->
            "substitute [" ++ intercalate ", " substitutions ++ "] ("
            ++ value ++ ")"
      renderAuxInit field =
        case afRole field of
          LbCoefficient axis ->
            [ "fmrInit \"" ++ afName field ++ "\" ("
              ++ sampleAt field
                   ("FE.orthogonalHodgeCoefficient feAxisIds feH ["
                    ++ show axis ++ "]")
              ++ ")" ]
          LbVolume -> ["fmrInit \"" ++ afName field ++ "\" feSqrtG"]
          LbFlux _ -> []
      mtDecls = case lbPlan of
        Nothing -> []
        Just _ -> [ "def " ++ n ++ " := function (" ++ coordArgs ++ ")"
                  | n <- map afName metricAuxFields ]
      mtInits = concatMap renderAuxInit metricAuxFields
      mtFlds = [(afName field, Scalar) | field <- metricStateFields]
      mtFlux =
        [ "[fmrEq \"" ++ afName field ++ "\" (feLbFlux "
          ++ show axis ++ ")]"
        | field <- metricStepFields
        , LbFlux axis <- [afRole field]
        ]
      mtPass = [ "scalarEq \"" ++ afName field ++ "\" ("
                 ++ afName field ++ ")"
               | field <- metricStateFields ]
      stepItems = mtFlux ++ [it | Just it <- items] ++ mtPass
      ddDef = case mDd m of
        Nothing -> []
        Just g -> ["def feDD := foldl (\\acc x -> acc + x ^ 2) 0"
                   ++ " (FE.formComponents (snd (FE.dForm feDim feFormDerivative"
                   ++ " (FE.dForm feDim feFormDerivative "
                   ++ dropWhileEnd (== '\'') g ++ "fN))))"]
      generatedBody = concat body ++ ddDef
      gates = orthoGate ++ (case mDd m of
                Just _ -> [("feDD = 0",
                            "# ERROR: d . d /= 0 on this grid -- refusing to generate")]
                Nothing -> [])
      operationalResidualText = unlines
        (generatedBody ++ concat inits ++ mtInits ++ stepItems)
      residualText = operationalResidualText ++ unlines (map fst gates)
      residualNames = [name | TId name _ <- tokenize residualText]
      operationalNames = [name | TId name _ <- tokenize operationalResidualText]
      usesOperationalName names = any (`elem` operationalNames) names
      needsScalarContext =
        "∂ " `isInfixOf` operationalResidualText
        || usesOperationalName ["shift", "dC", "dC2", "dTaylor", "axisId"]
      needsResidualYeeContext =
        metricTarget /= Nothing
        || usesOperationalName ["dYee", "yeeRef", "unit3"]
      contextMathDecls =
        (if needsScalarContext then scalarContextDecls else [])
        ++ (if needsFormContext || needsResidualYeeContext then yeeContextDecls else [])
        ++ (if needsFormContext then formContextDecls else [])
      usesResidualFamily name =
        any (\residualName -> residualName == name
                              || (name ++ "_") `isPrefixOf` residualName)
            residualNames
      liveMetricContext =
        [(name, decl) | (name, decl) <- metricContextDecls, usesResidualFamily name]
      liveMetricContextDecls = map snd liveMetricContext
      scaleMetricFamilies =
        [metricInternalBase VDown VDown, metricInternalBase VUp VUp]
      needsScaleFactors =
        metricTarget /= Nothing
        || (mMetric m /= Nothing
            && any (\(name, _) -> name `elem` scaleMetricFamilies) liveMetricContext)
      scaleFactorDefs = case (mMetric m, mEmbed m) of
        (Just hs, _)
          | needsScaleFactors ->
              [ "def feH (a: Integer) : MathValue := nth a ["
                  ++ intercalate ", " (map (renameAxes m) hs) ++ "]" ]
        (Nothing, Just _)
          | metricTarget /= Nothing ->
              [ "def feH (a: Integer) : MathValue := sqrt (feG a a)" ]
        _ -> []
      volumeDefs = case metricTarget of
        Nothing -> []
        Just _ -> ["def feSqrtG : MathValue := FE.orthogonalVolume feAxisIds feH"]
      lbOperatorDefs = case lbPlan of
        Nothing -> []
        Just plan ->
          [ "def feLbCellPlacement : [MathValue] := " ++ metricCellPlacement
          , "def feLbFluxPlacement (axis: Integer) : [MathValue] :="
          , "  nth axis " ++ egiMathList metricFluxPlacements
          , "def feLbGradient (axis: Integer) (value: MathValue) : MathValue :="
          , "  dYee axis (feLbFluxPlacement axis)"
          , "             (value, feLbCellPlacement)"
          , "def feLbDivergence (axis: Integer) (value: MathValue) : MathValue :="
          , "  dYee axis feLbCellPlacement"
          , "             (value, feLbFluxPlacement axis)"
          , "def feLbCoefficient (axis: Integer) : MathValue :="
          , "  nth axis " ++ egiMathList metricCoeffNames
          , "def feLbFlux (axis: Integer) : MathValue :="
          , "  FE.lbFlux feLbGradient feLbCoefficient axis " ++ lpSource plan
          , "def feLbStoredFlux (axis: Integer) : MathValue :="
          , "  nth axis " ++ egiMathList metricFluxNames
          , "def " ++ lpResultName plan ++ " : MathValue :="
          , "  FE.lbFromFluxes feAxisIds feLbDivergence feLbStoredFlux "
              ++ metricVolumeName
          ]
      metricDefs = embeddingDefs ++ scaleFactorDefs ++ volumeDefs
      header =
        [ "--"
        , "-- GENERATED by fec (the Formurae compiler) from " ++ mName m
            ++ ".fme -- edit the .fme, not this file"
        , "-- mode " ++ modeSurfaceName (selectedMode m)
        , "-- load lib/formurae-grid.egi, lib/formurae-tensor.egi, lib/formurae-geometry.egi, lib/fmrgen.egi, and lib/formurae-runtime.egi before this file"
        , "--"
        , "" ] ++
        (if null (mParams m) then []
         else [ "declare symbol " ++ intercalate ", " (map fst (mParams m)), "" ])
      fieldDecls = concatMap fdecl (mFlds m)
      primDecls = concatMap pdecl prims
      localDecls = [ "def " ++ sNm st ++ " := function (" ++ coordArgs ++ ")"
                   | st <- mSteps m, sk st == KLocal ]
                   ++ metricDefs ++ mtDecls ++ lbOperatorDefs
      feParams = "def feParams := ["
                 ++ intercalate ", " [ "(\"" ++ n ++ "\", \"" ++ v ++ "\")"
                                     | (n, v) <- mParams m ] ++ "]"
      generatedHelps = case (mEmbed m, metricTarget) of
        (Just _, Just _)
          | "sqrt" `notElem` declaredExterns (mHelp m) ->
              ["extern function :: sqrt"]
        _ -> []
      explicitHelps = mHelp m ++ generatedHelps
      helps = autoScalarExterns m explicitHelps ++ explicitHelps
      feHelpers = egiListDef "feHelpers" " : [String]"
        ["\"" ++ escH h ++ "\"" | h <- helps]
      feComps = "def feComps : [String] := "
                ++ egiStringList (concat [componentStorageNames m n k
                                          | (n, k) <- mFlds m ++ mtFlds])
      feInits = egiListDef "feInits" "" (concat inits ++ mtInits)
      feSteps = egiConcatDef "feSteps" stepItems
      emitter = "FMR.emitModelOn feDim feAxes"
      emitCall = "print (" ++ emitter ++ " feParams feHelpers feComps feInits feSteps)"
      nest [] = emitCall
      nest ((c, msg):gs) =
        "if " ++ c ++ " then (" ++ nest gs ++ ") else print \"" ++ escH msg ++ "\""
      mainDef
        | null gates = [ "def main (args: [String]) : IO () := " ++ emitCall ]
        | otherwise = [ "def main (args: [String]) : IO () :=", "  " ++ nest gates ]
  return (unlines (header ++ contextDecls ++ contextMathDecls ++ printerContextDecls
                   ++ (if null contextDecls then [] else [""])
                   ++ fieldDecls ++ primDecls ++ localDecls
                   ++ liveMetricContextDecls ++ [""]
                   ++ generatedBody ++ (if null generatedBody then [] else [""])
                   ++ [feParams] ++ feHelpers ++ [feComps] ++ feInits
                   ++ [feSteps] ++ [""] ++ mainDef))
  where
    fieldCoordArgs = intercalate ", " (internalCoordNames m)
    shape1 = "[" ++ show (mDim m) ++ "]"
    shape2 = "[" ++ show (mDim m) ++ ", " ++ show (mDim m) ++ "]"
    shapeK k = "[" ++ intercalate ", " (replicate k (show (mDim m))) ++ "]"
    fdecl (nm, Scalar) = ["def " ++ nm ++ " := function (" ++ fieldCoordArgs ++ ")"]
    fdecl (nm, Vector) =
      ["def " ++ nm ++ " := generateTensor (\\[i] -> function (" ++ fieldCoordArgs ++ ")) " ++ shape1]
    fdecl (nm, SymM) =
      ["def " ++ nm ++ " := generateTensor (\\[i, j] -> function (" ++ fieldCoordArgs ++ ")) " ++ shape2]
    fdecl (nm, AntiM) =
      ["def " ++ nm ++ " := generateTensor (\\[i, j] -> function (" ++ fieldCoordArgs ++ ")) " ++ shape2]
    fdecl (nm, Tensor2) =
      ["def " ++ nm ++ " := generateTensor (\\[i, j] -> function (" ++ fieldCoordArgs ++ ")) " ++ shape2]
    fdecl (nm, Form k) =
      formFamilyDecl nm "" k
      ++ [ "def " ++ nm ++ "f : (GridPolicy, Tensor MathValue) := ("
           ++ show (fieldPolicyOf m nm) ++ ", " ++ formTensorValue nm "" k ++ ")" ]
    pdecl nm = case kindOf m nm of
      Just Scalar -> ["def " ++ nm ++ "' := function (" ++ fieldCoordArgs ++ ")"]
      Just Vector ->
        ["def " ++ nm ++ "' := generateTensor (\\[i] -> function (" ++ fieldCoordArgs ++ ")) " ++ shape1]
      Just SymM ->
        ["def " ++ nm ++ "' := generateTensor (\\[i, j] -> function (" ++ fieldCoordArgs ++ ")) " ++ shape2]
      Just AntiM ->
        ["def " ++ nm ++ "' := generateTensor (\\[i, j] -> function (" ++ fieldCoordArgs ++ ")) " ++ shape2]
      Just Tensor2 ->
        ["def " ++ nm ++ "' := generateTensor (\\[i, j] -> function (" ++ fieldCoordArgs ++ ")) " ++ shape2]
      Just (Form k) ->
        formFamilyDecl nm "'" k
        ++ [ "def " ++ nm ++ "fN : (GridPolicy, Tensor MathValue) := ("
             ++ show (fieldPolicyOf m nm) ++ ", " ++ formTensorValue nm "'" k ++ ")" ]
      Nothing -> []
    formFamilyDecl nm primes k
      | k == 0 =
          ["def " ++ nm ++ primes ++ " := function (" ++ fieldCoordArgs ++ ")"]
      | k > 0 =
          let vars = take k (internalIndexNames m)
          in ["def " ++ nm ++ primes
              ++ " := generateTensor (\\[" ++ intercalate ", " vars
              ++ "] -> function (" ++ fieldCoordArgs ++ ")) " ++ shapeK k]
      | otherwise =
          error ("unsupported form degree in field declaration: " ++ nm)
    formTensorValue nm primes k
      | k == 0 =
          "FE.canonicalFormTensor (\\[] -> " ++ nm ++ primes ++ ") feDim 0"
      | otherwise =
          "FE.canonicalFormTensor (FE.tensorComponentAt " ++ nm ++ primes
          ++ ") feDim " ++ show k
    stepDefs lets st = case sk st of
      KLet | isIndexI (sIdx st) -> do
               e <- rewrite m lets Nothing (sEx st)
               let nm = sNm st
               return ["def " ++ nm ++ " := withSymbols [i] " ++ e]
           | otherwise -> do
               e <- rewriteScalar m lets (sEx st)
               return ["def " ++ sNm st ++ " := " ++ e]
      KEq
        | not (null (sIdx st)), isIndexKind (kindOf m (sNm st)) -> indexDefs m lets st
        | isIndexI (sIdx st) -> do
            e <- rewrite m lets Nothing (sEx st)
            return ["def feq" ++ sNm st ++ "_i := withSymbols [i] " ++ e]
        | kindOf m (sNm st) == Just Vector && null (sIdx st) -> do
            implicitVectorDefs m lets st
      _ -> return []
    stepItem lets st = case sk st of
      KLet -> return Nothing
      KLocal -> do
        e <- rewriteScalar m lets (sEx st)
        return (Just ("[fmrEq \"" ++ sNm st ++ "\" (" ++ e ++ ")]"))
      KEq
        | Just Vector <- kindOf m (sNm st)
        , not (null (sIdx st)) ->
            let nm = sNm st
            in return (Just ("tensorEqs " ++ nm ++ "' feq" ++ nm))
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
        | Just Tensor2 <- kindOf m (sNm st) ->
            let nm = sNm st
                names = egiStringList (componentStorageNamesOf m nm)
            in return (Just ("componentEqs " ++ names ++ " "
                             ++ egiMathList ["feq" ++ nm ++ show a ++ show b
                                            | (a, b) <- rank2Pairs (componentIndices (mDim m) Tensor2)]))
        | not (null (sIdx st)) ->
            let nm = sNm st
                names = egiStringList (componentStorageNamesOf m nm)
            in return (Just ("componentEqs " ++ names ++ " "
                             ++ egiMathList ["feq" ++ nm ++ show a
                                            | a <- axisRange m]))
        | kindOf m (sNm st) == Just Vector ->
            let nm = sNm st
                names = egiStringList (componentStorageNamesOf m nm)
            in return (Just ("componentEqs " ++ names ++ " "
                             ++ egiMathList ["feq" ++ nm ++ show a
                                            | a <- axisRange m]))
        | Just (Form _) <- kindOf m (sNm st) -> do
            rhs <- rewriteFormValue m lets (sEx st)
            let target = sNm st ++ "fN"
            return (Just ("formEqs " ++ target ++ " (" ++ rhs ++ ")"))
        | otherwise -> do
            e <- rewriteScalarAt (fieldPolicyOf m (sNm st)) m lets (sEx st)
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
        let policy = fieldPolicyOf m nm
            anchor = componentPlacement m policy []
        e <- rewriteScalarInitializerAt policy m lets ex
        let sampled = if policy == Collocated then e else shiftTo anchor e
        return ["fmrInit \"" ++ nm ++ "\" (" ++ sampled ++ ")"]
      ICasIndex nm lhsIx ex -> indexedInitLines lets nm lhsIx ex

    indexedInitLines lets nm lhsIx ex = do
      pre <- preprocessTensorExpr m ex
      strictEinstein m lets lhsIx pre
      case (kindOf m nm, lhsIx) of
        (Just Vector, [fi]) ->
          mapM (\a -> comp pre [a] [(ixName fi, a)]
                       (componentPlacement m (fieldPolicyOf m nm) [a]))
               (axisRange m)
        (Just SymM, [fi, fj]) ->
          mapM (\(a, b) -> comp pre [a, b] [(ixName fi, a), (ixName fj, b)]
                         (componentPlacement m (fieldPolicyOf m nm) [a, b]))
               (rank2Pairs (symComponentIndices (mDim m)))
        (Just AntiM, [fi, fj]) ->
          mapM (\(a, b) -> comp pre [a, b] [(ixName fi, a), (ixName fj, b)]
                         (componentPlacement m (fieldPolicyOf m nm) [a, b]))
               (rank2Pairs (antiComponentIndices (mDim m)))
        (Just Tensor2, [fi, fj]) ->
          mapM (\(a, b) -> comp pre [a, b] [(ixName fi, a), (ixName fj, b)]
                       (componentPlacement m (fieldPolicyOf m nm) [a, b]))
               (rank2Pairs (componentIndices (mDim m) Tensor2))
        _ -> fatal ("indexed CAS initializer has wrong indices for its field kind: " ++ nm)
      where
        kind = case kindOf m nm of
                 Just k -> k
                 Nothing -> Scalar
        comp pre' inds env anchor = do
          e <- ixExpandInitializer m lets env anchor pre'
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
