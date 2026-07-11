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
import Control.Monad (foldM)
import Data.List (dropWhileEnd, intercalate, sort, nub, stripPrefix, isInfixOf, isPrefixOf, isSuffixOf)
import Data.Maybe (fromMaybe)
import System.Environment (getArgs)
import System.IO (hPutStrLn, stderr)

import Formurae.BackendPlan
import Formurae.Common
import Formurae.Index
import Formurae.RuntimeTensor
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
  , pattern TEAppendIndexed
  , pattern TEWithSymbols
  , pattern TEContractWith
  , pattern TETensorMap
  , pattern TESubrefs
  , pattern TETranspose
  , pattern TEDisjoint
  , pattern TEDerivative
  , pattern TEDot
  , expandDefs
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
  [ Def "grad" ["u"] (nativeGradName ++ " u") Nothing
  , Def "dGrad" ["X"] (nativeDGradName ++ " X") Nothing
  , Def "divg" ["X"] (nativeDivgName ++ " X") Nothing
  ]
  ++ [ Def "curl" ["X"] (nativeCurlName ++ " X") Nothing
     | mDim m == 3
     ]
  ++ [ Def "lap" ["u"] (nativeLapName ++ " u") Nothing
     , Def "Δ" ["u"] (nativeLapName ++ " u") Nothing
     , Def "hessian" ["u"] (nativeHessianName ++ " u") Nothing
     ]

-- Definitions used to expand standard coordinate operators into the general
-- TensorExpr runtime bridge when the compact native operator path does not
-- cover the surrounding expression.
runtimeOperatorExpansionDefs :: Model -> [Def]
runtimeOperatorExpansionDefs m =
  [ Def "grad" ["u"] "withSymbols [i] ∂_i u" Nothing
  , Def "dGrad" ["X"] "withSymbols [i, j] ∂_i X_j" Nothing
  , Def "divg" ["X"] "contractWith (+) (∂_i X~i)" Nothing
  ]
  ++ [ Def "curl" ["X"]
         "withSymbols [i, j, k] (epsilon_i~j~k . ∂_j X_k)" Nothing
     | mDim m == 3
     ]
  ++ [ Def "lap" ["u"] "divg (grad u)" Nothing
     , Def "Δ" ["u"] "lap u" Nothing
     , Def "hessian" ["u"] "withSymbols [i, j] ∂_i ∂_j u" Nothing
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
         , "fmrEq", "fmrInit", "componentEqs", "fieldEqs", "fieldInits", "scalarEq"
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
    else Just (Def nm params rhs Nothing)
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
parseFe sourceFile name txt = go STop initialModel
                      [(lineNumber, transliterate raw, raw)
                      | (lineNumber, raw) <- zip [1 :: Int ..] (lines txt)]
  where
    initialModel = Model
      { mName = name
      , mSourcePath = sourceFile
      , mDim = 0
      , mAxes = []
      , mMode = Nothing
      , mMetricName = Nothing
      , mParams = []
      , mHelp = []
      , mFlds = []
      , mFieldDecls = []
      , mInits = []
      , mInitSourceTexts = []
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
                   , mInitSourceTexts = reverse (mInitSourceTexts mDef)
                   , mSteps = steps' }

    go sec m ((ln, raw, originalRaw):rest) = do
      let code = rstrip (stripComment raw)
          originalCode = rstrip (stripComment originalRaw)
          s = strip code
      if null s then go sec m rest else do
        case s of
          "init:" -> go SInit m rest
          "step:" -> go SStep m rest
          _ -> do
            let sec' = if take 1 code /= " " then STop else sec
            case sec' of
              STop -> top ln originalCode s m >>= \m' -> go STop m' rest
              -- an init line may continue over following lines until its
              -- brackets balance (tensor initializers span rows)
              SInit | bal s > 0 ->
                let (more, moreSourceLines, rest') = grab (bal s) rest
                in ini ((ln, originalCode) : moreSourceLines)
                       (s ++ " " ++ more) m
                     >>= \m' -> go SInit m' rest'
              SInit -> ini [(ln, originalCode)] s m >>= \m' -> go SInit m' rest
              SStep -> stp ln originalCode code m >>= \m' -> go SStep m' rest

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

    grab _ [] = ("", [], [])
    grab d ((lineNumber, raw, originalRaw):rest) =
      let t = strip (rstrip (stripComment raw))
          original = rstrip (stripComment originalRaw)
          d' = d + bal t
      in if d' <= 0
           then (t, [(lineNumber, original)], rest)
           else let (more, moreSourceLines, rest') = grab d' rest
                in (t ++ " " ++ more,
                    (lineNumber, original) : moreSourceLines, rest')

    top ln originalLine s m
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
              source <- sourceTextForRhs ln originalLine (defBody df)
              return m { mDefs = df { defSourceText = Just source } : mDefs m }
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
    ini [] _ _ = fatal "internal error: initializer has no source lines"
    ini sourceLines@((ln, _):_) s m
      | Just (nm, ix, ex) <- casForm s = do
          rejectReservedName ln (dropWhileEnd (== '\'') nm)
          if null ix
            then do
              let baseNm = dropWhileEnd (== '\'') nm
              if baseNm /= nm
                then fatal ("CAS initializer target cannot be primed: "
                            ++ nm ++ " (line " ++ show ln ++ ")")
                else return ()
              validateInitTarget baseNm []
              case kindOf m baseNm of
                Just Scalar -> addInit (ICas baseNm ex)
                _ -> fatal ("scalar CAS initializer needs a scalar field: "
                            ++ baseNm ++ " (line " ++ show ln ++ ")")
            else do
              let baseNm = dropWhileEnd (== '\'') nm
              if baseNm /= nm
                then fatal ("indexed CAS initializer target cannot be primed: "
                            ++ nm ++ showIxParts ix ++ " (line " ++ show ln ++ ")")
                else return ()
              validateInitTarget baseNm ix
              if isIndexKind (kindOf m baseNm)
                then addInit (ICasIndex baseNm ix ex)
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
              addInit (ISym nm comps)
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
              addInit (IAnti nm comps)
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
              addInit (ITensor2 nm comps)
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
                  else addInit (IVec nm elems)
            _
              | not (null lhsIx) ->
                  fatal ("indexed initializer needs a [| ... |] literal with matching suffix: "
                         ++ nm ++ showIxParts lhsIx ++ " = [| ... |]"
                         ++ showIxParts lhsIx ++ " (line " ++ show ln ++ ")")
              | otherwise -> addInit (IRaw nm rhs)
      | otherwise = fatal ("bad init: " ++ s ++ " (line " ++ show ln ++ ")")
      where
        addInit value = do
          source <- sourceTextForRhsLines sourceLines (assignmentRhs s)
          return m
            { mInits = value : mInits m
            , mInitSourceTexts = source : mInitSourceTexts m
            }
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
            Nothing ->
              fatal ("initializer refers to unknown field: "
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
    stp ln originalLine s0 m
      | Just bad <- banned =
          fatal (bad ++ " (line " ++ show ln ++ ")")
      | Just (nm, ix, ex) <- eqForm "let" s = do
          rejectReservedName ln nm
          source <- sourceTextForRhs ln originalLine ex
          return m { mSteps = Step KLet nm ix ex source : mSteps m }
      | Just (nm, _, ex) <- eqForm "local" s = do
          rejectReservedName ln nm
          source <- sourceTextForRhs ln originalLine ex
          return m { mSteps = Step KLocal nm [] ex source : mSteps m }
      | Just (nm, ixs, ex) <- primeEqForm s = do
          rejectReservedName ln nm
          source <- sourceTextForRhs ln originalLine ex
          return m { mSteps = Step KEq nm ixs ex source : mSteps m }
      | otherwise = fatal ("bad step eq: " ++ s ++ " (line " ++ show ln ++ ")")
      where
        s = strip s0
        banned = surfaceBanned m [] s

    sourceTextForRhs ln originalLine translatedExpression = do
      sourceTextForRhsLines [(ln, originalLine)] translatedExpression

    sourceTextForRhsLines sourceLines translatedExpression = do
      let pieces = sourcePieces sourceLines
          originalExpression = intercalate "\n" [text | (_, _, text) <- pieces]
          translatedPieces = map translatePiece pieces
          translated = intercalate " " [text | (text, _) <- translatedPieces]
          positions = intercalatePositions pieces translatedPieces
          (firstLine, firstColumn) =
            case pieces of
              (lineNumber, column, _) : _ -> (lineNumber, column)
              [] -> (1, 1)
      if translated == translatedExpression
        then return SourceText
          { sourcePath = sourceFile
          , sourceLine = firstLine
          , sourceColumn = firstColumn
          , sourceOriginal = originalExpression
          , sourceTranslated = translatedExpression
          , sourcePositionMap = positions
          }
        else fatal ("internal source-map transliteration mismatch on line "
                    ++ show firstLine ++ ": " ++ translated ++ " /= "
                    ++ translatedExpression)
      where
        sourcePieces [] = []
        sourcePieces ((lineNumber, originalLine) : rest) =
          (lineNumber, rhsStartColumn originalLine,
           assignmentRhs originalLine)
          : map continuationPiece rest
        continuationPiece (lineNumber, originalLine) =
          let text = strip originalLine
              column = length (takeWhile isSpace originalLine) + 1
          in (lineNumber, column, text)
        translatePiece (lineNumber, column, original) =
          let (translated, offsets) = transliterateWithMap original
          in (translated,
              [SourcePosition lineNumber (column + offset - 1)
              | offset <- offsets])
        intercalatePositions _ [] = []
        intercalatePositions _ [(_, positions)] = positions
        intercalatePositions (_ : nextPiece : restPieces)
                             ((_, positions) : restTranslated) =
          positions ++ [separatorPosition nextPiece]
          ++ intercalatePositions (nextPiece : restPieces) restTranslated
        intercalatePositions _ translatedPieces =
          concatMap snd translatedPieces
        separatorPosition (lineNumber, column, _) =
          SourcePosition lineNumber (max 1 (column - 1))

    assignmentRhs line =
      case break (== '=') line of
        (_, []) -> ""
        (_, _ : rhs) -> strip rhs

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
backendPlanFor m = do
  requests <- collectBackendRequests m
  case requests >>= planBackend m of
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

-- Replace native markers with their tensor definitions and expand them into
-- the general runtime AST.  This is not a component fallback: the result is
-- evaluated as one tensor expression by Egison.
expandRuntimeTensorDefs :: Model -> String -> IO String
expandRuntimeTensorDefs m source =
  expandDefs (runtimeOperatorExpansionDefs m)
    (untok (map replace (tokenize source)))
  where
    replace (TId name primes) =
      case lookup name nativeMarkerMap of
        Just legacyName -> TId legacyName primes
        Nothing -> TId name primes
    replace token = token

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
  :: GridPolicy -> Model -> [RuntimeTensorBinding] -> [TensorExpr]
  -> IO (Maybe [NativeValue])
nativeValuesAt _ _ _ [] = return (Just [])
nativeValuesAt targetPolicy m bindings (expr : rest) = do
  value <- nativeValueAt targetPolicy m bindings expr
  case value of
    Nothing -> return Nothing
    Just value' -> do
      values <- nativeValuesAt targetPolicy m bindings rest
      return ((value' :) <$> values)

-- Render the deliberately small whole-tensor subset needed by the standard
-- coordinate operators.  Returning Nothing selects the general TensorExpr
-- runtime bridge, which preserves arbitrary user tensor definitions.
nativeValueAt
  :: GridPolicy -> Model -> [RuntimeTensorBinding] -> TensorExpr
  -> IO (Maybe NativeValue)
nativeValueAt targetPolicy m bindings expr =
  case expr of
    TENumber number -> return (scalar number Nothing False)
    TEIdent base0 parts -> nativeIdent base0 parts
    TEUnary op operand -> do
      value <- nativeValueAt targetPolicy m bindings operand
      return (fmap (\v -> v { nativeText = "(" ++ op ++ nativeText v ++ ")" }) value)
    TECall fn args -> nativeScalarApplication True fn args
    TEApply (TEIdent "sharp" []) [operand] -> nativeSharp operand
    TEApply (TEIdent marker []) [operand]
      | marker `elem` map fst nativeMarkerMap -> nativeCoordinate marker operand
    TEApply fn args -> nativeScalarApplication False fn args
    TEIf condition yes no -> do
      values <- nativeValuesAt targetPolicy m bindings [condition, yes, no]
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
      value <- nativeValueAt targetPolicy m bindings operand
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
             | symbolicParts && length parts == componentRank kind -> do
                 validateFieldRefParts m bindingNames
                   (renderTensorExpr (TEIdent base0 parts))
                 return (Just (fieldValue base0 kind))
             | all (all isDigit . ixName) parts
             , length parts == componentRank kind ->
                 -- A fixed component carries a concrete basis that the
                 -- compact NativeValue policy/rank summary cannot represent.
                 -- Preserve the concrete basis through the general runtime
                 -- tensor bridge instead of guessing from basis [].
                 return Nothing
             | otherwise -> return Nothing
           Nothing
             | isLbResultBindingName fieldName && null parts ->
                 return (scalar base0 (Just Collocated) False)
             | Just binding <- bindingOf fieldName
             , null parts -> return (Just (bindingValue base0 binding))
             | Just binding <- bindingOf fieldName
             , all (not . all isDigit . ixName) parts
             , length parts == length (runtimeBindingIndices binding) ->
                 if map ixVariance parts
                      == map ixVariance (runtimeBindingIndices binding)
                   then return (Just (bindingValue base0 binding))
                   else fatal ("indexed let " ++ fieldName
                               ++ " is referenced with incompatible index variance: "
                               ++ renderTensorExpr (TEIdent base0 parts))
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
        bindingValue text binding = NativeValue
          { nativeText = text
          , nativeRank = length (runtimeBindingIndices binding)
          , nativePolicy = runtimeBindingPolicy binding
          , nativeOperator = False
          }

    nativeScalarApplication callSyntax fn args = do
      fnValue <- nativeValueAt targetPolicy m bindings fn
      argValues <- nativeValuesAt targetPolicy m bindings args
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
      values <- nativeValuesAt targetPolicy m bindings [lhs, rhs]
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
      operandValue <- nativeValueAt targetPolicy m bindings operand
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

    bindingNames = runtimeTensorBindingNames bindings
    bindingOf name =
      case [binding | binding <- bindings, runtimeBindingName binding == name] of
        binding : _ -> Just binding
        [] -> Nothing

parenthesizeNative :: String -> String
parenthesizeNative value
  | all (\c -> isAlphaNum c || c == '_' || c == '\'') value = value
  | otherwise = "(" ++ value ++ ")"

nativeExpressionAt
  :: GridPolicy -> Model -> [RuntimeTensorBinding] -> String
  -> IO (Maybe NativeValue)
nativeExpressionAt targetPolicy m bindings source =
  case parseTensorExprEither source of
    Left message -> fatal ("bad native tensor expression: " ++ message)
    Right expr -> do
      value <- nativeValueAt targetPolicy m bindings expr
      return $ case value of
        Just native | nativeOperator native -> Just native
        _ -> Nothing

runtimeTensorBindingsFor :: Model -> IO [RuntimeTensorBinding]
runtimeTensorBindingsFor m =
  foldM addBinding []
    [step | step <- mSteps m, sk step == KLet || sk step == KLocal]
  where
    addBinding bindings step = do
      pre <- preprocessTensorExpr m (sEx step)
      lowered <- lowerBackendText m pre
      expression <- case parseTensorExprEither lowered of
                      Right parsed -> return parsed
                      Left message ->
                        fatal ("bad indexed let expression: " ++ message)
      let availableNames = runtimeTensorBindingNames bindings
          unavailable = nub
            [fieldName
            | II tokenName <- itok (renderTensorExpr expression)
            , let (base, _) = parseIndexedIdent tokenName
                  fieldName = fst (fieldBaseOf base)
            , fieldName `elem` runtimeBindingNamesAll
            , fieldName `notElem` availableNames]
      case unavailable of
        name : _ -> fatal ("binding " ++ sNm step
                           ++ " references itself or a later binding: " ++ name)
        [] -> return ()
      native <- nativeValueAt Collocated m bindings expression
      case native of
        Just value
          | nativeRank value /= length (sIdx step) ->
              fatal ("let " ++ sNm step ++ " has tensor rank "
                     ++ show (nativeRank value) ++ " but its declaration has rank "
                     ++ show (length (sIdx step)))
        _ -> return ()
      policy <- if sk step == KLocal
        then return (Just Collocated)
        else case native of
          Just value
            | nativeOperator value
            , Just resultPolicy <- nativePolicy value -> return (Just resultPolicy)
          _ -> inferPolicy (length (sIdx step)) bindings expression
      return (bindings ++ [RuntimeTensorBinding
        { runtimeBindingName = sNm step
        , runtimeBindingIndices = sIdx step
        , runtimeBindingPolicy = policy
        }])

    inferPolicy bindingRank bindings expression =
      case kindForBindingRank bindingRank of
        Nothing -> fatal ("let tensor rank is not supported: "
                          ++ show bindingRank)
        Just targetKind ->
          case inferRuntimeExpressionPolicy m bindings
                 (syntheticIndices bindingRank) targetKind expression of
            Right policy -> return policy
            Left message -> fatal message

    kindForBindingRank 0 = Just Scalar
    kindForBindingRank 1 = Just Vector
    kindForBindingRank 2 = Just Tensor2
    kindForBindingRank _ = Nothing
    syntheticIndices rank =
      [IxPart VDown name | name <- take rank (internalIndexNames m)]

    runtimeBindingNamesAll =
      [sNm step | step <- mSteps m, sk step == KLet || sk step == KLocal]

runtimeBindingReferences :: [String] -> String -> [String]
runtimeBindingReferences bindingNames source = nub
  [fieldName
  | II tokenName <- itok source
  , let (base, _) = parseIndexedIdent tokenName
        fieldName = fst (fieldBaseOf base)
  , fieldName `elem` bindingNames]

scopeRuntimeBindings
  :: [RuntimeTensorBinding] -> [Step]
  -> [([RuntimeTensorBinding], [RuntimeTensorBinding], Step)]
scopeRuntimeBindings allBindings = go []
  where
    go _ [] = []
    go available (step : steps) =
      let current = case [binding | binding <- allBindings,
                                  runtimeBindingName binding == sNm step,
                                  sk step == KLet || sk step == KLocal] of
                      binding : _ -> [binding]
                      [] -> []
          after = available ++ current
      in (available, after, step) : go after steps

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

validateRuntimeTensorResult
  :: Model -> [RuntimeTensorBinding] -> GridPolicy -> [IxPart] -> Kind
  -> TensorExpr -> IO ()
validateRuntimeTensorResult
    m bindings targetPolicy targetIndices targetKind expression = do
  native <- nativeValueAt targetPolicy m bindings expression
  case native of
    Just value ->
      validateNativeResult m targetPolicy targetKind
        (renderTensorExpr expression) value
    Nothing ->
      if runtimeTensorPlacementMatches
           m bindings targetPolicy targetIndices targetKind expression
        then return ()
        else fatal ("grid placement mismatch in runtime tensor expression: target is "
                    ++ gridPolicySurfaceName targetPolicy ++ " in: "
                    ++ renderTensorExpr expression)

runtimeTensorPlacementMatches
  :: Model -> [RuntimeTensorBinding] -> GridPolicy -> [IxPart] -> Kind
  -> TensorExpr -> Bool
runtimeTensorPlacementMatches
    m bindings targetPolicy targetIndices targetKind expression =
  all validateBasis targetBases
  where
    targetRank = componentRank targetKind
    targetBases = nativeBases m targetRank
    targetNames = map ixName targetIndices
    expressionNames = nub (collectIndexNames expression)

    validateBasis targetBasis =
      all (validateEnvironment targetBasis)
        (extendEnvironments (zip targetNames targetBasis)
          [name | name <- expressionNames, name `notElem` targetNames])

    validateEnvironment targetBasis environment =
      let expected = componentPlacement m targetPolicy targetBasis
          actual = expressionPlacements targetBasis environment [] expression
      in all (== expected) actual

    extendEnvironments environment [] = [environment]
    extendEnvironments environment (name : names) =
      concat
        [extendEnvironments ((name, axis) : environment) names
        | axis <- axisRange m]

    expressionPlacements targetBasis environment aliases expr =
      case expr of
        TENumber _ -> []
        TEIdent base parts -> referencePlacements targetBasis environment aliases base parts
        TEUnary _ body -> expressionPlacements targetBasis environment aliases body
        TECall function arguments ->
          concatMap (expressionPlacements targetBasis environment aliases)
            (function : arguments)
        TEApply (TEIdent function functionParts) [body]
          | Just (order, _, part) <-
              derivativeOpParts (function ++ concatMap ixSuffix functionParts) ->
              coordinateDerivativePlacements
                targetBasis environment aliases order part body
        TEApply (TEIdent marker []) [_]
          | marker `elem` map fst nativeMarkerMap -> []
        TEApply function arguments ->
          concatMap (expressionPlacements targetBasis environment aliases)
            (function : arguments)
        TEIf condition yes no ->
          concatMap (expressionPlacements targetBasis environment aliases)
            [condition, yes, no]
        TEAppendIndexed (TEIdent base existing) parts ->
          referencePlacements targetBasis environment aliases base (existing ++ parts)
        TEAppendIndexed body _ ->
          expressionPlacements targetBasis environment aliases body
        TEWithSymbols names body ->
          let localAliases = zip names targetNames
                ++ [(name, replacement) | (name, replacement) <- aliases,
                                           name `notElem` names]
          in expressionPlacements targetBasis environment localAliases body
        TEContractWith _ body
          | isZeroExpression environment aliases body -> []
          | otherwise -> expressionPlacements targetBasis environment aliases body
        TETensorMap function body ->
          expressionPlacements targetBasis environment aliases function
          ++ materializedPlacements targetBasis environment aliases body
        TESubrefs (TEIdent base existing) parts ->
          referencePlacements targetBasis environment aliases base (existing ++ parts)
        TESubrefs body _ ->
          expressionPlacements targetBasis environment aliases body
        TETranspose names (TEIdent base parts)
          | null parts ->
              let variances = declaredVariances base (length names)
              in referencePlacements targetBasis environment aliases base
                   [IxPart variance name
                   | (variance, name) <- zip variances names]
        TETranspose _ body ->
          materializedPlacements targetBasis environment aliases body
        TEDisjoint parts
          | any (isZeroExpression environment aliases) parts -> []
          | otherwise ->
              concatMap (expressionPlacements targetBasis environment aliases) parts
        TEDerivative parts body ->
          indexedDerivativePlacements targetBasis environment aliases parts body
        TEDot parts
          | any (isZeroExpression environment aliases) parts -> []
          | otherwise ->
              concatMap (expressionPlacements targetBasis environment aliases) parts
        TEBinary op lhs rhs
          | op == "*"
          , isZeroExpression environment aliases lhs
            || isZeroExpression environment aliases rhs -> []
          | otherwise ->
              expressionPlacements targetBasis environment aliases lhs
              ++ expressionPlacements targetBasis environment aliases rhs
        TEGroup body -> expressionPlacements targetBasis environment aliases body

    materializedPlacements targetBasis environment aliases expr =
      case expr of
        TEGroup body -> materializedPlacements targetBasis environment aliases body
        TEIdent base [] ->
          let rank = referenceRank base
              variances = declaredVariances base rank
              names = take rank targetNames
          in referencePlacements targetBasis environment aliases base
               [IxPart variance name
               | (variance, name) <- zip variances names]
        TEUnary _ body -> materializedPlacements targetBasis environment aliases body
        TEBinary _ lhs rhs ->
          materializedPlacements targetBasis environment aliases lhs
          ++ materializedPlacements targetBasis environment aliases rhs
        TEIf condition yes no ->
          expressionPlacements targetBasis environment aliases condition
          ++ materializedPlacements targetBasis environment aliases yes
          ++ materializedPlacements targetBasis environment aliases no
        _ -> expressionPlacements targetBasis environment aliases expr

    indexedDerivativePlacements targetBasis environment aliases parts body =
      let (allDerivativeParts, source) = flattenDerivativeParts parts body
      in derivativeSourcePlacement targetBasis environment aliases
           False allDerivativeParts source

    coordinateDerivativePlacements
        targetBasis environment aliases order part body =
      case lookup (ixName part) (zip (internalCoordNames m) (axisRange m)) of
        Just axis -> derivativeSourcePlacement targetBasis environment aliases
          True (replicate order (IxPart (ixVariance part) (show axis))) body
        Nothing -> derivativeSourcePlacement targetBasis environment aliases
          True (replicate order part) body

    derivativeSourcePlacement
        targetBasis environment aliases targetAnchored derivativeParts source =
      if targetAnchored
        then coordinateResult sourcePlacements
        else indexedResult sourcePlacements
      where
        sourcePlacements =
          case stripRuntimeGroup source of
            TEIdent base sourceParts ->
              locatedReferencePlacement environment aliases base sourceParts
            TEAppendIndexed (TEIdent base existing) appended ->
              locatedReferencePlacement environment aliases base
                (existing ++ appended)
            _ -> expressionPlacements targetBasis environment aliases source
        coordinateResult [] = []
        coordinateResult placements@(placement : rest)
          | all (== placement) rest =
              [componentPlacement m targetPolicy targetBasis]
          | otherwise = placements
        indexedResult placements =
          case mapM (resolvePart environment aliases) derivativeParts of
            Just axes -> map (applyDerivativeAxes axes) placements
            Nothing -> placements
        applyDerivativeAxes axes placement =
          foldl (flip toggleIndexedPlacement) placement axes
        toggleIndexedPlacement _ placement@(Placement _ _ Collocated) = placement
        toggleIndexedPlacement axis (Placement bits placementText policy) =
          Placement
            [if current == axis then not bit else bit
            | (current, bit) <- zip (axisRange m) bits]
            placementText policy

    flattenDerivativeParts parts (TEDerivative more body) =
      flattenDerivativeParts (parts ++ more) body
    flattenDerivativeParts parts body = (parts, body)

    stripRuntimeGroup (TEGroup body) = stripRuntimeGroup body
    stripRuntimeGroup body = body

    referencePlacements _targetBasis environment aliases base parts
      | null parts, referenceRank base > 0 =
          let rank = referenceRank base
              variances = declaredVariances base rank
          in locatedReferencePlacement environment aliases base
               [IxPart variance name
               | (variance, name) <- zip variances (take rank targetNames)]
      | otherwise = locatedReferencePlacement environment aliases base parts

    locatedReferencePlacement environment aliases base parts =
      if isRuntimeMetricReference base parts
        then []
        else case referencePolicy base of
          Nothing -> []
          Just policy ->
            case mapM (resolvePart environment aliases) parts of
              Just basis -> [componentPlacement m policy basis]
              Nothing -> []

    isRuntimeMetricReference base parts =
      length parts == 2
      && let fieldName = fst (fieldBaseOf base)
         in fieldName == metricPreludeName || Just fieldName == mMetricName m

    resolvePart environment aliases (IxPart _ name)
      | all isDigit name = case reads name of
          [(axis, "")] -> Just axis
          _ -> Nothing
      | otherwise = lookup (renameAlias aliases name) environment

    isZeroExpression environment aliases expr =
      case expr of
        TENumber number ->
          case reads number :: [(Double, String)] of
            [(value, "")] -> value == 0
            _ -> False
        TEIdent base parts -> zeroReference base parts
        TEUnary _ body -> isZeroExpression environment aliases body
        TEIf _ yes no ->
          isZeroExpression environment aliases yes
          && isZeroExpression environment aliases no
        TEAppendIndexed (TEIdent base existing) parts ->
          zeroReference base (existing ++ parts)
        TEAppendIndexed body _ -> isZeroExpression environment aliases body
        TEWithSymbols _ body -> isZeroExpression environment aliases body
        TEContractWith reducer body
          | reducer == "+" || reducer == "*" ->
              isZeroExpression environment aliases body
          | otherwise -> False
        TETensorMap _ _ -> False
        TESubrefs body _ -> isZeroExpression environment aliases body
        TETranspose _ body -> isZeroExpression environment aliases body
        TEDisjoint parts -> any (isZeroExpression environment aliases) parts
        TEDerivative _ body -> isZeroExpression environment aliases body
        TEDot parts -> any (isZeroExpression environment aliases) parts
        TEBinary op lhs rhs
          | op == "*" -> isZeroExpression environment aliases lhs
                         || isZeroExpression environment aliases rhs
          | op == "/" -> isZeroExpression environment aliases lhs
          | op == "+" || op == "-" ->
              isZeroExpression environment aliases lhs
              && isZeroExpression environment aliases rhs
        TEGroup body -> isZeroExpression environment aliases body
        _ -> False
      where
        zeroReference base parts =
          case mapM (resolvePart environment aliases) parts of
            Just basis
              | isDiagonalMetric (fst (fieldBaseOf base))
              , [first, second] <- basis -> first /= second
              | fst (fieldBaseOf base) == "epsilon" ->
                  length basis /= length (nub basis)
              | kindOf m (fst (fieldBaseOf base)) == Just AntiM
              , [first, second] <- basis -> first == second
            _ -> False
        isDiagonalMetric fieldName =
          fieldName == "delta"
          || fieldName == metricPreludeName
          || Just fieldName == mMetricName m

    renameAlias aliases name =
      case lookup name aliases of
        Just replacement -> replacement
        Nothing -> name

    referencePolicy base =
      let fieldName = fst (fieldBaseOf base)
      in case kindOf m fieldName of
           Just _ -> Just (fieldPolicyOf m fieldName)
           Nothing -> case [runtimeBindingPolicy binding
                           | binding <- bindings,
                             runtimeBindingName binding == fieldName] of
             policy : _ -> policy
             [] -> Nothing

    referenceRank base =
      let fieldName = fst (fieldBaseOf base)
      in case kindOf m fieldName of
           Just kind -> componentRank kind
           Nothing -> case [length (runtimeBindingIndices binding)
                           | binding <- bindings,
                             runtimeBindingName binding == fieldName] of
             rank : _ -> rank
             [] -> 0

    declaredVariances base rank =
      let fieldName = fst (fieldBaseOf base)
      in case fieldDeclOf m fieldName >>= fieldIndexParts of
           Just parts | length parts == rank -> map ixVariance parts
           _ -> case [map ixVariance (runtimeBindingIndices binding)
                     | binding <- bindings,
                       runtimeBindingName binding == fieldName] of
             variances : _ | length variances == rank -> variances
             _ -> replicate rank VDown

    collectIndexNames expr =
      filter isSymbolicName $ case expr of
        TENumber _ -> []
        TEIdent _ parts -> map ixName parts
        TEUnary _ body -> collectIndexNames body
        TECall function arguments ->
          concatMap collectIndexNames (function : arguments)
        TEApply function arguments ->
          concatMap collectIndexNames (function : arguments)
        TEIf condition yes no ->
          concatMap collectIndexNames [condition, yes, no]
        TEAppendIndexed body parts ->
          collectIndexNames body ++ map ixName parts
        TEWithSymbols names body -> names ++ collectIndexNames body
        TEContractWith _ body -> collectIndexNames body
        TETensorMap function body ->
          collectIndexNames function ++ collectIndexNames body
        TESubrefs body parts -> collectIndexNames body ++ map ixName parts
        TETranspose names body -> names ++ collectIndexNames body
        TEDisjoint parts -> concatMap collectIndexNames parts
        TEDerivative parts body -> map ixName parts ++ collectIndexNames body
        TEDot parts -> concatMap collectIndexNames parts
        TEBinary _ lhs rhs -> collectIndexNames lhs ++ collectIndexNames rhs
        TEGroup body -> collectIndexNames body

    isSymbolicName name =
      not (null name)
      && not (all isDigit name)
      && name `notElem` internalCoordNames m

runtimePolicyCandidates
  :: Model -> [RuntimeTensorBinding] -> [IxPart] -> Kind -> TensorExpr
  -> [GridPolicy]
runtimePolicyCandidates m bindings indices kind expression =
  [policy
  | policy <- [Collocated, Primal, Dual]
  , runtimeTensorPlacementMatches m bindings policy indices kind expression]

inferRuntimeExpressionPolicy
  :: Model -> [RuntimeTensorBinding] -> [IxPart] -> Kind -> TensorExpr
  -> Either String (Maybe GridPolicy)
inferRuntimeExpressionPolicy m bindings indices kind expression =
  let candidates = runtimePolicyCandidates m bindings indices kind expression
      referenced = nub (runtimeReferencedPolicies m bindings expression)
  in case candidates of
       [] -> Left ("grid placement mismatch in expression: "
                   ++ renderTensorExpr expression)
       [policy] -> Right (Just policy)
       _ | null referenced -> Right Nothing
         | [policy] <- referenced, policy `elem` candidates -> Right (Just policy)
         | otherwise -> Left ("ambiguous grid policy in expression: "
                              ++ renderTensorExpr expression)

runtimeReferencedPolicies
  :: Model -> [RuntimeTensorBinding] -> TensorExpr -> [GridPolicy]
runtimeReferencedPolicies m bindings expression =
  case expression of
    TENumber _ -> []
    TEIdent base parts ->
      let fieldName = fst (fieldBaseOf base)
      in if length parts == 2
            && (fieldName == metricPreludeName || Just fieldName == mMetricName m)
           then []
           else case kindOf m fieldName of
             Just _ -> [fieldPolicyOf m fieldName]
             Nothing ->
               [policy
               | binding <- bindings
               , runtimeBindingName binding == fieldName
               , Just policy <- [runtimeBindingPolicy binding]]
    TEUnary _ body -> runtimeReferencedPolicies m bindings body
    TECall function arguments ->
      concatMap (runtimeReferencedPolicies m bindings) (function : arguments)
    TEApply function arguments ->
      concatMap (runtimeReferencedPolicies m bindings) (function : arguments)
    TEIf condition yes no ->
      concatMap (runtimeReferencedPolicies m bindings) [condition, yes, no]
    TEAppendIndexed body _ -> runtimeReferencedPolicies m bindings body
    TEWithSymbols _ body -> runtimeReferencedPolicies m bindings body
    TEContractWith _ body -> runtimeReferencedPolicies m bindings body
    TETensorMap function body ->
      runtimeReferencedPolicies m bindings function
      ++ runtimeReferencedPolicies m bindings body
    TESubrefs body _ -> runtimeReferencedPolicies m bindings body
    TETranspose _ body -> runtimeReferencedPolicies m bindings body
    TEDisjoint parts -> concatMap (runtimeReferencedPolicies m bindings) parts
    TEDerivative _ body -> runtimeReferencedPolicies m bindings body
    TEDot parts -> concatMap (runtimeReferencedPolicies m bindings) parts
    TEBinary _ lhs rhs ->
      runtimeReferencedPolicies m bindings lhs
      ++ runtimeReferencedPolicies m bindings rhs
    TEGroup body -> runtimeReferencedPolicies m bindings body

checkedNativeTensor :: Model -> String -> [IxPart] -> String -> String
checkedNativeTensor m target indices source =
  let safeIndices = hygienicIndexParts indices
  in renderCheckedRuntimeTensor m target safeIndices RuntimeTensorExpr
    { runtimeTensorText = "(" ++ source ++ ")" ++ concatMap ixSuffix safeIndices
    , runtimeTensorSymbols = nub
        [ixName index | index <- safeIndices, not (all isDigit (ixName index))]
    }


-- ------------------------------------ tensor index equations
--
-- v'~i   = v~i + (dt / rho0) * ∂_j s~i_j
indexDefs :: Model -> [RuntimeTensorBinding] -> Step -> IO [String]
indexDefs m bindings st = do
  validateFieldRefParts m lets (sNm st ++ concatMap ixSuffix (sIdx st))
  pre <- preprocessTensorExpr m (sEx st)
  ex <- lowerBackendText m pre
  nativeCandidate <- nativeExpressionAt (fieldPolicyOf m (sNm st)) m bindings ex
  expression <- case parseTensorExprEither ex of
                  Right parsed -> return parsed
                  Left message -> fatal ("bad indexed tensor expression: " ++ message)
  let native =
        if nativeResultIndicesSafe (map fst nativeMarkerMap) m bindings (sIdx st) expression
          then nativeCandidate
          else Nothing
  case (kindOf m (sNm st), native) of
    (Just kind, Just value) -> do
      if "FE.sharp " `isInfixOf` nativeText value
        then validateSharpTarget
        else return ()
      validateNativeResult m (fieldPolicyOf m (sNm st)) kind ex value
      return ["def " ++ base ++ " := "
              ++ checkedNativeTensor m (sNm st) (sIdx st) (nativeText value)]
    _ -> do
      expanded <- expandRuntimeTensorDefs m ex
      runtimeDefs expanded
  where
    lets = runtimeIndexedBindingNames bindings
    base = "feq" ++ sNm st
    runtimeDefs source =
      case parseTensorExprEither source of
        Left message -> fatal ("bad indexed tensor expression: " ++ message)
        Right expression -> do
          (targetBasisName, rendered) <- renderWithFreshTargetBasis expression 0
          case rendered of
            Left message -> fatal ("cannot lower indexed equation for "
                                   ++ sNm st ++ " in Egison: " ++ message)
            Right runtime -> do
              validateRuntimeEinstein m bindings (sIdx st) expression
              case kindOf m (sNm st) of
                Just kind -> validateRuntimeTensorResult m bindings
                  (fieldPolicyOf m (sNm st)) (sIdx st) kind expression
                Nothing -> return ()
              let checked = renderCheckedRuntimeTensor m (sNm st) (sIdx st) runtime
                  atName = reservedInternalPrefix ++ "EquationAt" ++ sNm st
                  shape = replicate (length (sIdx st)) (mDim m)
              return
                [ "def " ++ atName
                  ++ " (" ++ targetBasisName
                  ++ ": [Integer]) : Tensor MathValue := "
                  ++ checked
                , "def " ++ base
                  ++ " := generateTensor (\\" ++ targetBasisName ++ " -> "
                  ++ "FE.tensorComponentAt (" ++ atName
                  ++ " " ++ targetBasisName ++ ") " ++ targetBasisName
                  ++ ") " ++ show shape
                ]

    renderWithFreshTargetBasis
      :: TensorExpr -> Int -> IO (String, Either String RuntimeTensorExpr)
    renderWithFreshTargetBasis expression suffix = do
      let candidate = reservedInternalPrefix ++ "TargetBasis"
                      ++ if suffix == 0 then "" else show suffix
      rendered <- renderRuntimeTensorExpr
        m bindings (fieldPolicyOf m (sNm st)) (sIdx st) candidate expression
      case rendered of
        Right runtime | candidate `elem` runtimeTensorSymbols runtime ->
          renderWithFreshTargetBasis expression (suffix + 1)
        _ -> return (candidate, rendered)

    validateSharpTarget =
      case fieldDeclOf m (sNm st) >>= fieldIndexParts of
        Just [IxPart VUp _] -> return ()
        _ -> fatal ("sharp target must be an explicitly contravariant rank-1 vector: "
                    ++ sNm st ++ concatMap ixSuffix (sIdx st))

implicitVectorDefs :: Model -> [RuntimeTensorBinding] -> Step -> IO [String]
implicitVectorDefs m bindings st = do
  pre <- preprocessTensorExpr m (sEx st)
  ex <- lowerBackendText m pre
  expression <- case parseTensorExprEither ex of
    Right parsed -> return parsed
    Left message -> fatal ("bad implicit vector expression: " ++ message)
  nativeCandidate <- nativeExpressionAt
    (fieldPolicyOf m (sNm st)) m bindings ex
  let native =
        if nativeResultIndicesSafe (map fst nativeMarkerMap)
             m bindings [lhsIx] expression
          then nativeCandidate
          else Nothing
  case native of
    Just value -> do
      if "FE.sharp " `isInfixOf` nativeText value
        then validateSharpTarget
        else return ()
      validateNativeResult m (fieldPolicyOf m (sNm st)) Vector ex value
      return ["def feq" ++ sNm st ++ " := "
              ++ checkedNativeTensor m (sNm st) [lhsIx] (nativeText value)]
    Nothing -> do
      expanded <- expandRuntimeTensorDefs m ex
      runtimeExpression <- case parseTensorExprEither expanded of
        Right parsed -> return parsed
        Left message -> fatal ("bad implicit vector expression: " ++ message)
      let targetBasis = reservedInternalPrefix ++ "TargetBasis"
      rendered <- renderRuntimeTensorExpr m bindings
        (fieldPolicyOf m (sNm st)) [lhsIx] targetBasis runtimeExpression
      runtime <- case rendered of
        Right result -> return result
        Left message -> fatal ("cannot lower implicit vector equation for "
                               ++ sNm st ++ " in Egison: " ++ message)
      validateRuntimeEinstein m bindings [lhsIx] runtimeExpression
      validateRuntimeTensorResult m bindings
        (fieldPolicyOf m (sNm st)) [lhsIx] Vector runtimeExpression
      let atName = reservedInternalPrefix ++ "EquationAt" ++ sNm st
          checked = renderCheckedRuntimeTensor m (sNm st) [lhsIx] runtime
      return
        [ "def " ++ atName ++ " (" ++ targetBasis
          ++ ": [Integer]) : Tensor MathValue := " ++ checked
        , "def feq" ++ sNm st ++ " := generateTensor (\\" ++ targetBasis
          ++ " -> FE.tensorComponentAt (" ++ atName ++ " " ++ targetBasis
          ++ ") " ++ targetBasis ++ ") [" ++ show (mDim m) ++ "]"
        ]
  where
    lhsIx = case fieldDeclOf m (sNm st) >>= fieldIndexParts of
      Just [IxPart variance _] -> IxPart variance "i"
      _ -> IxPart VDown "i"
    validateSharpTarget =
      case fieldDeclOf m (sNm st) >>= fieldIndexParts of
        Just [IxPart VUp _] -> return ()
        _ -> fatal ("sharp target must be an explicitly contravariant rank-1 vector: "
                    ++ sNm st)

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

rewriteScalar :: Model -> [RuntimeTensorBinding] -> String -> IO String
rewriteScalar = rewriteScalarAt Collocated

rewriteScalarAt
  :: GridPolicy -> Model -> [RuntimeTensorBinding] -> String -> IO String
rewriteScalarAt targetPolicy m bindings expr = do
  pre <- preprocessTensorExpr m expr
  lowered <- lowerBackendText m pre
  native <- nativeExpressionAt targetPolicy m bindings lowered
  case native of
    Just value -> do
      validateNativeResult m targetPolicy Scalar lowered value
      return (nativeText value)
    Nothing -> do
      parsed <- case parseTensorExprEither lowered of
                  Right ast -> return ast
                  Left msg -> fatal ("bad scalar expression: " ++ msg)
      expanded <- expandRuntimeTensorDefs m lowered
      if hasIndexSyntax m lets expanded
        then do
          runtimeExpression <- case parseTensorExprEither expanded of
            Right parsedExpression -> return parsedExpression
            Left message -> fatal ("bad indexed scalar expression: " ++ message)
          validateRuntimeEinstein m bindings [] runtimeExpression
          rendered <- renderRuntimeTensorExpr
            m bindings targetPolicy [] "[]" runtimeExpression
          case rendered of
            Right runtime -> do
              validateRuntimeTensorResult m bindings targetPolicy [] Scalar
                runtimeExpression
              return (renderRuntimeScalar runtime)
            Left message -> fatal ("cannot lower indexed scalar expression in Egison: "
                                   ++ message)
        else do
          validateScalarResult True targetPolicy m bindings parsed expr
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
  where
    lets = runtimeIndexedBindingNames bindings

rewriteScalarInitializerAt
  :: GridPolicy -> Model -> [RuntimeTensorBinding] -> String
  -> IO (Maybe GridPolicy, String)
rewriteScalarInitializerAt targetPolicy m bindings expr = do
  pre <- preprocessTensorExpr m expr
  lowered <- lowerBackendText m pre
  native <- nativeExpressionAt targetPolicy m bindings lowered
  case native of
    Just value -> do
      if nativeRank value == 0
        then return (nativePolicy value, nativeText value)
        else fatal ("scalar initializer has a tensor-valued result: " ++ expr)
    Nothing -> do
      expanded <- expandRuntimeTensorDefs m lowered
      if hasIndexSyntax m lets expanded
        then do
          runtimeExpression <- case parseTensorExprEither expanded of
            Right parsed -> return parsed
            Left message -> fatal ("bad scalar initializer: " ++ message)
          validateRuntimeEinstein m bindings [] runtimeExpression
          rhsPolicy <- case inferRuntimeExpressionPolicy
                             m bindings [] Scalar runtimeExpression of
            Right inferred -> return inferred
            Left message -> fatal message
          rendered <- renderRuntimeTensorExpr
            m bindings (fromMaybe targetPolicy rhsPolicy) [] "[]" runtimeExpression
          case rendered of
            Right runtime -> return (rhsPolicy, renderRuntimeScalar runtime)
            Left message -> fatal ("cannot lower scalar initializer in Egison: "
                                   ++ message)
        else do
          parsed <- case parseTensorExprEither lowered of
                      Right ast -> return ast
                      Left msg -> fatal ("bad scalar initializer: " ++ msg)
          validateScalarResult False targetPolicy m bindings parsed expr
          rhsPolicy <- case inferRuntimeExpressionPolicy
                             m bindings [] Scalar parsed of
            Right inferred -> return inferred
            Left message -> fatal message
          rewritten <- rewrite m lets Nothing lowered
          return (rhsPolicy, rewritten)
  where
    lets = runtimeIndexedBindingNames bindings

validateScalarResult
  :: Bool -> GridPolicy -> Model -> [RuntimeTensorBinding]
  -> TensorExpr -> String -> IO ()
validateScalarResult checkPolicy targetPolicy m bindings expression source = do
  value <- nativeValueAt targetPolicy m bindings expression
  case value of
    Just result ->
      if nativeRank result /= 0
        then tensorError
        else if checkPolicy
               then validateNativeResult m targetPolicy Scalar source result
               else return ()
    Nothing
      | definitelyTensor expression -> tensorError
    _ -> return ()
  where
    tensorError = fatal ("scalar expression has a tensor-valued result: " ++ source)

    definitelyTensor expr =
      case expr of
        TEIdent base [] ->
          case kindOf m (fst (fieldBaseOf base)) of
            Just kind -> componentRank kind > 0
            Nothing ->
              case [runtimeBindingIndices binding
                   | binding <- bindings,
                     runtimeBindingName binding == fst (fieldBaseOf base)] of
                indices : _ -> not (null indices)
                [] -> False
        TEIdent _ (_ : _) -> True
        TETensorMap _ _ -> True
        TESubrefs _ _ -> True
        TETranspose _ _ -> True
        TEDisjoint _ -> True
        TEAppendIndexed _ _ -> True
        TEDerivative _ _ -> True
        TEDot _ -> True
        TEUnary _ body -> definitelyTensor body
        TECall _ arguments -> any definitelyTensor arguments
        TEApply _ arguments -> any definitelyTensor arguments
        TEIf _ yes no -> definitelyTensor yes || definitelyTensor no
        TEWithSymbols _ body -> definitelyTensor body
        TEContractWith _ _ -> False
        TEBinary _ lhs rhs -> definitelyTensor lhs || definitelyTensor rhs
        TEGroup body -> definitelyTensor body
        TENumber _ -> False

validateRuntimeEinstein
  :: Model -> [RuntimeTensorBinding] -> [IxPart] -> TensorExpr -> IO ()
validateRuntimeEinstein m bindings targetIndices expression =
  strictEinstein m (sharpResultName : runtimeIndexedBindingNames bindings) targetIndices
    (renderTensorExpr (materialize expression))
  where
    targetNames = map ixName targetIndices

    materialize expr =
      case expr of
        TENumber _ -> expr
        TEIdent base [] ->
          case referenceSignature base of
            Just variances
              | not (null variances)
              , length variances <= length targetNames ->
                  TEIdent base
                    [IxPart variance name
                    | (variance, name) <- zip variances targetNames]
            _ -> expr
        TEIdent _ _ -> expr
        TEUnary op body -> TEUnary op (materialize body)
        TECall function arguments ->
          TECall (materialize function) (map materialize arguments)
        TEApply (TEIdent "sharp" []) [_]
          | targetName : _ <- targetNames ->
              TEIdent sharpResultName [IxPart VUp targetName]
        TEApply function arguments ->
          TEApply (materialize function) (map materialize arguments)
        TEIf condition yes no ->
          TEIf (materialize condition) (materialize yes) (materialize no)
        TEAppendIndexed body parts -> TEAppendIndexed body parts
        TEWithSymbols names body -> TEWithSymbols names (materialize body)
        TEContractWith reducer body -> TEContractWith reducer (materialize body)
        TETensorMap function body ->
          TETensorMap (materialize function) (materialize body)
        TESubrefs body parts -> TESubrefs body parts
        TETranspose names body -> TETranspose names (materialize body)
        TEDisjoint parts -> TEDisjoint (map materialize parts)
        TEDerivative parts body -> TEDerivative parts (materialize body)
        TEDot parts -> TEDot (map materialize parts)
        TEBinary op lhs rhs -> TEBinary op (materialize lhs) (materialize rhs)
        TEGroup body -> TEGroup (materialize body)

    referenceSignature base =
      let fieldName = fst (fieldBaseOf base)
      in case kindOf m fieldName of
           Just kind
             | componentRank kind > 0 ->
                 Just $ case fieldDeclOf m fieldName >>= fieldIndexParts of
                   Just parts | length parts == componentRank kind ->
                     map ixVariance parts
                   _ -> replicate (componentRank kind) VDown
           _ -> case [map ixVariance (runtimeBindingIndices binding)
                     | binding <- bindings,
                       runtimeBindingName binding == fieldName,
                       not (null (runtimeBindingIndices binding))] of
             variances : _ -> Just variances
             [] -> Nothing

    sharpResultName = reservedInternalPrefix ++ "SharpResult"

hasIndexSyntax :: Model -> [String] -> String -> Bool
hasIndexSyntax m lets = any indexedTok . itok
  where
    indexedTok (II nm) =
      case parseIndexedIdent nm of
        (base, parts@(_:_)) ->
          all isIndexPart parts
          && (isIndexedBase base || derivativeOpParts nm /= Nothing)
          && not (isAxisDerivative nm parts)
        _ -> False
    indexedTok _ = False
    isIndexPart (IxPart _ name) = not (null name) && all isAlphaNum name
    isAxisDerivative nm parts =
      take 2 nm == "d_"
      && all (\part -> ixName part `elem` mAxes m) parts
    isIndexedBase base =
      case kindOf m (fst (fieldBaseOf base)) of
        Just kind -> componentRank kind > 0
        Nothing ->
          base `elem` lets
          || base `elem` ["d", "delta", "epsilon", metricPreludeName]
          || Just base == mMetricName m

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
  let -- A primed tensor family is needed only when a later RHS reads it.
      -- Descriptor-driven equation printing no longer needs a synthetic
      -- primed target tensor merely to recover storage names.
      prims = sort (nub (primedRefs m))
  if mMetric m /= Nothing && mEmbed m /= Nothing
    then fatal "declare either 'metric scale' or 'embedding', not both"
    else return ()
  backendPlan <- backendPlanFor m
  runtimeBindings <- runtimeTensorBindingsFor m
  let scopedSteps = scopeRuntimeBindings runtimeBindings (mSteps m)
      allBindingNames = runtimeTensorBindingNames runtimeBindings
      initializerBindings = []
  mapM_ (validateStepScope allBindingNames) scopedSteps
  mapM_ (validateInitializerScope allBindingNames) (mInits m)
  let lbPlans = bpLbPlans backendPlan
      plannedAuxFields = bpMetricAuxFields backendPlan ++ concatMap lpAuxFields lbPlans
      generatedGridFunctionNames =
        map afName plannedAuxFields
        ++ [sNm step | step <- mSteps m, sk step == KLocal]
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
      centeredDerivativeContextDecls =
            [ "def shift (a: Integer) (c: MathValue) (u: MathValue) : MathValue :="
            , "  substitute [(feCoords_a, feCoords_a + c * feHsteps_a)] u"
            , "def dC (a: Integer) (u: MathValue) : MathValue :="
            , "  (shift a 1 u - shift a (-1) u) / (2 * feHsteps_a)"
            , "def dC2 (a: Integer) (u: MathValue) : MathValue :="
            , "  (shift a 1 u - 2 * u + shift a (-1) u) / ((feHsteps_a) ^ 2)"
            ]
      coordinateDerivativeContextDecls =
            [ "def dTaylor (m: Integer) (ks: [MathValue]) (a: Integer) (u: MathValue) : MathValue :="
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
            , "def feFieldNames : [(String, String)] := concat (map FMR.fieldNameMappings feFieldDescriptors) ++ "
              ++ egiStringPairs
                   [(name, name) | name <- generatedGridFunctionNames]
            , "def feFieldPolicies : [(String, GridPolicy)] := map (\\(name, policy, _, _, _, _, _) -> (name, policy)) feFieldDescriptors"
            , "def feIndexNames : [String] := " ++ egiStringList internalIndexVars
            , "def fePrinterContext := (feSymbolNames, feFieldNames, feIndexNames, feCoords, feHsteps, feAxisIds)"
            , "def fmrEq : String -> MathValue -> String := FMR.eq fePrinterContext"
            , "def fmrInit : String -> MathValue -> String := FMR.init fePrinterContext"
            , "def componentEqs : [String] -> [MathValue] -> [String] := FMR.componentEqs fePrinterContext"
            , "def fieldEqs descriptor value := FMR.fieldEqs fePrinterContext descriptor value"
            , "def fieldInits descriptor value := FMR.fieldInits fePrinterContext descriptor value"
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
  body <- mapM (\(_, after, step) -> stepDefs after step) scopedSteps
  items <- mapM (\(before, _, step) -> stepItem before step) scopedSteps
  inits <- mapM (initLine initializerBindings) (mInits m)
  let metricAuxFields = plannedAuxFields
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
      needsCoordinateDerivativeContext =
        "∂ " `isInfixOf` operationalResidualText
        || usesOperationalName ["dTaylor", "axisId"]
      needsCenteredDerivativeContext =
        needsCoordinateDerivativeContext
        || needsTensorDerivativeContext
        || usesOperationalName ["shift", "dC", "dC2"]
      needsResidualYeeContext =
        usesLb
        || needsTensorDerivativeContext
        || usesOperationalName ["dYee", "yeeRef", "unit3"]
      contextMathDecls =
        (if needsCenteredDerivativeContext
           then centeredDerivativeContextDecls else [])
        ++ (if needsCoordinateDerivativeContext
              then coordinateDerivativeContextDecls else [])
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
      feInits = [egiConcatDef "feInits"
                   (concat inits ++ map (\initializer -> "[" ++ initializer ++ "]") mtInits)]
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
    validateStepScope allNames (before, _, step) =
      case [name | name <- runtimeBindingReferences allNames (sEx step),
                   name `notElem` runtimeTensorBindingNames before] of
        name : _ -> fatal ("step references a binding before its definition: "
                           ++ name)
        [] -> return ()

    validateInitializerScope bindingNames initializer =
      case [name | TId name True <- tokenize expression,
                   kindOf m name /= Nothing] of
        name : _ -> fatal ("initializer cannot reference primed field: " ++ name ++ "'")
        [] -> validateBindings
      where
        expression = initializerExpr initializer
        validateBindings = case
          [name | name <- runtimeBindingReferences bindingNames expression] of
            name : _ -> fatal ("initializer cannot reference step binding: " ++ name)
            [] -> return ()
        initializerExpr (ICas _ value) = value
        initializerExpr (ICasIndex _ _ value) = value
        initializerExpr _ = ""

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
    stepDefs bindings st = case sk st of
      KLet | not (null (sIdx st)) -> do
               pre <- preprocessTensorExpr m (sEx st)
               lowered <- lowerBackendText m pre
               let nm = sNm st
                   binding = bindingFor nm bindings
                   bindingPolicy = runtimeBindingPolicy binding
                   policy = fromMaybe Collocated bindingPolicy
                   targetRank = length (sIdx st)
                   targetKind = case targetRank of
                     1 -> Vector
                     2 -> Tensor2
                     _ -> error "unsupported indexed let rank"
               if targetRank > 2
                 then fatal ("indexed let rank is not supported: " ++ nm
                             ++ concatMap ixSuffix (sIdx st))
                 else return ()
               expression <- case parseTensorExprEither lowered of
                 Right parsed -> return parsed
                 Left message -> fatal ("bad indexed let expression: " ++ message)
               nativeCandidate <- nativeExpressionAt policy m bindings lowered
               let native =
                     if nativeResultIndicesSafe (map fst nativeMarkerMap)
                          m bindings (sIdx st) expression
                       then nativeCandidate
                       else Nothing
               case native of
                 Just value -> do
                   if "FE.sharp " `isInfixOf` nativeText value
                     then case sIdx st of
                            [IxPart VUp _] -> return ()
                            _ -> fatal "sharp in an indexed let needs an explicitly contravariant target"
                     else return ()
                   case bindingPolicy of
                     Just locatedPolicy ->
                       validateNativeResult m locatedPolicy targetKind lowered value
                     Nothing ->
                       if nativeRank value == targetRank
                         then return ()
                         else fatal ("indexed let " ++ nm ++ " has tensor rank "
                                     ++ show (nativeRank value) ++ " but target rank is "
                                     ++ show targetRank)
                   return ["def " ++ nm ++ " := "
                           ++ checkedNativeTensor m nm (sIdx st) (nativeText value)]
                 Nothing -> do
                   expanded <- expandRuntimeTensorDefs m lowered
                   runtimeExpression <- case parseTensorExprEither expanded of
                     Right parsed -> return parsed
                     Left message -> fatal ("bad indexed let expression: " ++ message)
                   let targetBasis = reservedInternalPrefix ++ "TargetBasis"
                   rendered <- renderRuntimeTensorExpr
                     m bindings policy (sIdx st) targetBasis runtimeExpression
                   runtime <- case rendered of
                     Right result -> return result
                     Left message -> fatal ("cannot lower indexed let " ++ nm
                                            ++ " in Egison: " ++ message)
                   validateRuntimeEinstein m bindings (sIdx st) runtimeExpression
                   validateRuntimeTensorResult m bindings policy (sIdx st)
                     targetKind runtimeExpression
                   let atName = reservedInternalPrefix ++ "LetAt" ++ nm
                       checked = renderCheckedRuntimeTensor m nm (sIdx st) runtime
                       shape = replicate (length (sIdx st)) (mDim m)
                   return
                     [ "def " ++ atName ++ " (" ++ targetBasis
                       ++ ": [Integer]) : Tensor MathValue := " ++ checked
                     , "def " ++ nm ++ " := generateTensor (\\" ++ targetBasis
                       ++ " -> FE.tensorComponentAt (" ++ atName ++ " "
                       ++ targetBasis ++ ") " ++ targetBasis ++ ") " ++ show shape
                     ]
           | otherwise -> do
               let policy = maybe Collocated id
                     (runtimeBindingPolicy (bindingFor (sNm st) bindings))
               e <- rewriteScalarAt policy m bindings (sEx st)
               return ["def " ++ sNm st ++ " := " ++ e]
      KEq
        | not (null (sIdx st)), isIndexKind (kindOf m (sNm st)) -> indexDefs m bindings st
        | isIndexI (sIdx st) -> do
            e <- rewrite m (runtimeIndexedBindingNames bindings) Nothing (sEx st)
            return ["def feq" ++ sNm st ++ "_i := withSymbols [i] " ++ e]
        | kindOf m (sNm st) == Just Vector && null (sIdx st) -> do
            implicitVectorDefs m bindings st
      _ -> return []
    stepItem bindings st = case sk st of
      KLet -> return Nothing
      KLocal -> do
        e <- rewriteScalar m bindings (sEx st)
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
            rhs <- rewriteFormValue m (runtimeIndexedBindingNames bindings) (sEx st)
            let nm = sNm st
            case (kindOf m nm, inferredDegree) of
              (Just (Form targetDegree), Just rhsDegree)
                | targetDegree /= rhsDegree ->
                    fatal ("form degree mismatch for " ++ nm ++ ": target is "
                           ++ show targetDegree ++ " but RHS is " ++ show rhsDegree)
              _ -> return ()
            return (Just ("fieldEqs (" ++ fieldDescriptorRef m nm ++ ") (" ++ rhs ++ ")"))
        | otherwise -> do
            e <- rewriteScalarAt (fieldPolicyOf m (sNm st)) m bindings (sEx st)
            return (Just ("scalarEq \"" ++ sNm st ++ "\" (" ++ e ++ ")"))
    initLine bindings it = case it of
      IRaw nm rhs -> return [singleton ("\"  " ++ firstComponentStorageName m nm
                             ++ rawGridPoint ++ " = " ++ escQ rhs ++ "\"")]
      IVec nm els -> return
        [singleton ("\"  " ++ lhs ++ rawGridPoint ++ " = " ++ escQ el ++ "\"")
        | (lhs, el) <- zip (componentStorageNamesOf m nm) els]
      ISym nm els -> return
        [singleton ("\"  " ++ lhs ++ rawGridPoint ++ " = " ++ escQ el ++ "\"")
        | (lhs, el) <- zip (componentStorageNamesOf m nm) els]
      IAnti nm els -> return
        [singleton ("\"  " ++ lhs ++ rawGridPoint ++ " = " ++ escQ el ++ "\"")
        | (lhs, el) <- zip (componentStorageNamesOf m nm) els]
      ITensor2 nm els -> return
        [singleton ("\"  " ++ lhs ++ rawGridPoint ++ " = " ++ escQ el ++ "\"")
        | (lhs, el) <- zip (componentStorageNamesOf m nm) els]
      ICas nm ex -> do
        let policy = fieldPolicyOf m nm
            targetPlacement = componentPlacement m policy []
        (rhsPolicy, e) <- rewriteScalarInitializerAt policy m bindings ex
        validateInitializerCoordinateMix Scalar rhsPolicy ex
        let sampled = case rhsPolicy of
              Nothing
                | targetPlacement == componentPlacement m Collocated [] -> e
                | otherwise -> shiftTo targetPlacement e
              Just sourcePolicy
                | targetPlacement == componentPlacement m sourcePolicy [] -> e
                | otherwise -> shiftBy
                    ("FE.relativePlacement (FE.componentPlacement feDim "
                     ++ show policy ++ " []) (FE.componentPlacement feDim "
                     ++ show sourcePolicy ++ " [])") e
        return [singleton ("fmrInit \"" ++ nm ++ "\" (" ++ sampled ++ ")")]
      ICasIndex nm lhsIx ex -> indexedInitLines bindings nm lhsIx ex
      where
        singleton expression = "[" ++ expression ++ "]"

    bindingFor name bindings =
      case [binding | binding <- bindings, runtimeBindingName binding == name] of
        binding : _ -> binding
        [] -> error ("missing runtime tensor binding for " ++ name)

    indexedInitLines bindings nm lhsIx ex = do
      let policy = fieldPolicyOf m nm
      pre <- preprocessTensorExpr m ex
      lowered <- lowerBackendText m pre
      loweredExpression <- case parseTensorExprEither lowered of
        Right parsed -> return parsed
        Left message -> fatal ("bad indexed initializer: " ++ message)
      let targetBasis = reservedInternalPrefix ++ "TargetBasis"
      nativeCandidate <- nativeExpressionAt policy m bindings lowered
      let native =
            if nativeResultIndicesSafe (map fst nativeMarkerMap)
                 m bindings lhsIx loweredExpression
              then nativeCandidate
              else Nothing
      (checked, rhsPolicy) <- case (kindOf m nm, native) of
        (Just targetKind, Just value) -> do
          if "FE.sharp " `isInfixOf` nativeText value
            then case fieldDeclOf m nm >>= fieldIndexParts of
                   Just [IxPart VUp _] -> return ()
                   _ -> fatal ("sharp initializer target must be explicitly contravariant: "
                               ++ nm ++ concatMap ixSuffix lhsIx)
            else return ()
          if nativeRank value == componentRank targetKind
            then return ()
            else fatal ("indexed initializer for " ++ nm ++ " has tensor rank "
                        ++ show (nativeRank value) ++ " but target rank is "
                        ++ show (componentRank targetKind))
          return (checkedNativeTensor m nm lhsIx (nativeText value),
                  nativePolicy value)
        (Just targetKind, Nothing) -> do
          expanded <- expandRuntimeTensorDefs m lowered
          expression <- case parseTensorExprEither expanded of
            Right parsed -> return parsed
            Left message -> fatal ("bad indexed initializer: " ++ message)
          validateRuntimeEinstein m bindings lhsIx expression
          inferredPolicy <-
            case inferRuntimeExpressionPolicy
                   m bindings lhsIx targetKind expression of
              Right inferred -> return inferred
              Left message -> fatal message
          rendered <- renderRuntimeTensorExpr
            m bindings (fromMaybe policy inferredPolicy)
              lhsIx targetBasis expression
          runtime <- case rendered of
            Right result -> return result
            Left message -> fatal ("cannot lower indexed initializer for " ++ nm
                                   ++ " in Egison: " ++ message)
          return (renderCheckedRuntimeTensor m nm lhsIx runtime,
                  inferredPolicy)
        _ -> fatal ("indexed CAS initializer has wrong indices for its field kind: "
                    ++ nm)
      case kindOf m nm of
        Just targetKind ->
          validateInitializerCoordinateMix targetKind rhsPolicy lowered
        Nothing -> return ()
      let
          component = "FE.tensorComponentAt (" ++ checked ++ ") " ++ targetBasis
          targetPlacement = "FE.componentPlacement feDim " ++ show policy
                            ++ " " ++ targetBasis
          samplingPlacement = case rhsPolicy of
            Nothing -> targetPlacement
            Just sourcePolicy ->
              "FE.relativePlacement (" ++ targetPlacement
              ++ ") (FE.componentPlacement feDim " ++ show sourcePolicy
              ++ " " ++ targetBasis ++ ")"
          sampled
            | rhsPolicy == Just policy
              || policy == Collocated && rhsPolicy == Nothing = component
            | otherwise =
                "substitute (map (\\a -> (feCoords_a, feCoords_a + nth a ("
                ++ samplingPlacement ++ ") * feHsteps_a)) feAxisIds) ("
                ++ component ++ ")"
          shape = replicate (length lhsIx) (mDim m)
          tensor = "generateTensor (\\" ++ targetBasis ++ " -> " ++ sampled
                   ++ ") " ++ show shape
      return ["fieldInits (" ++ fieldDescriptorRef m nm ++ ") ("
              ++ show policy ++ ", " ++ tensor ++ ")"]

    shiftTo anchor e =
      shiftBy (placeText anchor) e
    shiftBy placement e =
      "substitute (map (\\a -> (feCoords_a, feCoords_a + nth a ("
      ++ placement ++ ") * feHsteps_a)) feAxisIds) (" ++ e ++ ")"
    validateInitializerCoordinateMix targetKind rhsPolicy source =
      case rhsPolicy of
        Just sourcePolicy
          | usesCoordinates
          , any (\basis -> componentPlacement m sourcePolicy basis
                           /= componentPlacement m Collocated basis)
                (componentIndices (mDim m) targetKind) ->
              fatal ("initializer cannot mix explicit coordinates with a "
                     ++ "staggered field-valued expression: " ++ source)
        _ -> return ()
      where
        coordinateNames = mAxes m ++ internalCoordNames m
        usesCoordinates = any isCoordinate (tokenize source)
        isCoordinate (TId name _) = name `elem` coordinateNames
        isCoordinate _ = False
    rawGridPoint = "[" ++ intercalate "," (internalIndexNames m) ++ "]"

-- Unicode input: Greek letters transliterate to their ASCII names.  A
-- decorated partial-derivative sign is a coordinate derivative:
-- `∂_x u`, `∂^2_x u`, `∂'^2_x u`.  A plain marked partial (`∂_i` or
-- `∂~i`) remains the indexed derivative when the mark is not a declared
-- axis.  A bare partial sign still becomes d.  The small delta becomes the
-- codifferential, and the minus sign becomes '-'.
transliterate :: String -> String
transliterate = fst . transliterateWithMap

-- Return the transliterated text together with a 1-based map from every
-- generated character to the original source character that produced it.
-- The map is monotone and covers whole decorated-derivative spellings, so a
-- translated AST span can always be projected back to its pre-transliteration
-- source columns.
transliterateWithMap :: String -> (String, [Int])
transliterateWithMap = go 1
  where
    go _ [] = ([], [])
    go offset ('\8706':cs) =
      case coordDerivative cs of
        Just ((ordr, radius, part), rest) ->
          appendMapped offset (1 + length cs - length rest)
            ("pd" ++ show ordr ++ "r" ++ show radius
             ++ renderDerivativePart part) rest
        Nothing | oldCompactDerivative cs ->
          appendMapped offset 1 "badPartialDerivative " cs
        Nothing ->
          case cs of
            '_':rest -> appendMapped offset 2 "d_" rest
            '~':rest -> appendMapped offset 2 "d~" rest
            _ -> appendMapped offset 1 "d" cs
    go offset (c:cs) = appendMapped offset 1 (tr c) cs

    appendMapped offset consumed replacement rest =
      let (suffix, suffixMap) = go (offset + consumed) rest
      in (replacement ++ suffix,
          replacementOffsets offset consumed (length replacement) ++ suffixMap)

    replacementOffsets _ _ 0 = []
    replacementOffsets offset consumed 1 = [offset + consumed - 1]
    replacementOffsets offset consumed count =
      [offset + (position * (consumed - 1)) `div` (count - 1)
      | position <- [0 .. count - 1]]

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
      txt <- readFile path
      let name = takeWhile (/= '.') (reverse (takeWhile (/= '/') (reverse path)))
      m <- parseFe path name txt
      out <- emit m
      putStr out
    _ -> fatal "usage: fec model.fme > model.egi"
