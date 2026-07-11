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
--   def NAME ARG... = EXPR          user-defined operator.  Surface
--                                    substitution uses the TensorExpr AST;
--                                    standard coordinate operators retain
--                                    native FE.* identity.  Use
--                                    withSymbols for newly introduced free
--                                    indices and contractWith / `.` for
--                                    contraction.  Tensor primitives are
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
-- operators such as Δ use native shared tensor definitions and may be
-- shadowed by user definitions; Δ4 is user-defined.
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
import Data.Maybe (fromMaybe)
import System.Environment (getArgs)
import System.IO (hPutStrLn, stderr)

import Formurae.BackendPlan
import Formurae.Common
import Formurae.Index
import Formurae.Syntax
import Formurae.TensorExpr
  ( TensorExpr
  , pattern TEIdent
  , pattern TENumber
  , pattern TEApply
  , pattern TECall
  , pattern TEIf
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
  , transformTensorExprM
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
-- Egison's Tensor primitives.  Standard coordinate operators are registered
-- as hygienic native markers.  User definitions are subsequently pushed in
-- front of those entries and therefore shadow the corresponding FE.* entry.
standardNames :: [String]
standardNames =
  [ ".", "wedge", "trace", "sym", "antisym"
  , "norm2", "hessian", "grad", "dGrad", "divg", "curl", "lap", "Δ"
  , "flat", "sharp"
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

nativeGradName, nativeDGradName, nativeDivgName, nativeCurlName,
  nativeLapName, nativeHessianName :: String
nativeGradName = reservedInternalPrefix ++ "NativeGrad"
nativeDGradName = reservedInternalPrefix ++ "NativeDGrad"
nativeDivgName = reservedInternalPrefix ++ "NativeDivg"
nativeCurlName = reservedInternalPrefix ++ "NativeCurl"
nativeLapName = reservedInternalPrefix ++ "NativeLap"
nativeHessianName = reservedInternalPrefix ++ "NativeHessian"

-- Standard coordinate operators retain their identity after user-definition
-- expansion.  The marker heads are lowered to the shared Egison tensor
-- kernel at emission time.  User definitions still shadow these entries
-- because they are inserted before the prelude in the definition lookup.
nativeOperatorDefs :: Model -> [Def]
nativeOperatorDefs m =
  [ Def "grad" ["u"] (nativeGradName ++ " u")
  , Def "dGrad" ["X"] (nativeDGradName ++ " X")
  , Def "divg" ["X"] (nativeDivgName ++ " X")
  ]
  ++ [ Def "curl" ["X"] (nativeCurlName ++ " X")
     | mDim m == 3
     ]
  ++ [ Def "lap" ["u"] (nativeLapName ++ " u")
     , Def "Δ" ["u"] (nativeLapName ++ " u")
     , Def "hessian" ["u"] (nativeHessianName ++ " u")
     ]

-- The component lowering remains a temporary validation oracle while the
-- native path is rolled out.  It is never emitted for a native expression.
legacyNativeValidationDefs :: Model -> [Def]
legacyNativeValidationDefs m =
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
      name `elem` generatedValueNames
      || any (`isPrefixOf` name) ["feq", "feLb"]
    generatedValueNames =
      internalCoordNames m
      ++ internalHstepNames m
      ++ [ "feDim", "feAxes", "feAxisIds", "feCoords", "feHsteps"
         , "shift", "dC", "dC2", "dTaylor", "axisId", "∂"
         , "yeeRef", "unit3", "dYee"
         , "feTensorDerivative"
         , "feFormDerivative"
         , "feHodgeCoefficient"
         , "feMusicalScale"
         , "feLbGradient", "feLbDivergence", "feLbCoefficient", "feLbFlux"
         , "feLbCellPlacement", "feLbFluxPlacement"
         , "feLbStoredFlux", lbResultBindingName
         , "hodge", "dForm", "codiff"
         , "feSymbolNames", "feFieldDescriptors", "feFieldNames", "feFieldPolicies", "feIndexNames", "fePrinterContext"
         , "fmrEq", "fmrInit", "componentEqs", "fieldEqs", "scalarEq"
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
    check (TId "flat" _) _
      | not (userDefined "flat") && selectedMode m /= DecMode =
      Just "flat requires mode dec"
    check (TId "sharp" _) _
      | not (userDefined "sharp") && selectedMode m /= DecMode =
      Just "sharp requires mode dec"
    check _ _ = Nothing
    indexedAfter rest =
      case dropWhile isSpTok rest of
        TC '~' : _ -> True
        TC '_' : _ -> True
        _ -> False
    orElse (Just x) _ = Just x
    orElse Nothing y = y

parseFe :: FilePath -> String -> String -> IO Model
parseFe sourcePath name txt = go STop initialModel
                      (zip [1 :: Int ..] (lines txt))
  where
    initialModel = Model
      { mName = name
      , mSourcePath = sourcePath
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
          preludeDefs <- resolveDefs mUse [] (nativeOperatorDefs mUse)
          let userDefs0 = reverse (mDefs mUse)
          allDefs <- resolveDefs mUse preludeDefs userDefs0
          let defs = take (length userDefs0) allDefs
          let mDef = mUse { mDefs = defs }
          steps' <- mapM (\st -> do ex0 <- preprocessTensorExpr mUse (sEx st)
                                    ex <- expandDefs allDefs ex0
                                    return st { sEx = ex
                                              , sSourceMapped = ex == ex0 })
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
              SStep -> stp ln code m >>= \m' -> go SStep m' rest

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
          return m { mSteps = Step KLet nm ix ex ln expressionColumn ex True : mSteps m }
      | Just (nm, _, ex) <- eqForm "local" s = do
          rejectReservedName ln nm
          return m { mSteps = Step KLocal nm [] ex ln expressionColumn ex True : mSteps m }
      | Just (nm, ixs, ex) <- primeEqForm s = do
          rejectReservedName ln nm
          return m { mSteps = Step KEq nm ixs ex ln expressionColumn ex True : mSteps m }
      | otherwise = fatal ("bad step eq: " ++ s ++ " (line " ++ show ln ++ ")")
      where
        s = strip s0
        banned = surfaceBanned m [] s
        expressionColumn = rhsStartColumn s0

    rhsStartColumn line =
      case break (== '=') line of
        (_, []) -> 1
        (prefix, _ : rhs) ->
          length prefix + 2 + length (takeWhile isSpace rhs)

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
      || nm `elem` map fst nativeMarkerMap
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

-- ---------------------------------------------------------------- native tensor operators

data NativeValue = NativeValue
  { nativeText     :: String
  , nativeRank     :: Int
  , nativePolicy   :: Maybe GridPolicy
  , nativeOperator :: Bool
  }

nativeMarkerMap :: [(String, String)]
nativeMarkerMap =
  [ (nativeGradName, "grad")
  , (nativeDGradName, "dGrad")
  , (nativeDivgName, "divg")
  , (nativeCurlName, "curl")
  , (nativeLapName, "lap")
  , (nativeHessianName, "hessian")
  ]

-- Reconstruct the former component expression only for validation and for
-- surface constructs that are not yet representable by the native emitter.
-- Native equations themselves never contain this expansion.
nativeLegacyExpression :: Model -> String -> IO String
nativeLegacyExpression m source =
  expandDefs (legacyNativeValidationDefs m) (untok (map replace (tokenize source)))
  where
    replace (TId name primes) =
      case lookup name nativeMarkerMap of
        Just legacyName -> TId legacyName primes
        Nothing -> TId name primes
    replace token = token

-- `sharp` changes representation from a form tuple to a rank-1 tensor.  The
-- legacy signature oracle has no form tuple node, so use the actual target
-- field reference as a signature/placement placeholder while validating the
-- complete surrounding expression.  This does not affect emitted code.
nativeSignatureExpression :: String -> [IxPart] -> String -> IO String
nativeSignatureExpression target targetIndices source =
  case parseTensorExprEither source of
    Left message -> fatal ("bad native signature expression: " ++ message)
    Right expression -> do
      replaced <- transformTensorExprM replaceSharp expression
      return (renderTensorExpr replaced)
  where
    replaceSharp expression =
      case expression of
        TEApply (TEIdent "sharp" []) [_] ->
          return (Just (TEIdent target targetIndices))
        _ -> return Nothing

flipPolicy :: GridPolicy -> GridPolicy
flipPolicy Collocated = Collocated
flipPolicy Primal = Dual
flipPolicy Dual = Primal

nativeBases :: Model -> Int -> [[Int]]
nativeBases _ 0 = [[]]
nativeBases m rank =
  [axis : rest | axis <- axisRange m, rest <- nativeBases m (rank - 1)]

-- GridPolicy is metadata; compatibility is decided by the concrete physical
-- placement of every result component.  This matters for rank-0 values,
-- where Collocated and Primal both denote the cell centre, and for scalar ×
-- tensor expressions, where equal policy names can still denote different
-- component locations.
mergeNativePlacements
  :: Model -> GridPolicy -> String -> Int -> [NativeValue]
  -> IO (Maybe GridPolicy)
mergeNativePlacements m targetPolicy context resultRank values =
  case located of
    [] -> return Nothing
    _ ->
      if all compatibleAt bases
        then case [candidate | candidate <- candidates,
                             all (candidateMatches candidate) bases] of
               candidate : _ -> return (Just candidate)
               [] -> placementError
        else placementError
  where
    located = [(policy, nativeRank value)
              | value <- values, Just policy <- [nativePolicy value]]
    bases = nativeBases m resultRank
    candidates = nub (targetPolicy : map fst located)
    operandPlacement basis (policy, rank)
      | rank == 0 = componentPlacement m policy []
      | rank == resultRank = componentPlacement m policy basis
      | otherwise = error "mergeNativePlacements: incompatible operand rank"
    compatibleAt basis =
      case map (operandPlacement basis) located of
        [] -> True
        placement : rest -> all (== placement) rest
    candidateMatches candidate basis =
      case map (operandPlacement basis) located of
        [] -> True
        placement : _ -> componentPlacement m candidate basis == placement
    placementError =
      fatal ("grid placement mismatch between operands in native expression: "
             ++ context)

nativeValuesAt
  :: GridPolicy -> Model -> [String] -> [TensorExpr] -> IO (Maybe [NativeValue])
nativeValuesAt _ _ _ [] = return (Just [])
nativeValuesAt targetPolicy m lets (expr : rest) = do
  value <- nativeValueAt targetPolicy m lets expr
  case value of
    Nothing -> return Nothing
    Just value' -> do
      values <- nativeValuesAt targetPolicy m lets rest
      return ((value' :) <$> values)

-- Render the deliberately small whole-tensor subset needed by the standard
-- coordinate operators.  Returning Nothing selects the legacy lowering; this
-- keeps arbitrary user tensor definitions working during the migration.
nativeValueAt
  :: GridPolicy -> Model -> [String] -> TensorExpr -> IO (Maybe NativeValue)
nativeValueAt targetPolicy m lets expr =
  case expr of
    TENumber number -> return (scalar number Nothing False)
    TEIdent base0 parts -> nativeIdent base0 parts
    TEUnary op operand -> do
      value <- nativeValueAt targetPolicy m lets operand
      return (fmap (\v -> v { nativeText = "(" ++ op ++ nativeText v ++ ")" }) value)
    TECall fn args -> nativeScalarApplication True fn args
    TEApply (TEIdent "sharp" []) [operand] -> nativeSharp operand
    TEApply (TEIdent marker []) [operand]
      | marker `elem` map fst nativeMarkerMap -> nativeCoordinate marker operand
    TEApply fn args -> nativeScalarApplication False fn args
    TEIf condition yes no -> do
      values <- nativeValuesAt targetPolicy m lets [condition, yes, no]
      case values of
        Just [conditionValue, yesValue, noValue]
          | nativeRank conditionValue == 0
          , nativeRank yesValue == nativeRank noValue -> do
              policy <- mergeNativePlacements m targetPolicy
                          (renderTensorExpr expr) (nativeRank yesValue)
                          [conditionValue, yesValue, noValue]
              return (Just NativeValue
                { nativeText = "if " ++ nativeText conditionValue
                               ++ " then " ++ nativeText yesValue
                               ++ " else " ++ nativeText noValue
                , nativeRank = nativeRank yesValue
                , nativePolicy = policy
                , nativeOperator = any nativeOperator
                    [conditionValue, yesValue, noValue]
                })
        _ -> return Nothing
    TEBinary op lhs rhs -> nativeBinary op lhs rhs
    TEGroup operand -> do
      value <- nativeValueAt targetPolicy m lets operand
      return (fmap (\v -> v { nativeText = "(" ++ nativeText v ++ ")" }) value)
    _ -> return Nothing
  where
    scalar text policy isNative =
      Just NativeValue
        { nativeText = text
        , nativeRank = 0
        , nativePolicy = policy
        , nativeOperator = isNative
        }

    nativeIdent base0 parts =
      let (fieldName, _) = fieldBaseOf base0
          symbolicParts = all (not . all isDigit . ixName) parts
          localScalars = [sNm step | step <- mSteps m, sk step == KLocal]
      in case kindOf m fieldName of
           Just (Form _) -> return Nothing
           Just kind
             | null parts ->
                 return (Just (fieldValue base0 kind))
             | symbolicParts && length parts == componentRank kind ->
                 return (Just (fieldValue base0 kind))
             | all (all isDigit . ixName) parts
             , length parts == componentRank kind ->
                 -- A fixed component carries a concrete basis that the
                 -- compact NativeValue policy/rank summary cannot represent.
                 -- Preserve exact placement semantics through legacy
                 -- component lowering instead of guessing from basis [].
                 return Nothing
             | otherwise -> return Nothing
           Nothing
             | isLbResultBindingName fieldName && null parts ->
                 return (scalar base0 (Just Collocated) False)
             | fieldName `elem` lets && (null parts || length parts == 1) ->
                 return (Just NativeValue
                   { nativeText = base0
                   , nativeRank = 1
                   , nativePolicy = Just Collocated
                   , nativeOperator = False
                   })
             | fieldName `elem` localScalars && null parts ->
                 return (scalar base0 (Just Collocated) False)
             | null parts -> return (scalar base0 Nothing False)
             | otherwise -> return Nothing
      where
        fieldValue text kind = NativeValue
          { nativeText = text
          , nativeRank = componentRank kind
          , nativePolicy = Just (fieldPolicyOf m (fst (fieldBaseOf text)))
          , nativeOperator = False
          }

    nativeScalarApplication callSyntax fn args = do
      fnValue <- nativeValueAt targetPolicy m lets fn
      argValues <- nativeValuesAt targetPolicy m lets args
      case (fnValue, argValues) of
        (Just functionValue, Just values)
          | nativeRank functionValue == 0
          , all ((== 0) . nativeRank) values -> do
              policy <- mergeNativePlacements m targetPolicy
                          (renderTensorExpr expr) 0 (functionValue : values)
              let renderedArgs = map nativeText values
                  rendered = if callSyntax
                    then nativeText functionValue ++ "("
                         ++ intercalate ", " renderedArgs ++ ")"
                    else unwords (nativeText functionValue :
                                  map parenthesizeNative renderedArgs)
              return (Just NativeValue
                { nativeText = rendered
                , nativeRank = 0
                , nativePolicy = policy
                , nativeOperator = nativeOperator functionValue
                                   || any nativeOperator values
                })
        _ -> return Nothing

    nativeBinary op lhs rhs = do
      values <- nativeValuesAt targetPolicy m lets [lhs, rhs]
      case values of
        Just [lhsValue, rhsValue] ->
          case op of
            "+" -> sameRankBinary lhsValue rhsValue
            "-" -> sameRankBinary lhsValue rhsValue
            "*" -> scalarTensorBinary lhsValue rhsValue
            "/" | nativeRank rhsValue == 0 ->
                    scalarTensorBinary lhsValue rhsValue
            "^" | nativeRank lhsValue == 0 && nativeRank rhsValue == 0 ->
                    sameRankBinary lhsValue rhsValue
            _ | op `elem` ["<", ">", "<=", ">=", "==", "!=", "&&", "||"]
              , nativeRank lhsValue == 0 && nativeRank rhsValue == 0 -> do
                  policy <- mergeNativePlacements m targetPolicy
                              (renderTensorExpr expr) 0 [lhsValue, rhsValue]
                  return (binaryResult 0 policy lhsValue rhsValue)
            _ -> return Nothing
        _ -> return Nothing
      where
        sameRankBinary lhsValue rhsValue
          | nativeRank lhsValue /= nativeRank rhsValue =
              fatal ("native tensor rank mismatch in: " ++ renderTensorExpr expr)
          | otherwise = do
              policy <- mergeNativePlacements m targetPolicy
                          (renderTensorExpr expr) (nativeRank lhsValue)
                          [lhsValue, rhsValue]
              return (binaryResult (nativeRank lhsValue) policy lhsValue rhsValue)
        scalarTensorBinary lhsValue rhsValue
          | nativeRank lhsValue > 0 && nativeRank rhsValue > 0 = return Nothing
          | otherwise = do
              let resultRank = max (nativeRank lhsValue) (nativeRank rhsValue)
              policy <- mergeNativePlacements m targetPolicy
                          (renderTensorExpr expr) resultRank [lhsValue, rhsValue]
              return (binaryResult resultRank
                                    policy lhsValue rhsValue)
        binaryResult rank policy lhsValue rhsValue =
          Just NativeValue
            { nativeText = "(" ++ nativeText lhsValue ++ " " ++ op ++ " "
                           ++ nativeText rhsValue ++ ")"
            , nativeRank = rank
            , nativePolicy = policy
            , nativeOperator = nativeOperator lhsValue || nativeOperator rhsValue
            }

    nativeCoordinate marker operand = do
      operandValue <- nativeValueAt targetPolicy m lets operand
      case operandValue of
        Nothing -> return Nothing
        Just value -> do
          let sourcePolicy = fromMaybe targetPolicy (nativePolicy value)
              (operatorName, inputRank, resultRank, resultPolicy) =
                case marker of
                  _ | marker == nativeGradName ->
                        ("FE.grad", 0, 1, sourcePolicy)
                    | marker == nativeDGradName ->
                        ("FE.dGrad", 1, 2, sourcePolicy)
                    | marker == nativeDivgName ->
                        ("FE.divg", 1, 0, sourcePolicy)
                    | marker == nativeCurlName ->
                        ("FE.curl", 1, 1, flipPolicy sourcePolicy)
                    | marker == nativeLapName ->
                        ("FE.lap", 0, 0, sourcePolicy)
                    | otherwise ->
                        ("FE.hessian", 0, 2, sourcePolicy)
          if nativeRank value /= inputRank
            then fatal (operatorName ++ " expects a rank-" ++ show inputRank
                        ++ " operand in: " ++ renderTensorExpr expr)
            else return (Just NativeValue
              { nativeText = operatorName ++ " (feTensorDerivative "
                             ++ show resultPolicy ++ " " ++ show sourcePolicy
                             ++ ") feAxisIds " ++ parenthesizeNative (nativeText value)
              , nativeRank = resultRank
              , nativePolicy = Just resultPolicy
              , nativeOperator = True
              })

    nativeSharp operand =
      case stripNativeGroup operand of
        TEIdent base0 parts ->
          let (fieldName, primes) = fieldBaseOf base0
          in case kindOf m fieldName of
               Just (Form 1)
                 | null parts ->
                     let policy = fieldPolicyOf m fieldName
                         wrapper = fieldName ++ if primes == 0 then "f" else "fN"
                     in return (Just NativeValue
                          { nativeText = "snd (FE.sharp feMusicalScale " ++ wrapper ++ ")"
                          , nativeRank = 1
                          , nativePolicy = Just policy
                          , nativeOperator = True
                          })
               Just (Form degree) ->
                 fatal ("sharp expects a 1-form, but " ++ fieldName
                        ++ " is a " ++ show degree ++ "-form")
               _ -> fatal ("sharp expects an unindexed 1-form operand in: "
                           ++ renderTensorExpr expr)
        _ -> fatal ("sharp expects an unindexed 1-form operand in: "
                    ++ renderTensorExpr expr)

    stripNativeGroup (TEGroup value) = stripNativeGroup value
    stripNativeGroup value = value

parenthesizeNative :: String -> String
parenthesizeNative value
  | all (\c -> isAlphaNum c || c == '_' || c == '\'') value = value
  | otherwise = "(" ++ value ++ ")"

nativeExpressionAt
  :: GridPolicy -> Model -> [String] -> String -> IO (Maybe NativeValue)
nativeExpressionAt targetPolicy m lets source =
  case parseTensorExprEither source of
    Left message -> fatal ("bad native tensor expression: " ++ message)
    Right expr -> do
      value <- nativeValueAt targetPolicy m lets expr
      return $ case value of
        Just native | nativeOperator native -> Just native
        _ -> Nothing

validateNativeResult :: Model -> GridPolicy -> Kind -> String -> NativeValue -> IO ()
validateNativeResult m targetPolicy targetKind source value = do
  let targetRank = componentRank targetKind
  if nativeRank value == targetRank
    then return ()
    else fatal ("native tensor result has rank " ++ show (nativeRank value)
                ++ " but target has rank " ++ show targetRank ++ " in: " ++ source)
  case nativePolicy value of
    Just policy
      | any (\indices -> componentPlacement m policy indices
                         /= componentPlacement m targetPolicy indices)
            (componentIndices (mDim m) targetKind) ->
      fatal ("grid placement mismatch in indexed equation (native policies): target is "
             ++ gridPolicySurfaceName targetPolicy ++ " but RHS is "
             ++ gridPolicySurfaceName policy ++ " in: " ++ source)
    _ -> return ()


-- ------------------------------------ tensor index equations
--
-- v'~i   = v~i + (dt / rho0) * ∂_j s~i_j
indexDefs :: Model -> [String] -> Step -> IO [String]
indexDefs m lets st = do
  validateFieldRefParts m lets (sNm st ++ concatMap ixSuffix (sIdx st))
  pre <- preprocessTensorExpr m (sEx st)
  ex <- lowerBackendText m pre
  signature <- nativeSignatureExpression (sNm st) (sIdx st) ex
  legacy <- nativeLegacyExpression m signature
  strictEinstein m lets (sIdx st) legacy
  native <- nativeExpressionAt (fieldPolicyOf m (sNm st)) m lets ex
  case (kindOf m (sNm st), native) of
    (Just kind, Just value) -> do
      if "FE.sharp " `isInfixOf` nativeText value
        then validateSharpTarget
        else return ()
      validateNativeResult m (fieldPolicyOf m (sNm st)) kind ex value
      validateComponents kind legacy
      return ["def " ++ base ++ " := " ++ nativeText value]
    _ -> legacyDefs legacy
  where
    base = "feq" ++ sNm st
    legacyDefs ex =
      case (kindOf m (sNm st), sIdx st) of
        (Just Vector, [fi]) -> do
          es <- mapM (\a -> ixExpand m lets [(ixName fi, a)]
                                (componentPlacement m (fieldPolicyOf m (sNm st)) [a]) ex)
                     (axisRange m)
          return ["def " ++ base ++ " := [| " ++ intercalate ", " es ++ " |]"]
        (Just SymM, [fi, fj]) ->
          fmap (++ rank2TensorDef SymM)
            (mapM (\(a, b) -> comp ex [(ixName fi, a), (ixName fj, b)]
                               (componentPlacement m (fieldPolicyOf m (sNm st)) [a, b])
                               (base ++ show a ++ show b))
                  (rank2Pairs (symComponentIndices (mDim m))))
        (Just AntiM, [fi, fj]) ->
          fmap (++ rank2TensorDef AntiM)
            (mapM (\(a, b) -> comp ex [(ixName fi, a), (ixName fj, b)]
                               (componentPlacement m (fieldPolicyOf m (sNm st)) [a, b])
                               (base ++ show a ++ show b))
                  (rank2Pairs (antiComponentIndices (mDim m))))
        (Just Tensor2, [fi, fj]) ->
          fmap (++ rank2TensorDef Tensor2)
            (mapM (\(a, b) -> comp ex [(ixName fi, a), (ixName fj, b)]
                                    (componentPlacement m (fieldPolicyOf m (sNm st)) [a, b])
                                    (base ++ show a ++ show b))
                  (rank2Pairs (componentIndices (mDim m) Tensor2)))
        _ -> fatal ("index equation has wrong indices for its field kind: " ++ sNm st)

    validateComponents kind ex =
      case (kind, sIdx st) of
        (Vector, [fi]) ->
          mapM_ (\a -> ixExpand m lets [(ixName fi, a)]
                           (componentPlacement m (fieldPolicyOf m (sNm st)) [a]) ex
                         >> return ())
                (axisRange m)
        (SymM, [fi, fj]) -> validateRank2 fi fj (symComponentIndices (mDim m)) ex
        (AntiM, [fi, fj]) -> validateRank2 fi fj (antiComponentIndices (mDim m)) ex
        (Tensor2, [fi, fj]) -> validateRank2 fi fj (componentIndices (mDim m) Tensor2) ex
        _ -> fatal ("index equation has wrong indices for its field kind: " ++ sNm st)

    validateRank2 fi fj indices ex =
      mapM_ (\(a, b) -> ixExpand m lets [(ixName fi, a), (ixName fj, b)]
                            (componentPlacement m (fieldPolicyOf m (sNm st)) [a, b]) ex
                          >> return ())
            (rank2Pairs indices)

    comp ex env anchor defnm = do
      e <- ixExpand m lets env anchor ex
      return ("def " ++ defnm ++ " := " ++ e)

    validateSharpTarget =
      case fieldDeclOf m (sNm st) >>= fieldIndexParts of
        Just [IxPart VUp _] -> return ()
        _ -> fatal ("sharp target must be an explicitly contravariant rank-1 vector: "
                    ++ sNm st ++ concatMap ixSuffix (sIdx st))

    rank2TensorDef kind =
      ["def " ++ base ++ " := [| "
       ++ intercalate ", "
            ["[| " ++ intercalate ", "
                [rank2Component kind a b | b <- axisRange m]
             ++ " |]"
            | a <- axisRange m]
       ++ " |]"]

    rank2Component SymM a b =
      base ++ show (min a b) ++ show (max a b)
    rank2Component AntiM a b
      | a == b = "0"
      | a < b = base ++ show a ++ show b
      | otherwise = "0 - " ++ base ++ show b ++ show a
    rank2Component Tensor2 a b = base ++ show a ++ show b
    rank2Component _ _ _ = error "rank2TensorDef: non-rank-2 field"

implicitVectorDefs :: Model -> [String] -> Step -> IO [String]
implicitVectorDefs m lets st = do
  pre <- preprocessTensorExpr m (sEx st)
  ex <- lowerBackendText m pre
  signature <- nativeSignatureExpression (sNm st) [lhsIx] ex
  legacy <- nativeLegacyExpression m signature
  native <- nativeExpressionAt (fieldPolicyOf m (sNm st)) m lets ex
  case native of
    Just value -> do
      if "FE.sharp " `isInfixOf` nativeText value
        then validateSharpTarget
        else return ()
      strictEinstein m lets [lhsIx] legacy
      validateNativeResult m (fieldPolicyOf m (sNm st)) Vector ex value
      mapM_ (validateComp legacy) (axisRange m)
      return ["def feq" ++ sNm st ++ " := " ++ nativeText value]
    Nothing ->
      if hasIndexSyntax m legacy
        then do
          strictEinstein m lets [lhsIx] legacy
          defs <- mapM (comp legacy) (axisRange m)
          return (defs ++ [vectorTensorDef])
        else do
          defs <- mapM scalarComp (axisRange m)
          return (defs ++ [vectorTensorDef])
  where
    lhsIx = IxPart VDown "i"
    comp ex' a = do
      let anchor = componentPlacement m (fieldPolicyOf m (sNm st)) [a]
      e <- ixExpand m lets [(ixName lhsIx, a)] anchor ex'
      return ("def feq" ++ sNm st ++ show a ++ " := " ++ e)
    validateComp ex' a = do
      let anchor = componentPlacement m (fieldPolicyOf m (sNm st)) [a]
      ixExpand m lets [(ixName lhsIx, a)] anchor ex' >> return ()
    vectorTensorDef =
      "def feq" ++ sNm st ++ " := [| "
      ++ intercalate ", " ["feq" ++ sNm st ++ show a | a <- axisRange m]
      ++ " |]"
    validateSharpTarget =
      case fieldDeclOf m (sNm st) >>= fieldIndexParts of
        Just [IxPart VUp _] -> return ()
        _ -> fatal ("sharp target must be an explicitly contravariant rank-1 vector: "
                    ++ sNm st)
    scalarComp a = do
      e <- rewrite m lets (Just (show a)) (sEx st)
      return ("def feq" ++ sNm st ++ show a ++ " := " ++ e)

-- names X whose updated value X' is referenced in some step RHS
primedRefs :: Model -> [String]
primedRefs m = sort (nub [nm | st <- mSteps m, TId nm True <- tokenize (sEx st)
                             , kindOf m nm /= Nothing])

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
        TEApply (TEIdent "flat" []) [operand] ->
          flatValue operand
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

    flatValue operand =
      case stripFormGroup operand of
        TEIdent base0 parts -> do
          validateFieldRefParts m lets (renderTensorExpr (TEIdent base0 parts))
          let (fieldName, _) = fieldBaseOf base0
          case (kindOf m fieldName,
                fieldDeclOf m fieldName >>= fieldIndexParts) of
               (Just Vector, Just [IxPart VUp _])
                 | [IxPart VUp _] <- parts ->
                     return (Just ("FE.flat feMusicalScale ("
                                   ++ show (fieldPolicyOf m fieldName) ++ ", "
                                   ++ base0 ++ ")"))
               (Just Vector, _) ->
                 fatal ("flat expects an explicitly contravariant rank-1 vector: "
                        ++ renderTensorExpr operand)
               _ -> fatal ("flat expects a rank-1 vector operand: "
                           ++ renderTensorExpr operand)
        _ -> fatal ("flat expects a field vector operand: "
                    ++ renderTensorExpr operand)

    stripFormGroup (TEGroup value) = stripFormGroup value
    stripFormGroup value = value

    scalarValue = rewrite m lets Nothing . renderTensorExpr

    formOperator op
      | op `elem` deltaOps =
          "FE.codiffForm feDim feFormDerivative feHodgeCoefficient"
      | op == "hodge" = "FE.hodgeForm feDim feHodgeCoefficient"
      | otherwise = "FE.dForm feDim feFormDerivative"

    parenthesize value
      | all isAlphaNum value = value
      | otherwise = "(" ++ value ++ ")"

formExpressionDegree :: Model -> String -> IO (Maybe Int)
formExpressionDegree m source = do
  pre <- preprocessTensorExpr m source
  expression <- case parseTensorExprEither pre of
    Right parsed -> return parsed
    Left message -> fatal ("bad differential-form expression: " ++ message)
  infer expression
  where
    infer expression =
      case expression of
        TEIdent base [] ->
          let (fieldName, _) = fieldBaseOf base
          in case kindOf m fieldName of
               Just (Form degree) -> return (Just degree)
               _ -> return Nothing
        TEApply (TEIdent "flat" []) [_] -> return (Just 1)
        TEApply (TEIdent operator []) [operand]
          | operator == "d" || operator == "dForm" -> do
              degree <- requireDegree operator operand
              if degree < mDim m
                then return (Just (degree + 1))
                else fatal ("d cannot raise a " ++ show degree ++ "-form in dimension "
                            ++ show (mDim m))
          | operator == "hodge" -> do
              degree <- requireDegree operator operand
              return (Just (mDim m - degree))
          | operator `elem` deltaOps -> do
              degree <- requireDegree operator operand
              if degree > 0
                then return (Just (degree - 1))
                else fatal (operator ++ " cannot lower a 0-form")
        TEUnary _ operand -> infer operand
        TEBinary operator lhs rhs
          | operator == "+" || operator == "-" -> do
              lhsDegree <- infer lhs
              rhsDegree <- infer rhs
              case (lhsDegree, rhsDegree) of
                (Just lhsValue, Just rhsValue)
                  | lhsValue == rhsValue -> return (Just lhsValue)
                  | otherwise -> fatal "cannot add differential forms of different degrees"
                (Nothing, Nothing) -> return Nothing
                _ -> fatal "cannot add a scalar and a differential form"
          | operator == "*" -> do
              lhsDegree <- infer lhs
              rhsDegree <- infer rhs
              case (lhsDegree, rhsDegree) of
                (Just degree, Nothing) -> return (Just degree)
                (Nothing, Just degree) -> return (Just degree)
                (Nothing, Nothing) -> return Nothing
                _ -> fatal "multiplication of two differential forms needs an explicit wedge"
          | operator == "/" -> infer lhs
        TEGroup operand -> infer operand
        _ -> return Nothing
    requireDegree operator operand = do
      degree <- infer operand
      case degree of
        Just value -> return value
        Nothing -> fatal (operator ++ " expects a differential-form operand")

rewriteScalar :: Model -> [String] -> String -> IO String
rewriteScalar = rewriteScalarAt Collocated

rewriteScalarAt :: GridPolicy -> Model -> [String] -> String -> IO String
rewriteScalarAt targetPolicy m lets expr = do
  pre <- preprocessTensorExpr m expr
  lowered <- lowerBackendText m pre
  parsed <- case parseTensorExprEither lowered of
              Right ast -> return ast
              Left msg -> fatal ("bad scalar expression: " ++ msg)
  legacy <- nativeLegacyExpression m lowered
  native <- nativeExpressionAt targetPolicy m lets lowered
  case native of
    Just value -> do
      if hasIndexSyntax m legacy
        then strictEinstein m lets [] legacy
        else return ()
      validateNativeResult m targetPolicy Scalar lowered value
      ixExpand m lets [] (componentPlacement m targetPolicy []) legacy >> return ()
      return (nativeText value)
    Nothing ->
      if hasIndexSyntax m legacy
        then strictEinstein m lets [] legacy
             >> ixExpand m lets [] (componentPlacement m targetPolicy []) legacy
        else do
      let sourcePolicies = nub
            [fieldPolicyOf m fieldName
            | TId tokenName _ <- tokenize lowered
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
        else rewrite m lets Nothing lowered

rewriteScalarInitializerAt :: GridPolicy -> Model -> [String] -> String -> IO String
rewriteScalarInitializerAt targetPolicy m lets expr = do
  pre <- preprocessTensorExpr m expr
  lowered <- lowerBackendText m pre
  legacy <- nativeLegacyExpression m lowered
  native <- nativeExpressionAt targetPolicy m lets lowered
  case native of
    Just value -> do
      if hasIndexSyntax m legacy
        then strictEinstein m lets [] legacy
        else return ()
      validateNativeResult m targetPolicy Scalar lowered value
      ixExpandInitializer m lets [] (componentPlacement m targetPolicy []) legacy
        >> return (nativeText value)
    Nothing ->
      if hasIndexSyntax m legacy
        then strictEinstein m lets [] legacy
             >> ixExpandInitializer m lets [] (componentPlacement m targetPolicy []) legacy
        else rewrite m lets Nothing lowered

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

egiFieldDescriptor :: Model -> FieldDecl -> String
egiFieldDescriptor m field =
  "(" ++ intercalate ", "
    [ show name
    , show (fdPolicy field)
    , egiIntList shape
    , egiStringList variances
    , show layout
    , egiIntLists projection
    , "[" ++ intercalate ", "
        ["(" ++ egiIntList indices ++ ", " ++ show storage ++ ")"
        | (indices, storage) <- zip projection storageNames]
      ++ "]"
    ]
  ++ ")"
  where
    name = fdName field
    kind = fdKind field
    shape = replicate (componentRank kind) (mDim m)
    variances =
      case fieldIndexParts field of
        Just parts | length parts == componentRank kind ->
          map (varianceName . ixVariance) parts
        _ -> replicate (componentRank kind) "down"
    varianceName VUp = "up"
    varianceName VDown = "down"
    layout = case kind of
      Scalar -> "scalar"
      Vector -> "vector"
      SymM -> "symmetric"
      AntiM -> "antisymmetric"
      Tensor2 -> "full"
      Form _ -> "form"
    projection = componentIndices (mDim m) kind
    storageNames = componentStorageNames m name kind

fieldDescriptorIndex :: Model -> String -> Int
fieldDescriptorIndex m name =
  case [index | (index, field) <- zip [1 ..] (mFieldDecls m),
                fdName field == name] of
    index : _ -> index
    [] -> error ("missing field descriptor for " ++ name)

fieldDescriptorRef :: Model -> String -> String
fieldDescriptorRef m name =
  "nth " ++ show (fieldDescriptorIndex m name) ++ " feFieldDescriptors"

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
      -- A primed tensor family is needed only when a later RHS reads it.
      -- Descriptor-driven equation printing no longer needs a synthetic
      -- primed target tensor merely to recover storage names.
      prims = sort (nub (primedRefs m))
  if mMetric m /= Nothing && mEmbed m /= Nothing
    then fatal "declare either 'metric scale' or 'embedding', not both"
    else return ()
  backendPlan <- backendPlanFor m
  let lbPlans = bpLbPlans backendPlan
      usesLb = not (null lbPlans)
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
      tensorDerivativeContextDecls =
            [ "def feTensorDerivative"
            , "      (targetPolicy: GridPolicy) (sourcePolicy: GridPolicy)"
            , "      (targetBasis: [Integer]) (derivativeAxes: [Integer])"
            , "      (sourceBasis: [Integer]) (value: MathValue) : MathValue :="
            , "  FE.gridDerivativeChain dC dC2 dYee derivativeAxes"
            , "    (FE.componentPlacement feDim targetPolicy targetBasis)"
            , "    (FE.componentPlacement feDim sourcePolicy sourceBasis) value"
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
      fieldDescriptorDecls =
        egiListDef "feFieldDescriptors" "" (map (egiFieldDescriptor m) (mFieldDecls m))
      printerContextDecls =
            fieldDescriptorDecls
            ++ [ "def feSymbolNames : [(String, String)] := " ++ egiStringPairs symbolNames
            , "def feFieldNames : [(String, String)] := concat (map FMR.fieldNameMappings feFieldDescriptors)"
            , "def feFieldPolicies : [(String, GridPolicy)] := map (\\(name, policy, _, _, _, _, _) -> (name, policy)) feFieldDescriptors"
            , "def feIndexNames : [String] := " ++ egiStringList internalIndexVars
            , "def fePrinterContext := (feSymbolNames, feFieldNames, feIndexNames, feCoords, feHsteps, feAxisIds)"
            , "def fmrEq : String -> MathValue -> String := FMR.eq fePrinterContext"
            , "def fmrInit : String -> MathValue -> String := FMR.init fePrinterContext"
            , "def componentEqs : [String] -> [MathValue] -> [String] := FMR.componentEqs fePrinterContext"
            , "def fieldEqs descriptor value := FMR.fieldEqs fePrinterContext descriptor value"
            ]
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
  let metricAuxFields = bpMetricAuxFields backendPlan ++ concatMap lpAuxFields lbPlans
      metricStateFields =
        [field | field <- metricAuxFields, afLifetime field == PersistentState]
      metricStepFields =
        [field | field <- metricAuxFields, afLifetime field == StepLocal]
      metricCoeffFields =
        [(axis, field) | field <- metricAuxFields,
                         LbCoefficient axis <- [afRole field]]
      metricVolumeField =
        case [field | field <- metricAuxFields, afRole field == LbVolume] of
          field:_ -> Just field
          [] -> Nothing
      metricCoeffNames = [afName field | (_, field) <- metricCoeffFields]
      metricVolumeName = maybe "sg" afName metricVolumeField
      metricCellPlacement =
        maybe (placeText (componentPlacement m Collocated []))
              (placeText . afPlacement) metricVolumeField
      metricFluxPlacements =
        [placeText (afPlacement field) | (_, field) <- metricCoeffFields]
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
          LbFlux _ _ -> []
      lbFluxFunctionName requestId =
        "feLbFlux" ++ if requestId == 1 then "" else show requestId
      lbStoredFluxName requestId =
        "feLbStoredFlux" ++ if requestId == 1 then "" else show requestId
      mtDecls = [ "def " ++ n ++ " := function (" ++ coordArgs ++ ")"
                | n <- map afName metricAuxFields ]
      mtInits = concatMap renderAuxInit metricAuxFields
      mtFlds = [(afName field, Scalar) | field <- metricStateFields]
      mtFlux =
        [ "[fmrEq \"" ++ afName field ++ "\" ("
          ++ lbFluxFunctionName requestId ++ " "
          ++ show axis ++ ")]"
        | field <- metricStepFields
        , LbFlux requestId axis <- [afRole field]
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
      needsTensorDerivativeContext =
        usesOperationalName ["feTensorDerivative"]
      needsScalarContext =
        "∂ " `isInfixOf` operationalResidualText
        || needsTensorDerivativeContext
        || usesOperationalName ["shift", "dC", "dC2", "dTaylor", "axisId"]
      needsResidualYeeContext =
        usesLb
        || needsTensorDerivativeContext
        || usesOperationalName ["dYee", "yeeRef", "unit3"]
      contextMathDecls =
        (if needsScalarContext then scalarContextDecls else [])
        ++ (if needsFormContext || needsResidualYeeContext then yeeContextDecls else [])
        ++ (if needsTensorDerivativeContext then tensorDerivativeContextDecls else [])
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
      needsMusical =
        "FE.flat " `isInfixOf` operationalResidualText
        || "FE.sharp " `isInfixOf` operationalResidualText
      needsScaleFactors =
        usesLb
        || needsMetricHodge
        || needsMusical
        || (mMetric m /= Nothing
            && any (\(name, _) -> name `elem` scaleMetricFamilies) liveMetricContext)
      scaleFactorDefs = case (mMetric m, mEmbed m) of
        (Just hs, _)
          | needsScaleFactors ->
              [ "def feH (a: Integer) : MathValue := nth a ["
                  ++ intercalate ", " (map (renameAxes m) hs) ++ "]" ]
        (Nothing, Just _)
          | usesLb || needsMetricHodge || needsMusical ->
              [ "def feH (a: Integer) : MathValue := sqrt (feG a a)" ]
        (Nothing, Nothing)
          | needsMusical ->
              [ "def feH (_: Integer) : MathValue := 1" ]
        _ -> []
      needsMetricHodge =
        needsFormContext && (mMetric m /= Nothing || mEmbed m /= Nothing)
      hodgeCoefficientDefs
        | not needsFormContext = []
        | not needsMetricHodge =
            [ "def feHodgeCoefficient (_: GridPolicy) (_: [Integer]) : MathValue := 1" ]
        | otherwise =
            [ "def feHodgeCoefficient (policy: GridPolicy) (basis: [Integer]) : MathValue :="
            , "  let placement := FE.componentPlacement feDim policy basis"
            , "   in substitute"
            , "        (map (\\axis -> (feCoords_axis, feCoords_axis + nth axis placement * feHsteps_axis)) feAxisIds)"
            , "        (FE.orthogonalHodgeCoefficient feAxisIds feH basis)"
            ]
      musicalScaleDefs
        | not needsMusical = []
        | otherwise =
            [ "def feMusicalScale (policy: GridPolicy) (axis: Integer) : MathValue :="
            , "  let placement := FE.componentPlacement feDim policy [axis]"
            , "   in substitute"
            , "        (map (\\a -> (feCoords_a, feCoords_a + nth a placement * feHsteps_a)) feAxisIds)"
            , "        (feH axis)"
            ]
      volumeDefs =
        ["def feSqrtG : MathValue := FE.orthogonalVolume feAxisIds feH" | usesLb]
      lbOperatorDefs
        | not usesLb = []
        | otherwise =
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
          ]
          ++ concatMap renderLbPlan lbPlans
      renderLbPlan plan =
        let requestId = lpRequestId plan
            fluxFunction = lbFluxFunctionName requestId
            storedFlux = lbStoredFluxName requestId
            fluxNames =
              [afName field | field <- lpAuxFields plan,
                              LbFlux _ _ <- [afRole field]]
        in [ "def " ++ fluxFunction ++ " (axis: Integer) : MathValue :="
           , "  FE.lbFlux feLbGradient feLbCoefficient axis " ++ lpSource plan
           , "def " ++ storedFlux ++ " (axis: Integer) : MathValue :="
           , "  nth axis " ++ egiMathList fluxNames
           , "def " ++ lpResultName plan ++ " : MathValue :="
           , "  FE.lbFromFluxes feAxisIds feLbDivergence " ++ storedFlux
               ++ " " ++ metricVolumeName
           ]
      metricDefs = embeddingDefs ++ scaleFactorDefs ++ hodgeCoefficientDefs
                   ++ musicalScaleDefs ++ volumeDefs
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
      generatedHelps = case (mEmbed m, usesLb || needsMetricHodge) of
        (Just _, True)
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
    fdecl (nm, SymM) = canonicalRank2Family nm "" SymM
    fdecl (nm, AntiM) = canonicalRank2Family nm "" AntiM
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
      Just SymM -> canonicalRank2Family nm "'" SymM
      Just AntiM -> canonicalRank2Family nm "'" AntiM
      Just Tensor2 ->
        ["def " ++ nm ++ "' := generateTensor (\\[i, j] -> function (" ++ fieldCoordArgs ++ ")) " ++ shape2]
      Just (Form k) ->
        formFamilyDecl nm "'" k
        ++ [ "def " ++ nm ++ "fN : (GridPolicy, Tensor MathValue) := ("
             ++ show (fieldPolicyOf m nm) ++ ", " ++ formTensorValue nm "'" k ++ ")" ]
      Nothing -> []
    canonicalRank2Family nm primes kind =
      [ "def " ++ raw ++ " := generateTensor (\\[i, j] -> function ("
        ++ fieldCoordArgs ++ ")) " ++ shape2
      , "def " ++ nm ++ primes ++ " := generateTensor (\\[i, j] -> "
        ++ component ++ ") " ++ shape2
      ]
      where
        raw = reservedInternalPrefix ++ "Field" ++ nm
              ++ if null primes then "" else "Next"
        at a b = "FE.tensorComponentAt " ++ raw ++ " [" ++ a ++ ", " ++ b ++ "]"
        component = case kind of
          SymM -> "if i <= j then " ++ at "i" "j" ++ " else " ++ at "j" "i"
          AntiM -> "if i = j then 0 else if i < j then " ++ at "i" "j"
                   ++ " else 0 - " ++ at "j" "i"
          _ -> error "canonicalRank2Family: non-canonical layout"
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
               pre <- preprocessTensorExpr m (sEx st)
               lowered <- lowerBackendText m pre
               signature <- nativeSignatureExpression (sNm st) (sIdx st) lowered
               legacy <- nativeLegacyExpression m signature
               strictEinstein m lets (sIdx st) legacy
               native <- nativeExpressionAt Collocated m lets lowered
               let nm = sNm st
               case native of
                 Just value -> do
                   if "FE.sharp " `isInfixOf` nativeText value
                     then fatal "sharp in an indexed let needs an explicitly contravariant field target"
                     else return ()
                   validateNativeResult m Collocated Vector lowered value
                   case sIdx st of
                     [lhsIx] ->
                       mapM_ (\a -> ixExpand m lets [(ixName lhsIx, a)]
                                          (componentPlacement m Collocated [a]) legacy
                                        >> return ())
                             (axisRange m)
                     _ -> fatal "internal error: indexed let lost its single index"
                   return ["def " ++ nm ++ " := " ++ nativeText value]
                 Nothing -> do
                   e <- rewrite m lets Nothing legacy
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
            in return (Just ("fieldEqs (" ++ fieldDescriptorRef m nm ++ ") ("
                             ++ show (fieldPolicyOf m nm) ++ ", feq" ++ nm ++ ")"))
        | Just SymM <- kindOf m (sNm st) ->
              let nm = sNm st
              in return (Just ("fieldEqs (" ++ fieldDescriptorRef m nm ++ ") ("
                               ++ show (fieldPolicyOf m nm) ++ ", feq" ++ nm ++ ")"))
        | Just AntiM <- kindOf m (sNm st) ->
            let nm = sNm st
            in return (Just ("fieldEqs (" ++ fieldDescriptorRef m nm ++ ") ("
                             ++ show (fieldPolicyOf m nm) ++ ", feq" ++ nm ++ ")"))
        | Just Tensor2 <- kindOf m (sNm st) ->
            let nm = sNm st
            in return (Just ("fieldEqs (" ++ fieldDescriptorRef m nm ++ ") ("
                             ++ show (fieldPolicyOf m nm) ++ ", feq" ++ nm ++ ")"))
        | not (null (sIdx st)) ->
            let nm = sNm st
                names = egiStringList (componentStorageNamesOf m nm)
            in return (Just ("componentEqs " ++ names ++ " "
                             ++ egiMathList ["feq" ++ nm ++ show a
                                            | a <- axisRange m]))
        | kindOf m (sNm st) == Just Vector ->
            let nm = sNm st
            in return (Just ("fieldEqs (" ++ fieldDescriptorRef m nm ++ ") ("
                             ++ show (fieldPolicyOf m nm) ++ ", feq" ++ nm ++ ")"))
        | Just (Form _) <- kindOf m (sNm st) -> do
            inferredDegree <- formExpressionDegree m (sEx st)
            rhs <- rewriteFormValue m lets (sEx st)
            let nm = sNm st
            case (kindOf m nm, inferredDegree) of
              (Just (Form targetDegree), Just rhsDegree)
                | targetDegree /= rhsDegree ->
                    fatal ("form degree mismatch for " ++ nm ++ ": target is "
                           ++ show targetDegree ++ " but RHS is " ++ show rhsDegree)
              _ -> return ()
            return (Just ("fieldEqs (" ++ fieldDescriptorRef m nm ++ ") (" ++ rhs ++ ")"))
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
      legacy <- nativeLegacyExpression m pre
      strictEinstein m lets lhsIx legacy
      case (kindOf m nm, lhsIx) of
        (Just Vector, [fi]) ->
          mapM (\a -> comp legacy [a] [(ixName fi, a)]
                       (componentPlacement m (fieldPolicyOf m nm) [a]))
               (axisRange m)
        (Just SymM, [fi, fj]) ->
          mapM (\(a, b) -> comp legacy [a, b] [(ixName fi, a), (ixName fj, b)]
                         (componentPlacement m (fieldPolicyOf m nm) [a, b]))
               (rank2Pairs (symComponentIndices (mDim m)))
        (Just AntiM, [fi, fj]) ->
          mapM (\(a, b) -> comp legacy [a, b] [(ixName fi, a), (ixName fj, b)]
                         (componentPlacement m (fieldPolicyOf m nm) [a, b]))
               (rank2Pairs (antiComponentIndices (mDim m)))
        (Just Tensor2, [fi, fj]) ->
          mapM (\(a, b) -> comp legacy [a, b] [(ixName fi, a), (ixName fj, b)]
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
      m <- parseFe path name txt
      out <- emit m
      putStr out
    _ -> fatal "usage: fec model.fme > model.egi"
