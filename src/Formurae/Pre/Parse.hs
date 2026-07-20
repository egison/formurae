{-# LANGUAGE PatternSynonyms #-}
-- Parse and validate Formurae's mathematical surface language.
--
-- This is intentionally only a front-end parser.  It preserves analytic
-- tensor expressions and exact source maps for formurae-pre; Egison performs
-- continuum normalization and formurae-post selects discrete implementations.
module Formurae.Pre.Parse
  ( parseModel
  ) where

import Control.Monad (foldM, when)
import Data.Char (isAlpha, isAlphaNum, isDigit, isSpace, toUpper)
import Data.List (dropWhileEnd, intercalate, nub, sort, stripPrefix, isSuffixOf)
import Data.Ratio (denominator, numerator)

import Formurae.Common
import Formurae.Index
import Formurae.Post.Stencil (sbpPrimalNorm, sbpStaggeredPair)
import Formurae.Syntax
import Formurae.TensorExpr
  ( pattern TENumber, pattern TEIdent, pattern TEUnary, pattern TECall
  , pattern TEApply, pattern TEIf, pattern TEAppendIndexed
  , pattern TEWithSymbols, pattern TEContractWith, pattern TETensorMap
  , pattern TESubrefs, pattern TETranspose, pattern TEDisjoint
  , pattern TEDerivative, pattern TEGridDerivativeChain
  , pattern TETensorLiteral, pattern TEDot, pattern TEBinary, pattern TEGroup
  , parseTensorExprEither, renderTensorExpr
  )

-- Names provided by the continuum normalization libraries.  They are reserved
-- tensor operators or values and cannot be reused by surface value bindings.
standardNames :: [String]
standardNames =
  [ ".", "wedge", "trace", "sym", "antisym", "norm2"
  , "hessian", "grad", "dGrad", "divg", "curl", "lap", "Δ"
  , "d", "δ", "hodge", "ΔH"
  , "resample"
  , "epsilon"
  , "π", "pi"
  ]

-- Unicode π is the one symbolic circle constant in the mathematical
-- surface language.  ASCII pi is reserved as a diagnostic-only near miss:
-- Egison core defines it as a Float, which would bypass CAS simplification.
mathematicalConstantNames :: [String]
mathematicalConstantNames = ["π", "pi"]

scalarIntrinsics :: [String]
scalarIntrinsics =
  [ "sin", "cos", "tan"
  , "asin", "acos", "atan", "atan2"
  , "sinh", "cosh", "tanh"
  , "exp", "log", "sqrt", "pow", "fabs"
  ]

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

ambientNames :: [String]
ambientNames =
  [ "dimension", "coordinates", "volume", "metric", "inverseMetric", "epsilon" ]

generatedNormalizationNames :: [String]
generatedNormalizationNames = ambientNames ++
  [ "feDimension", "feCoordinates", "feGeometryId", "fePrimitiveManifestId"
  , "feParameters", "feCoordinatesRegistry", "feFields"
  , "feIntrinsics", "feAnalytics", "feProgram"
  , "feGeometryScaleRaw", "feGeometryMetricRaw", "feGeometryEmbedding"
  , "feGeometryInverseMetricRaw", "feGeometryScales"
  , "feGeometryOrthogonalityVerified", "feGeometryMetric"
  , "feGeometryScale", "feGeometryInverseMetric", "feGeometryVolume"
  , "main"
  ]

normalizationDependencies :: [String]
normalizationDependencies =
  [ "print", "nth", "foldl", "map", "sum", "product", "sqrt"
  , "contractWith"
  -- These names occur in generated tensor encoders and indexed-parameter
  -- checks and therefore must not resolve to a model binding.
  , "tensorShape", "dfOrder", "assert", "bool"
  ]

-- Every user definition is wrapped in one `withSymbols` that binds these
-- names.  A value binding or formal parameter with the same name would be
-- silently captured by the generated wrapper rather than denoting the
-- surface binding.
generatedIndexNames :: [String]
generatedIndexNames = ["i", "j", "k", "l", "m", "n"]
-- ------------------------------------------------------------- utilities

metricNameConflicts :: Model -> [(String, String)]
metricNameConflicts m =
  [("param", nm) | (nm, _) <- mParams m]
  ++ [("field", fdName field) | field <- mFieldDecls m]
  ++ [("definition", defName definition) | definition <- mDefs m]
  ++ [("definition parameter", defParamBase parameter)
     | definition <- mDefs m, parameter <- defParams definition]
  ++ [(stepKind step, sNm step)
     | step <- mSteps m, sk step `elem` [KLet, KLocal]]
  where
    stepKind step = case sk step of
      KLet -> "let"
      KLocal -> "local"
      _ -> "step"

validateValueBindingNames :: Model -> IO ()
validateValueBindingNames m =
  case duplicateBindings of
    [] -> checkDuplicateDefinitions
    (name, kinds) : _ ->
      fatal ("value name '" ++ name ++ "' is declared more than once as "
             ++ intercalate "/" kinds)
  where
    bindings =
      [("param", nm, ln)
      | ((nm, _), ln) <- zip (mParams m) (mParamSourceLines m)]
      ++ [("field", fdName field, fdSourceLine field)
         | field <- mFieldDecls m]
      ++ [("let", sNm st, sourceLine (sSourceText st))
         | st <- mSteps m, sk st == KLet]
      ++ [("local", sNm st, sourceLine (sSourceText st))
         | st <- mSteps m, sk st == KLocal]
    duplicateBindings =
      [(name, map fst matches)
      | name <- nub [bindingName | (_, bindingName, _) <- bindings]
      , let matches =
              [(kind, line) | (kind, bindingName, line) <- bindings
                            , bindingName == name]
      , length matches > 1]
    definitionBindings =
      [ (defName definition,
         maybe 0 sourceLine (defSourceText definition))
      | definition <- mDefs m
      ]
    duplicateDefinitions =
      [ (definitionName,
         sort [line | (name, line) <- definitionBindings
                    , name == definitionName])
      | definitionName <- nub (map fst definitionBindings)
      , length [() | (name, _) <- definitionBindings
                   , name == definitionName] > 1
      ]
    checkDuplicateDefinitions =
      case duplicateDefinitions of
        [] -> checkDefinitionParameterConflicts
        (definitionName, lines') : _ ->
          fatal ("definition name '" ++ definitionName
                 ++ "' is declared more than once (lines "
                 ++ intercalate ", " (map show lines') ++ ")")
    checkDefinitionParameterConflicts =
      case [ (defName definition, parameterName,
              maybe 0 sourceLine (defSourceText definition))
           | definition <- mDefs m
           , parameter <- defParams definition
           , let parameterName = defParamBase parameter
           , parameterName `elem` renamedAxisNames
           ] of
        [] -> checkDefinitionValueConflicts
        (definitionName, parameterName, line) : _ ->
          fatal ("definition parameter '" ++ parameterName ++ "' in '"
                 ++ definitionName
                 ++ "' conflicts with a coordinate axis (line "
                 ++ show line ++ ")")
    renamedAxisNames =
      [ sourceName
      | (sourceName, canonicalName) <- zip (mAxes m) (internalCoordNames m)
      , sourceName /= canonicalName
      ]
    checkDefinitionValueConflicts =
      case [ (definitionName, definitionLine, kind, bindingLine)
           | definition <- mDefs m
           , let definitionName = defName definition
                 definitionLine = maybe 0 sourceLine (defSourceText definition)
           , (kind, bindingName, bindingLine) <- bindings
           , definitionName == bindingName
           ] of
        [] -> checkGeneratedValueConflicts
        (name, definitionLine, kind, bindingLine) : _ ->
          fatal ("definition name '" ++ name ++ "' conflicts with " ++ kind
                 ++ " value binding (definition line " ++ show definitionLine
                 ++ ", " ++ kind ++ " line " ++ show bindingLine ++ ")")
    checkGeneratedValueConflicts =
      case [(kind, name, line) | (kind, name, line) <- bindings
                               , isGeneratedValueName name] of
        [] -> checkGeneratedDefinitionConflicts
        (kind, name, line) : _ ->
          fatal ("value name '" ++ name
                 ++ "' is reserved for generated Egison code (" ++ kind
                 ++ ", line " ++ show line ++ ")")
    checkGeneratedDefinitionConflicts =
      case [ (defName definition,
              maybe 0 sourceLine (defSourceText definition))
           | definition <- mDefs m
           , isGeneratedDefinitionName (defName definition)
           ] of
        [] -> return ()
        (name, line) : _ ->
          fatal ("definition name '" ++ name
                 ++ "' is reserved for generated Egison code (line "
                 ++ show line ++ ")")
    isGeneratedValueName name =
      name `elem` generatedValueNames
      || isReservedInternalName name
    generatedValueNames =
      mAxes m
      ++ internalCoordNames m
      ++ generatedIndexNames
      ++ generatedNormalizationNames
      ++ standardNames
      ++ scalarIntrinsics
      ++ egisonReservedWords
      ++ normalizationDependencies
    isGeneratedDefinitionName name =
      name `elem` definitionGeneratedNames
      || isReservedInternalName name
    -- Standard operators, scalar intrinsics, and explicit primitives remain
    -- intentionally shadowable by user definitions.  Only names owned by the
    -- generated normalization unit itself are forbidden here.
    definitionGeneratedNames =
      mAxes m
      ++ internalCoordNames m
      ++ generatedIndexNames
      ++ generatedNormalizationNames
      ++ mathematicalConstantNames
      ++ egisonReservedWords
      ++ normalizationDependencies

validateMetricName :: Model -> IO ()
validateMetricName m =
  case mMetricName m of
    Nothing -> return ()
    Just nm | nm `elem` mAxes m ->
      fatal ("metric name '" ++ nm
             ++ "' conflicts with a coordinate axis (axes line "
             ++ show (maybe 0 id (mAxesSourceLine m)) ++ ")")
    Just "δ" ->
      fatal "metric δ is reserved for Kronecker delta; use metric g for the metric tensor"
    Just nm -> do
      let conflicts = nub [kind | (kind, x) <- metricNameConflicts m, x == nm]
      case conflicts of
        [] -> return ()
        _ -> fatal
          ("metric name '" ++ nm ++ "' conflicts with "
           ++ intercalate "/" conflicts ++ " binding")

-- The indices on an Egison-style binding LHS are implicit withSymbols
-- binders for its RHS.  Reject names that would shadow an existing value;
-- the generated i/j/k/... symbol pool is intentionally omitted because
-- those are precisely the names an indexed binding is expected to bind.
validateIndexedStepTargets :: Model -> IO ()
validateIndexedStepTargets model = mapM_ validateStep (mSteps model)
  where
    validateStep step = do
      either (fatal . renderIndexedTargetError line targetName)
             return
             (validateBindingIndices forbidden (sIdx step))
      case sk step of
        KEq ->
          case fieldDeclOf model targetName of
            Nothing -> fatal ("unknown step target '" ++ targetName
                              ++ "' (line " ++ show line ++ ")")
            Just field ->
              either (fatal . renderIndexedTargetError line targetName)
                     return
                     (validateFieldTarget field (sTarget step))
        KLocal ->
          case sLocalDecl step of
            Nothing -> fatal ("internal local declaration is missing for '"
                              ++ targetName ++ "' (line " ++ show line ++ ")")
            Just local ->
              either (fatal . renderIndexedTargetError line targetName)
                     return
                     (validateFieldTarget (localDeclAsField local)
                       (sTarget step))
        _ -> return ()
      where
        targetName = sNm step
        line = sourceLine (sSourceText step)

    forbidden = nub $
      mAxes model
      ++ internalCoordNames model
      ++ map fst (mParams model)
      ++ map fdName (mFieldDecls model)
      ++ [sNm step | step <- mSteps model, sk step `elem` [KLet, KLocal]]
      ++ map defName (mDefs model)
      ++ maybe [] (: []) (mMetricName model)
      ++ generatedNormalizationNames
      ++ standardNames
      ++ scalarIntrinsics
      ++ egisonReservedWords
      ++ normalizationDependencies

renderIndexedTargetError :: Int -> String -> IndexedTargetError -> String
renderIndexedTargetError line targetName problem =
  case problem of
    IndexedTargetNameMismatch expected actual ->
      "indexed target name '" ++ actual ++ "' does not match field '"
      ++ expected ++ "' (line " ++ show line ++ ")"
    InvalidTargetIndex name ->
      "invalid index name '" ++ name ++ "' on target '" ++ targetName
      ++ "' (line " ++ show line ++ ")"
    DuplicateTargetIndex name ->
      "index '" ++ name ++ "' occurs more than once on target '"
      ++ targetName ++ "' (line " ++ show line ++ ")"
    TargetIndexNameConflict name ->
      "index '" ++ name ++ "' on target '" ++ targetName
      ++ "' conflicts with a coordinate or value binding (line "
      ++ show line ++ ")"
    IndexedTargetRankMismatch expected actual ->
      "indexed target '" ++ targetName ++ "' has rank " ++ show actual
      ++ ", but the field declaration has rank " ++ show expected
      ++ " (line " ++ show line ++ ")"
    IndexedTargetVarianceMismatch position expected actual ->
      "index " ++ show position ++ " on target '" ++ targetName ++ "' is "
      ++ varianceLabel actual ++ ", but the field declaration requires "
      ++ varianceLabel expected ++ " (line " ++ show line ++ ")"
  where
    varianceLabel VUp = "a superscript"
    varianceLabel VDown = "a subscript"

parseFieldDecl :: Int -> String -> IO FieldDecl
parseFieldDecl = parseStorageDecl False Primal

-- Field declarations historically default differential forms to Primal.
-- Locals deliberately do not: every omitted local policy is Collocated,
-- independent of tensor kind, and a staggered local must say @primal or
-- @dual explicitly.
parseLocalDecl :: Int -> String -> IO LocalDecl
parseLocalDecl ln source =
  localDeclFromField <$> parseStorageDecl True Collocated ln source

parseStorageDecl :: Bool -> GridPolicy -> Int -> String -> IO FieldDecl
parseStorageDecl deferredAllowed defaultFormPolicy ln r =
  case break (== ':') r of
    (nm0, ':':k0) -> withKind (strip nm0) (strip k0)
    _ -> indexed
  where
    withKind nm k =
      if not (validSurfaceName nm)
        then fatal ("bad field name: " ++ nm ++ " (line " ++ show ln ++ ")")
        else do
          rejectReservedName ln nm
          case words k of
            "scalar" : attrs -> do
              policy <- parsePolicyAttrs Collocated attrs
              return (FieldDecl nm Nothing policy Scalar ln)
            "vector" : attrs -> do
              policy <- parsePolicyAttrs Collocated attrs
              return (FieldDecl nm Nothing policy Vector ln)
            "symmetric" : attrs -> do
              policy <- parsePolicyAttrs Collocated attrs
              return (FieldDecl nm Nothing policy SymM ln)
            -- `: tensor` defers rank, variances, and form degree to the
            -- value computed during normalization.  Only step locals may
            -- defer: user-state fields are the model interface.
            "tensor" : attrs
              | deferredAllowed -> do
                  policy <- parsePolicyAttrs Collocated attrs
                  return (FieldDecl nm Nothing policy TensorAny ln)
              | otherwise -> fatal
                  ("deferred tensor kind is only available on local "
                   ++ "declarations (line " ++ show ln ++ ")")
            form : attrs | Just deg <- formKind form -> do
              policy <- parsePolicyAttrs defaultFormPolicy attrs
              return (FieldDecl nm Nothing policy (Form deg) ln)
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
          case mix of
            Just (FieldIndex group) ->
              either (fatal . renderIndexedTargetError ln nm)
                     return
                     (validateDistinctIndices (groupParts group))
            Nothing -> return ()
          kind <- inferFieldKind ln spec mix
          return (FieldDecl nm mix policy kind ln)
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
    groupParts (Plain parts) = parts
    groupParts (Symmetric parts) = parts
    groupParts (Antisymmetric parts) = parts

-- NAME(~i|_i)? = EXPR   with NAME = [A-Za-z][A-Za-z0-9]*
eqForm :: String -> String -> Maybe (IndexedTarget, String)
eqForm marker s = do
  rest0 <- if null marker then Just s else stripPrefix (marker ++ " ") s
  let rest = dropWhile isSpace rest0
  (target, r2) <- parseIndexedTargetPrefix rest
  r3 <- stripPrefix "=" (dropWhile isSpace r2)
  let ex = strip r3
  if null ex then Nothing else Just (target, ex)

-- LOCAL-DECL = EXPR.  The declaration half accepts the complete field
-- descriptor grammar (indices/layout, kind/degree, and policy), while the
-- resulting IndexedTarget keeps only the free LHS indices that scope over
-- the RHS.  A colon declaration such as @local omega : 2-form = ...@ is a
-- whole-tensor target and therefore has no explicit LHS indices.
localForm :: Int -> String -> IO (LocalDecl, IndexedTarget, String)
localForm line source =
  case break (== '=') source of
    (declarationSource, '=' : expressionSource)
      | not (null expression) -> do
          declaration <- parseLocalDecl line (strip declarationSource)
          let target = IndexedTarget (ldName declaration)
                (maybe [] id (fieldIndexParts
                  (localDeclAsField declaration)))
          return (declaration, target, expression)
      where
        expression = strip expressionSource
    _ -> fatal ("bad local declaration (line " ++ show line ++ ")")

-- def NAME PARAM... = BODY
-- def (.) A B = BODY
--
-- Formurae deliberately has no result-index syntax on a user definition
-- head.  Indices written on parameters describe views of the arguments.
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

-- NAME'(~index|_index)* = EXPR
primeEqForm :: String -> Maybe (IndexedTarget, String)
primeEqForm s = do
  (target, r3) <- parsePrimedIndexedTargetPrefix s
  r4 <- stripPrefix "=" (dropWhile isSpace r3)
  let ex = strip r4
  if null ex then Nothing else Just (target, ex)

-- ---------------------------------------------------------------- parser

data Section = STop | SInit | SStep

validateDimensionFeatures :: Model -> IO ()
validateDimensionFeatures m
  | selectedMode m == CollocatedMode
  , any isFormField fieldKinds =
      fatal "differential-form fields require mode dec"
  | any isAntiField fieldKinds && mDim m < 2 =
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
      case [k | (_, Form k) <- fieldKinds, k < 0 || k > mDim m] of
        k:_ -> Just k
        [] -> Nothing
    fieldKinds =
      [(fdName field, fdKind field) | field <- mFieldDecls m]
      ++ [(ldName local, ldKind local)
         | step <- mSteps m
         , Just local <- [sLocalDecl step]]

validateBoundaryDecls :: Model -> IO ()
validateBoundaryDecls m = mapM_ check (mBoundaryDecls m)
  where
    check declaration
      | boundaryAxisName declaration `elem` mAxes m = return ()
      | otherwise = fatal
          ("boundary declaration names unknown axis '"
           ++ boundaryAxisName declaration ++ "' (line "
           ++ show (boundarySourceLine declaration) ++ ")")

-- | An sbp boundary declaration supplies named constants to the model:
-- the wall-neighborhood thresholds sbpLoA / sbpHiA and the inverse
-- boundary norm sbpHinvA of the minimal pair (with sbpHinv<2k>A for
-- every wider pair count the model's spellings or profile rules can
-- reach), where A is the axis name with its first letter capitalized —
-- an underscore would read as an Egison subscript, so the axis joins the
-- name in camel case.  Penalty terms compose these names instead of
-- hand-written closure weights.  The constants are ordinary parameters
-- with exact rational backend values, injected ahead of the user
-- parameters so a user parameter may reference them.
injectSbpBoundaryConstants :: [String] -> Model -> IO Model
injectSbpBoundaryConstants macroSources m
  | null sbpDeclarations = return m
  | otherwise = do
      mapM_ checkCollision constants
      return m
        { mParams = map constantParam constants ++ mParams m
        , mParamSourceLines = map constantLine constants
            ++ mParamSourceLines m
        }
  where
    sbpDeclarations =
      [ declaration
      | declaration <- mBoundaryDecls m
      , boundaryKind declaration == SurfaceSbpBoundary
      ]

    constants = concatMap axisConstants sbpDeclarations
    constantParam (name, value, _) = (name, value)
    constantLine (_, _, line) = line

    axisConstants declaration =
      let axis = boundaryAxisName declaration
          line = boundarySourceLine declaration
          step = "d" ++ axis
          suffix = sbpAxisSuffix axis
      in ( "sbpLo" ++ suffix, "0.5*" ++ step, line )
         : ( "sbpHi" ++ suffix
           , "(total_grid_" ++ axis ++ " - 1.5)*" ++ step, line )
         : [ (hinvName pairs suffix, hinvValue weight ++ "/" ++ step, line)
           | pairs <- pairCounts
           , Right pair <- [sbpStaggeredPair pairs]
           , weight : _ <- [sbpPrimalNorm pair]
           ]

    hinvName pairs suffix
      | pairs == 1 = "sbpHinv" ++ suffix
      | otherwise = "sbpHinv" ++ show (2 * pairs) ++ suffix

    hinvValue weight =
      let inverse = recip weight
          num = show (numeratorOf inverse) ++ ".0"
          den = show (denominatorOf inverse) ++ ".0"
      in if denominatorOf inverse == 1
           then num
           else "(" ++ num ++ "/" ++ den ++ ")"

    -- Every pair count the model can request on an sbp axis: the minimal
    -- stage, the explicit-radius spellings, and the staggered profile
    -- accuracies.  Unconstructible widths simply supply no constant.
    pairCounts = nub
      ( 1
      : [ radius
        | source <- modelExpressionTexts ++ macroSources
        , TId name _ <- tokenize source
        , Just (_, radius, _) <- [derivativeOpParts name]
        , radius > 1
        ]
      ++ [ accuracy `div` 2
         | declaration <- mDiscretizationDecls m
         , discretizationLatticeClass declaration == SurfaceStaggered
         , let accuracy = discretizationFormalAccuracy declaration
         , accuracy > 2
         ] )

    modelExpressionTexts =
      map sEx (mSteps m)
      ++ map defBody (mDefs m)
      ++ concatMap initializerTexts (mInits m)

    initializerTexts initializer =
      case initializer of
        IRaw _ _ -> []
        IVec _ components -> components
        ISym _ components -> components
        IAnti _ components -> components
        ITensor2 _ components -> components
        ICas _ expression -> [expression]
        ICasIndex _ _ expression -> [expression]

    checkCollision (name, _, line)
      | name `elem` boundNames = fatal
          ("value name '" ++ name
           ++ "' is reserved for the sbp boundary declaration (line "
           ++ show line ++ ")")
      | otherwise = return ()

    boundNames =
      mAxes m
      ++ map fst (mParams m)
      ++ map fdName (mFieldDecls m)
      ++ map defName (mDefs m)
      ++ map sNm (mSteps m)
      ++ maybe [] (: []) (mMetricName m)

macroTexts :: PreMacro -> [String]
macroTexts macro =
  map snd (pmLocals macro) ++ [snd (pmResult macro)]

-- | The axis suffix of the injected boundary constants: the axis name
-- with its first letter capitalized, so the joined name stays one plain
-- Egison symbol.
sbpAxisSuffix :: String -> String
sbpAxisSuffix axis =
  case axis of
    first : rest -> toUpper first : rest
    [] -> []

numeratorOf :: Rational -> Integer
numeratorOf = numerator

denominatorOf :: Rational -> Integer
denominatorOf = denominator

parseDiscretizationDecl :: Int -> String -> IO DiscretizationDecl
parseDiscretizationDecl lineNumber source =
  case words source of
    [latticeToken, familyToken, "accuracy", accuracyToken] ->
      build latticeToken Nothing familyToken accuracyToken
    [latticeToken, "derivative", orderToken,
      familyToken, "accuracy", accuracyToken] -> do
        order <- parsePositive "derivative order" orderToken
        build latticeToken (Just order) familyToken accuracyToken
    _ -> badSyntax
  where
    build latticeToken derivativeOrder familyToken accuracyToken = do
      lattice <- parseLattice latticeToken
      family <- parseFamily familyToken
      accuracy <- parsePositive "formal accuracy" accuracyToken
      if odd accuracy
        then fatal ("formal accuracy must be a positive even integer (line "
                    ++ show lineNumber ++ ")")
        else if not (validPair lattice family)
          then fatal ("invalid discretization lattice/family pair (line "
                      ++ show lineNumber ++ ")")
          else return DiscretizationDecl
            { discretizationLatticeClass = lattice
            , discretizationDerivativeOrder = derivativeOrder
            , discretizationStencilFamily = family
            , discretizationFormalAccuracy = accuracy
            , discretizationSourceLine = lineNumber
            }

    parsePositive label token
      | not (null token) && all isDigit token && read token > (0 :: Int) =
          return (read token)
      | otherwise = fatal (label ++ " must be a positive integer (line "
                           ++ show lineNumber ++ ")")

    parseLattice "collocated" = return SurfaceCollocated
    parseLattice "staggered" = return SurfaceStaggered
    parseLattice token = fatal ("unknown discretization lattice '" ++ token
                                ++ "' (line " ++ show lineNumber ++ ")")

    parseFamily "centered" = return SurfaceCentered
    parseFamily "yee" = return SurfaceYee
    parseFamily token = fatal ("unknown stencil family '" ++ token
                               ++ "' (line " ++ show lineNumber ++ ")")

    validPair SurfaceCollocated SurfaceCentered = True
    validPair SurfaceStaggered SurfaceYee = True
    validPair _ _ = False

    badSyntax = fatal
      ("bad discretization declaration (line " ++ show lineNumber ++ "): "
       ++ "discretization collocated [derivative ORDER] centered accuracy EVEN, "
       ++ "or discretization staggered [derivative ORDER] yee accuracy EVEN")

-- boundary AXIS : sbp | periodic | ghost VALUE
--
-- The boundary is an axis property: one declaration fixes the treatment of
-- every derivative along that axis, which is what makes a model-level
-- energy-stability claim checkable.  The axis name is resolved against the
-- axes declaration after the whole file is read.
parseBoundaryDecl :: Int -> String -> IO BoundaryDecl
parseBoundaryDecl lineNumber source =
  case break (== ':') source of
    (axisPart, ':' : kindPart)
      | axisName <- strip axisPart
      , not (null axisName) -> do
          kind <- parseKind (strip kindPart)
          return BoundaryDecl
            { boundaryAxisName = axisName
            , boundaryKind = kind
            , boundarySourceLine = lineNumber
            }
    _ -> badSyntax
  where
    parseKind "sbp" = return SurfaceSbpBoundary
    parseKind "periodic" = return SurfacePeriodicBoundary
    parseKind spec
      | Just fill <- stripPrefix "ghost " spec
      , not (null (strip fill)) = return (SurfaceGhostBoundary (strip fill))
      | spec == "ghost" = fatal ("ghost boundary needs a fill value (line "
                                 ++ show lineNumber ++ "): boundary AXIS : ghost VALUE")
      | otherwise = badSyntax
    badSyntax = fatal
      ("bad boundary declaration (line " ++ show lineNumber ++ "): "
       ++ "boundary AXIS : sbp, boundary AXIS : periodic, "
       ++ "or boundary AXIS : ghost VALUE")

-- Parse and validate the source language without expanding definitions or
-- selecting a discrete implementation.  formurae-pre emits this model to Egison
-- for mathematical normalization.
parseModel :: FilePath -> String -> String -> IO Model
parseModel sourceFile name txt = do
  mapM_ rejectInternalOperatorSpelling numberedMaskedLines
  mapM_ rejectNormalizationCapability numberedMaskedLines
  go STop [] initialModel
    [(lineNumber, transliterate raw, raw) | (lineNumber, raw) <- numberedLines]
  where
    -- Strip line comments once for the complete file.  The scanner keeps
    -- string, character-literal, and nested block-comment state across line
    -- boundaries; calling a line-local stripper from the parser would lose
    -- that state on the next line of a raw Egison block.
    numberedLines = zip [1 :: Int ..]
      (lines (stripEgisonLineComments txt))
    numberedMaskedLines = zip [1 :: Int ..]
      (lines (maskEgisonNonCode txt))

    -- Δ_H is lowered to the atomic identifier ΔH before the indexed-expression
    -- parser sees it.  Reserve that compact spelling so it cannot become an
    -- accidental second surface alias for the Hodge Laplacian.
    rejectInternalOperatorSpelling (lineNumber, raw) =
      case [name' | name' <- egisonIdentifiers raw, name' == "ΔH"] of
        _ : _ -> fatal ("ΔH is an internal spelling; write Δ_H (line "
                        ++ show lineNumber ++ ")")
        [] -> return ()

    -- Generated normalization code is trusted to construct opaque FEIR
    -- requests; user source is not.  Scan every surface context before its
    -- grammar-specific path is selected, including definitions, steps,
    -- initializers, metric scales, and embeddings.  The complete source was
    -- masked in one stateful pass above, so strings, character literals, line
    -- comments, and nested block comments cannot hide later executable code.
    rejectNormalizationCapability (lineNumber, raw) =
      case [name' | name' <- egisonIdentifiers raw,
                    isReservedNormalizationCapability name'] of
        name' : _ -> fatal
          ("reserved normalization capability '" ++ name'
           ++ "' cannot be used in Formurae source (line "
           ++ show lineNumber ++ ")")
        [] -> return ()

    initialModel = Model
      { mName = name
      , mSourcePath = sourceFile
      , mDim = 0
      , mAxes = []
      , mAxesSourceLine = Nothing
      , mMode = Nothing
      , mMetricName = Nothing
      , mParams = []
      , mParamSourceLines = []
      , mHelp = []
      , mHelpKinds = []
      , mHelpSourceLines = []
      , mFieldDecls = []
      , mInits = []
      , mInitSourceTexts = []
      , mSteps = []
      , mMetric = Nothing
      , mEmbed = Nothing
      , mDefs = []
      , mDiscretizationDecls = []
      , mBoundaryDecls = []
      }
    -- dimension and axes are required: they fix the coordinate frame
    -- that gives the operators their meaning (which axis ∂_theta is,
    -- what an index letter in ∂_j ranges over)
    go _ ms m []
      | mDim m == 0 = fatal "dimension declaration is required (dimension 1, 2, or 3)"
      | null (mAxes m) = fatal "axes declaration is required (e.g. axes x, y, z)"
      | any (not . validSurfaceName) (mAxes m) =
          fatal ("axes contains an invalid coordinate name (line "
                 ++ show (maybe 0 id (mAxesSourceLine m)) ++ ")")
      | length (nub (mAxes m)) /= length (mAxes m) =
          fatal ("axes coordinate names must be unique (line "
                 ++ show (maybe 0 id (mAxesSourceLine m)) ++ ")")
      | any (`elem` generatedIndexNames) (mAxes m) =
          fatal ("axes coordinate names conflict with generated index symbols (line "
                 ++ show (maybe 0 id (mAxesSourceLine m)) ++ ")")
      | reservedAxis : _ <-
          [axis | axis <- mAxes m,
                  axis `elem` (standardNames ++ scalarIntrinsics
                               ++ egisonReservedWords)] =
          fatal ("coordinate name '" ++ reservedAxis
                 ++ "' is reserved for a surface operator or intrinsic (axes line "
                 ++ show (maybe 0 id (mAxesSourceLine m)) ++ ")")
      | Just ambient <- firstAmbientName (mAxes m) =
          fatal ("coordinate name '" ++ ambient
                 ++ "' is reserved for the ambient Egison environment (axes line "
                 ++ show (maybe 0 id (mAxesSourceLine m)) ++ ")")
      | length (mAxes m) /= mDim m =
          fatal ("axes declares " ++ show (length (mAxes m))
                 ++ " names for dimension " ++ show (mDim m))
      | mMode m == Nothing = fatal "mode declaration is required (mode collocated or mode dec)"
      | otherwise = do
          let ordered = m
                { mParams = reverse (mParams m)
                , mParamSourceLines = reverse (mParamSourceLines m)
                , mHelp = reverse (mHelp m)
                , mHelpKinds = reverse (mHelpKinds m)
                , mHelpSourceLines = reverse (mHelpSourceLines m)
                , mFieldDecls = reverse (mFieldDecls m)
                , mInits = reverse (mInits m)
                , mInitSourceTexts = reverse (mInitSourceTexts m)
                , mSteps = reverse (mSteps m)
                , mDefs = reverse (mDefs m)
                , mDiscretizationDecls = reverse (mDiscretizationDecls m)
                , mBoundaryDecls = reverse (mBoundaryDecls m)
                }
          validateBoundaryDecls ordered
          supplied <- injectSbpBoundaryConstants
            (concatMap macroTexts ms) ordered
          mUse <- expandMacros (ms ++ activePreludeMacros supplied) supplied
          validateValueBindingNames mUse
          validateMetricName mUse
          validateDimensionFeatures mUse
          validateIndexedStepTargets mUse
          mapM_ (checkUserSurface mUse [] "in embedding expression")
            (maybe [] id (mEmbed mUse))
          mapM_ (checkUserSurface mUse [] "in metric scale expression")
            (maybe [] id (mMetric mUse))
          mapM_ (\df ->
                    checkUserSurface mUse (map defParamBase (defParams df))
                      ("in def " ++ defName df) (defBody df))
                (mDefs mUse)
          mapM_ (\st ->
                    checkUserSurface mUse []
                      ("in step expression: " ++ sEx st) (sEx st))
                (mSteps mUse)
          mapM_ (checkInitUse mUse) (mInits mUse)
          return mUse

    go sec ms m ((ln, raw, originalRaw):rest) = do
      let code = rstrip raw
          originalCode = rstrip originalRaw
          s = strip code
      if null s then go sec ms m rest else do
        case s of
          "init:" -> go SInit ms m rest
          "step:" -> go SStep ms m rest
          _ -> do
            let sec' = if take 1 code /= " " then STop else sec
            case sec' of
              STop
                | Just macroHead <- stripPrefix "macro " s ->
                    if definitionNeedsContinuation macroHead
                      then do
                        let (bodyLines, rest') = takeDefinitionBody rest
                        newMacro <- parseMacroDeclaration ln macroHead
                          [ (lineNumber, strip (rstrip translated))
                          | (lineNumber, translated, _) <- bodyLines
                          , not (null (strip translated)) ]
                        when (pmName newMacro `elem` map pmName ms) (fatal
                          ("macro '" ++ pmName newMacro
                           ++ "' is declared more than once (line "
                           ++ show ln ++ ")"))
                        go STop (ms ++ [newMacro]) m rest'
                      else fatal ("macro body must be an indented block of \
                                  \local bindings ending with 'in <expression>' (line "
                                  ++ show ln ++ ")")
              STop
                | Just definitionHead <- stripPrefix "def " s
                , definitionNeedsContinuation definitionHead ->
                    let (bodyLines, rest') = takeDefinitionBody rest
                    in case bodyLines of
                         [] -> fatal ("bad def (line " ++ show ln
                                      ++ "): a body must follow '='")
                         _ ->
                           let translatedBody = intercalate "\n" (deindentBlock
                                 [rstrip translatedLine
                                 | (_, translatedLine, _) <- bodyLines])
                               originalBodyLines =
                                 [(lineNumber, rstrip originalLine')
                                 | (lineNumber, _, originalLine') <- bodyLines]
                               combinedHead = definitionHead ++ " " ++ translatedBody
                           in addDefinition ln
                                (sourceTextForContinuationLines originalBodyLines)
                                combinedHead m
                              >>= \m' -> go STop ms m' rest'
              STop -> top ln originalCode s m >>= \m' -> go STop ms m' rest
              -- an init line may continue over following lines until its
              -- brackets balance (tensor initializers span rows)
              SInit | bal s > 0 ->
                let (more, moreSourceLines, rest') = grab (bal s) rest
                in ini ((ln, originalCode) : moreSourceLines)
                       (s ++ " " ++ more) m
                     >>= \m' -> go SInit ms m' rest'
              SInit -> ini [(ln, originalCode)] s m >>= \m' -> go SInit ms m' rest
              SStep | stepNeedsContinuation s ->
                let (more, moreSourceLines, rest') = grab (bal s) rest
                    sourceLines = (ln, originalCode) : moreSourceLines
                in stp sourceLines (s ++ " " ++ more) m
                     >>= \m' -> go SStep ms m' rest'
              SStep -> stp [(ln, originalCode)] code m
                >>= \m' -> go SStep ms m' rest

    bal t = sum [1 :: Int | c <- t, c `elem` "(["] - sum [1 | c <- t, c `elem` ")]"]

    definitionNeedsContinuation source =
      case break (== '=') source of
        (_, '=' : body) -> null (strip body)
        _ -> False

    stepNeedsContinuation source =
      bal source > 0
      || case break (== '=') source of
           (_, '=' : body) -> null (strip body)
           _ -> False

    takeDefinitionBody = collect []
      where
        collect accumulated [] = (reverse accumulated, [])
        collect accumulated remaining@((lineNumber, translated, original):rest)
          | null translatedCode = collect accumulated rest
          | firstCharacter : _ <- translated
          , isSpace firstCharacter =
              collect ((lineNumber, translated, original) : accumulated) rest
          | otherwise = (reverse accumulated, remaining)
          where
            translatedCode = strip (rstrip translated)

    deindentBlock lines' = map (drop commonIndent) lines'
      where
        commonIndent = case
          [length (takeWhile isSpace line) | line <- lines', not (null (strip line))] of
            [] -> 0
            indents -> minimum indents

    checkUserSurface m' locals context body =
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
      let t = strip (rstrip raw)
          original = rstrip originalRaw
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
      | Just r <- stripPrefix "discretization " s =
          parseDiscretizationDecl ln r >>= addDiscretizationDecl
      | Just r <- stripPrefix "boundary " s =
          parseBoundaryDecl ln r >>= addBoundaryDecl
      | Just r <- stripPrefix "def " s =
          addDefinition ln (sourceTextForRhs ln originalLine) r m
      | Just r <- stripPrefix "param " s =
          case break (== '=') r of
            (nm, '=':v) | not (null (strip nm)) && not (null (strip v)) -> do
              let parameterName = strip nm
              if not (validSurfaceName parameterName)
                then fatal ("bad param name: " ++ parameterName ++ " (line "
                            ++ show ln ++ ")")
                else do
                  rejectReservedName ln parameterName
                  rejectRawConstant ln "parameter value" (strip v)
                  return m
                    { mParams = (parameterName, strip v) : mParams m
                    , mParamSourceLines = ln : mParamSourceLines m
                    }
            _ -> fatal ("bad param (line " ++ show ln ++ ")")
      | Just r <- stripPrefix "extern " s =
          return m
            { mHelp = ("extern function :: " ++ strip r) : mHelp m
            , mHelpKinds = ExternalHelper : mHelpKinds m
            , mHelpSourceLines = ln : mHelpSourceLines m
            }
      | s == "raw" = return m
          { mHelp = "" : mHelp m
          , mHelpKinds = RawHelper : mHelpKinds m
          , mHelpSourceLines = ln : mHelpSourceLines m
          }
      | Just r <- stripPrefix "raw " s = return m
          { mHelp = r : mHelp m
          , mHelpKinds = RawHelper : mHelpKinds m
          , mHelpSourceLines = ln : mHelpSourceLines m
          }
      | Just r <- stripPrefix "field " s =
          parseFieldDecl ln r >>= addField
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
          in if mMetricName m /= Nothing
               then fatal ("metric name may be declared only once (line "
                           ++ show ln ++ ")")
               else if not (validSurfaceName nm)
               then fatal ("bad metric name: " ++ nm ++ " (line " ++ show ln ++ ")")
               else if nm `elem` mAxes m
                 then fatal ("metric name '" ++ nm
                             ++ "' conflicts with a coordinate axis (line "
                             ++ show ln ++ ")")
               else if nm == "δ"
                 then fatal "metric δ is reserved for Kronecker delta; use metric g for the metric tensor"
               else if nm `elem` generatedMetricNameConflicts
                 then fatal ("metric name '" ++ nm
                             ++ "' is reserved for the generated Egison environment (line "
                             ++ show ln ++ ")")
               else do
                 rejectReservedName ln nm
                 if any ((== nm) . defName) (mDefs m)
                   then fatal ("definition name '" ++ nm
                               ++ "' conflicts with generated metric value '"
                               ++ nm ++ "' (line " ++ show ln ++ ")")
                   else return m { mMetricName = Just nm }
      | Just r <- stripPrefix "dimension " s = dim r
      | Just r <- stripPrefix "axes " s =
          return m
            { mAxes = map strip (splitTop ',' r)
            , mAxesSourceLine = Just ln
            }
      | otherwise = fatal ("unrecognized: " ++ s ++ " (line " ++ show ln ++ ")")
      where
        setMode mode =
          case mMode m of
            Nothing -> return m { mMode = Just mode }
            Just _ -> fatal ("mode may be declared only once (line " ++ show ln ++ ")")
        addField fd =
          return m { mFieldDecls = fd : mFieldDecls m }
        addDiscretizationDecl declaration =
          let key value =
                (discretizationLatticeClass value,
                 discretizationDerivativeOrder value)
          in if any ((== key declaration) . key) (mDiscretizationDecls m)
               then fatal ("duplicate discretization rule (line " ++ show ln ++ ")")
               else return m
                 { mDiscretizationDecls = declaration : mDiscretizationDecls m }
        addBoundaryDecl declaration =
          if any ((== boundaryAxisName declaration) . boundaryAxisName)
               (mBoundaryDecls m)
            then fatal ("duplicate boundary declaration for axis '"
                        ++ boundaryAxisName declaration ++ "' (line "
                        ++ show ln ++ ")")
            else return m
              { mBoundaryDecls = declaration : mBoundaryDecls m }
        dim r | all isDigit (strip r), n <- read (strip r) =
                  if n < (1 :: Int) || n > 3
                    then fatal ("Formurae currently supports dimension 1, 2, or 3 (got "
                                ++ show n ++ ")")
                    else return m { mDim = n }
              | otherwise = fatal ("bad dimension (line " ++ show ln ++ ")")

    addDefinition ln sourceBuilder source m
      | not (null (snd (parseIndexedIdent (definitionHeadToken source)))) =
          fatal ("result indices are not allowed in user definition heads; "
                 ++ "write the metric contraction in an indexed equation or "
                 ++ "local binding (line " ++ show ln ++ ")")
      | otherwise = case defForm source of
        Just df -> do
          rejectReservedName ln (defName df)
          case mMetricName m of
            Just metricName | metricName == defName df ->
              fatal ("definition name '" ++ defName df
                     ++ "' conflicts with generated metric value '"
                     ++ metricName ++ "' (line " ++ show ln ++ ")")
            _ -> return ()
          mapM_ (rejectReservedName ln) (defParams df)
          case [parameterName | parameter <- defParams df
                     , let parameterName = defParamBase parameter
                     , parameterName `elem` ambientNames] of
            [] -> return ()
            parameterName : _ ->
              fatal ("definition parameter '" ++ parameterName
                     ++ "' is reserved for the ambient Egison environment (line "
                     ++ show ln ++ ")")
          case [parameterName | parameter <- defParams df
                     , let parameterName = defParamBase parameter
                     , parameterName `elem` generatedIndexNames] of
            [] -> return ()
            parameterName : _ ->
              fatal ("definition parameter '" ++ parameterName
                     ++ "' is reserved for generated index symbols (line "
                     ++ show ln ++ ")")
          case [parameterName | parameter <- defParams df
                     , let parameterName = defParamBase parameter
                     , parameterName `elem` mathematicalConstantNames] of
            [] -> return ()
            parameterName : _ ->
              fatal ("definition parameter '" ++ parameterName
                     ++ "' cannot shadow the symbolic constant π (line "
                     ++ show ln ++ ")")
          case [parameterName | parameter <- defParams df
                     , let parameterName = defParamBase parameter
                     , parameterName `elem` definitionParameterGeneratedNames] of
            [] -> return ()
            parameterName : _ ->
              fatal ("definition parameter '" ++ parameterName
                     ++ "' is reserved for generated Egison code (line "
                     ++ show ln ++ ")")
          definitionSource <- sourceBuilder (defBody df)
          return m
            { mDefs = df { defSourceText = Just definitionSource } : mDefs m }
        Nothing -> fatal ("bad def (line " ++ show ln
                          ++ "): def NAME ARG... = EXPR")

    definitionHeadToken = takeWhile (\c -> not (isSpace c) && c /= '=') . strip

    -- Standard mathematical operators remain legal higher-order formals.
    -- Only Egison syntax and the unqualified names inserted inside this
    -- definition's generated parameter checks must be protected from capture.
    -- Dependencies used by separate top-level generated definitions do not
    -- occur in this lexical scope.  Ambient values, index symbols, and π are
    -- checked above so their specific diagnostics remain.
    definitionParameterGeneratedNames = nub
      (generatedNormalizationNames
       ++ egisonReservedWords
       ++ ["assert", "tensorShape", "bool"])

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
          rejectRawConstant ln "raw initializer" rhs
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

    -- Step equations keep superscripts (~i) and subscripts (_i) distinct.
    -- formurae-pre preserves that variance in the logical tensor type; Egison
    -- evaluates the indexed equation and formurae-post alone projects storage.
    stp sourceLines s0 m
      | Just bad <- banned =
          fatal (bad ++ " (line " ++ show ln ++ ")")
      | Just (target, ex) <- eqForm "let" s = do
          rejectReservedName ln (indexedTargetName target)
          source <- sourceTextForRhsLines sourceLines ex
          return m { mSteps = Step KLet target Nothing ex source : mSteps m }
      | Just localSource <- stripPrefix "local " s = do
          (declaration, target, ex) <- localForm ln localSource
          rejectReservedName ln (indexedTargetName target)
          source <- sourceTextForRhsLines sourceLines ex
          return m
            { mSteps = Step KLocal target (Just declaration) ex source
                : mSteps m
            }
      | Just (target, ex) <- primeEqForm s = do
          rejectReservedName ln (indexedTargetName target)
          source <- sourceTextForRhsLines sourceLines ex
          return m { mSteps = Step KEq target Nothing ex source : mSteps m }
      | otherwise = fatal ("bad step eq: " ++ s ++ " (line " ++ show ln ++ ")")
      where
        ln = case sourceLines of
          (lineNumber, _) : _ -> lineNumber
          [] -> 0
        s = strip s0
        banned = surfaceBanned m [] s

    sourceTextForRhs ln originalLine translatedExpression = do
      sourceTextForRhsLines [(ln, originalLine)] translatedExpression

    sourceTextForRhsLines sourceLines =
      sourceTextForPieces "\n" " " (sourcePieces sourceLines)

    sourceTextForContinuationLines sourceLines =
      sourceTextForPieces "\n" "\n" (continuationPieces sourceLines)

    sourceTextForPieces originalSeparator translatedSeparator pieces translatedExpression = do
      let originalExpression = intercalate originalSeparator
            [text | (_, _, text) <- pieces]
          translatedPieces = map translatePiece pieces
          translated = intercalate translatedSeparator
            [text | (text, _) <- translatedPieces]
          positions = intercalatePositions translatedSeparator pieces translatedPieces
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

    sourcePieces [] = []
    sourcePieces ((lineNumber, originalLine) : rest) =
      case assignmentRhs originalLine of
        "" -> map continuationPiece rest
        rhs -> (lineNumber, rhsStartColumn originalLine, rhs)
          : map continuationPiece rest

    continuationPiece (lineNumber, originalLine) =
      let text = strip originalLine
          column = length (takeWhile isSpace originalLine) + 1
      in (lineNumber, column, text)

    continuationPieces sourceLines =
      [ (lineNumber, commonIndent + 1, drop commonIndent originalLine)
      | (lineNumber, originalLine) <- sourceLines
      ]
      where
        commonIndent = case
          [length (takeWhile isSpace line)
          | (_, line) <- sourceLines, not (null (strip line))] of
            [] -> 0
            indents -> minimum indents

    translatePiece (lineNumber, column, original) =
      let (translated, offsets) = transliterateWithMap original
      in (translated,
          [SourcePosition lineNumber (column + offset - 1)
          | offset <- offsets])

    rejectRawConstant line context expression =
      case rawConstantUse expression of
        Nothing -> return ()
        Just spelling -> fatal
          (context ++ " cannot use " ++ spelling
           ++ " because it bypasses symbolic FEIR; use a numeric backend value"
           ++ (if context == "raw initializer" then " or ':='" else "")
           ++ " (line " ++ show line ++ ")")

    intercalatePositions _ _ [] = []
    intercalatePositions _ _ [(_, positions)] = positions
    intercalatePositions separator (_ : nextPiece : restPieces)
                         ((_, positions) : restTranslated) =
      positions ++ replicate (length separator) (separatorPosition nextPiece)
      ++ intercalatePositions separator (nextPiece : restPieces) restTranslated
    intercalatePositions _ _ translatedPieces =
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
surfaceBanned m _ s =
  foldr (\t acc -> checkTok t `orElse` acc) Nothing (tokenize s)
  `orElse`
  foldr (\t acc -> checkIndexTok t `orElse` acc) Nothing (itok s)
  where
    checkTok (TId nm primed)
      | baseName == "pi" =
          Just "ASCII 'pi' is a floating-point Egison value; write Unicode π for the symbolic circle constant"
      | baseName == "π", primed =
          Just "symbolic constant π cannot be primed"
      | baseName == "π", not (null indexedParts) =
          Just "symbolic constant π is scalar and cannot carry tensor indices"
      | Just msg <- invalidDerivativeOp m nm =
          Just msg
      | Just msg <- invalidAxisProjection m baseName indexedParts =
          Just msg
      | nm == "badPartialDerivative" =
          Just "coordinate derivative must be written with subscript notation, e.g. ∂_x u, ∂^2_x u, or ∂'^2_x u"
      | ("FormuraeInternalKroneckerDelta" : ps) <- splitOn '_' nm
      , any ((> 1) . length) ps =
          Just ("Kronecker delta takes one index per mark (δ~i_j): " ++ nm)
      where
        (baseName, indexedParts) = parseIndexedIdent nm
    checkTok _ = Nothing
    checkIndexTok (II nm) =
      case parseIndexedIdent nm of
        ("FormuraeInternalKroneckerDelta", parts@(_:_))
          | not (length parts == 2 && all isAlphaNumIx parts
                 && hasOppositeVariances parts) ->
              Just ("Kronecker delta takes one upper and one lower marked index, e.g. δ~i_j or δ_i~1: " ++ nm)
        ("epsilon", parts@(_:_))
          | not (length parts == mDim m && all isSingleAlphaIx parts) ->
              Just ("epsilon takes " ++ show (mDim m)
                    ++ " single marked indices in this model: " ++ nm)
        _ -> Nothing
    checkIndexTok _ = Nothing
    isAlphaNumIx (IxPart _ ix) = not (null ix) && all isAlphaNum ix
    hasOppositeVariances [IxPart first _, IxPart second _] = first /= second
    hasOppositeVariances _ = False
    orElse (Just x) _ = Just x
    orElse Nothing y = y

rawConstantUse :: String -> Maybe String
rawConstantUse source =
  case [base | TId name _ <- tokenize source
             , let (base, _) = parseIndexedIdent name
             , base `elem` mathematicalConstantNames] of
    spelling : _ -> Just spelling
    [] -> Nothing

firstAmbientName :: [String] -> Maybe String
firstAmbientName [] = Nothing
firstAmbientName (name : rest)
  | name `elem` ambientNames = Just name
  | otherwise = firstAmbientName rest

generatedMetricNameConflicts :: [String]
generatedMetricNameConflicts = nub
  (generatedNormalizationNames
   ++ generatedIndexNames
   ++ standardNames
   ++ scalarIntrinsics
   ++ egisonReservedWords
   ++ normalizationDependencies)

invalidDerivativeOp :: Model -> String -> Maybe String
invalidDerivativeOp _ nm =
  case derivativeOpParts nm of
    Nothing ->
      -- The sbpd spelling is retired: the boundary treatment is an axis
      -- property, so the opaque per-call operator became a declaration.
      case sbpOpParts nm of
        Just _ ->
          Just (nm ++ " is retired: declare the boundary (boundary AXIS : sbp)"
                ++ " and write the plain derivative"
                ++ " (∂_x for sbpd_x, ∂^2_x for sbpd2_x)")
        _ -> Nothing
    Just (ordr, radius, part)
      | ordr < 1 ->
          Just ("coordinate derivative order must be at least 1: " ++ nm)
      | radius < 1 ->
          Just ("coordinate derivative stencil radius must be at least 1: " ++ nm)
      | ordr >= 2 * radius + 1 ->
          Just ("coordinate derivative ∂" ++ show ordr ++ "," ++ show radius ++ ixName part
                ++ " has too few stencil points")
      | otherwise -> Nothing
-- Unicode input: Greek letters transliterate to their ASCII names except
-- mathematical π (and the already-special δ), whose spelling carries CAS
-- semantics and therefore remains Unicode.  A
-- decorated partial-derivative sign is a coordinate derivative:
-- `∂_x u`, `∂^2_x u`, `∂'^2_x u`.  A plain marked partial (`∂_i` or
-- `∂~i`) remains the indexed derivative when the mark is not a declared
-- axis.  A bare partial sign still becomes d.  The small delta remains
-- Unicode so the canonical codifferential cannot collide with an ASCII user
-- identifier.  The source spelling Delta-sub-H is mapped to one atomic
-- identifier before underscore can be read as a tensor index.  The minus
-- sign becomes '-'.
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
    go offset ('\916':'_':'H':cs) =
      appendMapped offset 3 "ΔH" cs
    -- Indexed small delta is the Kronecker tensor and retains its historical
    -- hygienic trusted spelling.  Only the unindexed glyph denotes the
    -- canonical codifferential.  In particular, an ordinary user definition
    -- named `delta` must not capture the Kronecker tensor after translation.
    go offset ('\948':rest@(mark:_))
      | mark == '_' || mark == '~' =
          appendMapped offset 1 "FormuraeInternalKroneckerDelta" rest
    go offset ('\948':cs) = appendMapped offset 1 "δ" cs
    -- `∂/∂` is the analytic coordinate derivative (the Egison spelling);
    -- it must be claimed before the decorated/discrete ∂ forms below.
    go offset ('\8706':'/':'\8706':cs) =
      appendMapped offset 3 analyticDerivativeName cs
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
    tr '\960' = "π"        -- π remains Egison's symbolic MathValue constant
    tr '\948' = "δ"        -- δ remains distinct from ASCII delta
    tr '\8722' = "-"       -- − (minus sign)
    tr c = [c]


-- === Surface macros =========================================================
--
-- A macro is a generation-time template: zero or more local bindings and one
-- result expression.  A call inside a step expression expands before any
-- other analysis; the locals are lifted, with fresh names, to just before
-- the enclosing step action (let-insertion), and the call is replaced by the
-- result expression.  Downstream passes never see macros.

data PreMacro = PreMacro
  { pmName   :: String
  , pmParams :: [String]
  , pmLocals :: [(Int, String)]
  , pmResult :: (Int, String)
  , pmLine   :: Int
  }

-- On declared geometry the canonical Δ and δ are prelude macros: the
-- weighted flux is materialized by a lifted step local (on the staggered
-- lattice, exactly where the conservative scheme stores it) and the
-- signed adjoint divergence closes the form; constant geometry keeps
-- the analytic operator path.  Users cannot collide with these names:
-- 'δ' and 'Δ' are not valid surface macro names.
-- A user binding of the same name shadows the prelude, exactly as user
-- definitions shadow the canonical operators.
activePreludeMacros :: Model -> [PreMacro]
activePreludeMacros model =
  [ prelude
  | prelude <- preludeMacros model
  , pmName prelude `notElem` boundNames
  ]
  where
    boundNames =
      mAxes model
      ++ map fst (mParams model)
      ++ map fdName (mFieldDecls model)
      ++ map defName (mDefs model)
      ++ map sNm (mSteps model)
      ++ maybe [] (: []) (mMetricName model)

preludeMacros :: Model -> [PreMacro]
preludeMacros model =
  geometryPreludeMacros model ++ boundaryPreludeMacros model

-- The penalty (SAT) idioms of a declared sbp axis: Dirichlet damping on
-- both walls and the Neumann flux substitution through the boundary
-- extrapolation sbpx.  The bodies compose the declaration's supplied
-- constants, so the only hand-written ingredients left are the data and
-- the physical strength.
boundaryPreludeMacros :: Model -> [PreMacro]
boundaryPreludeMacros model = concat
  [ [ PreMacro
        { pmName = "satDirichlet_" ++ axis
        , pmParams = ["u", "g", "coef"]
        , pmLocals = []
        , pmResult = (0, dirichletBody axis)
        , pmLine = 0
        }
    , PreMacro
        { pmName = "satNeumann_" ++ axis
        , pmParams = ["flux", "glo", "ghi"]
        , pmLocals = []
        , pmResult = (0, neumannBody axis)
        , pmLine = 0
        }
    ]
  | declaration <- mBoundaryDecls model
  , boundaryKind declaration == SurfaceSbpBoundary
  , let axis = boundaryAxisName declaration
  ]
  where
    dirichletBody axis =
      "((if " ++ axis ++ " < sbpLo" ++ sbpAxisSuffix axis
      ++ " then 0.0 - coef*(u - g) else 0.0)"
      ++ " + (if " ++ axis ++ " > sbpHi" ++ sbpAxisSuffix axis
      ++ " then 0.0 - coef*(u - g) else 0.0))"
    neumannBody axis =
      "((if " ++ axis ++ " < sbpLo" ++ sbpAxisSuffix axis
      ++ " then sbpHinv" ++ sbpAxisSuffix axis ++ "*(sbpx_" ++ axis
      ++ " flux - glo) else 0.0)"
      ++ " + (if " ++ axis ++ " > sbpHi" ++ sbpAxisSuffix axis
      ++ " then 0.0 - sbpHinv" ++ sbpAxisSuffix axis ++ "*(sbpx_" ++ axis
      ++ " flux - ghi) else 0.0))"

-- The weights local carries only geometry (dFluxWeights reads its operand
-- solely for the degree), so the backend can freeze it into an init-time
-- coefficient field; the flux local then contains no position-dependent
-- arithmetic, exactly the shape the shifting-frame code generator expects.
geometryPreludeMacros :: Model -> [PreMacro]
geometryPreludeMacros model
  | mMetric model == Nothing && mEmbed model == Nothing = []
  | otherwise =
      [ PreMacro
          { pmName = "δ"
          , pmParams = ["A"]
          , pmLocals =
              [ (0, "codiffCoeff : tensor @ primal = dFluxWeights A")
              , (0, "codiffFlux : tensor @ primal = dFluxScale codiffCoeff A")
              ]
          , pmResult = (0, "dFluxDiv codiffFlux")
          , pmLine = 0
          }
      , PreMacro
          { pmName = "Δ"
          , pmParams = ["u"]
          , pmLocals =
              [ (0, "deltaCoeff : tensor @ primal = dFluxWeights (dExterior u)")
              , (0, "deltaFlux : tensor @ primal = dFluxScale deltaCoeff (dExterior u)")
              ]
          , pmResult = (0, "0 - dFluxDiv deltaFlux")
          , pmLine = 0
          }
      ]

macroBalance :: String -> Int
macroBalance t =
  sum [1 :: Int | c <- t, c `elem` "(["] - sum [1 | c <- t, c `elem` ")]"]

-- Join physical body lines into logical lines: a line whose brackets stay
-- open continues on the next line, exactly as step equations do.
macroLogicalLines :: [(Int, String)] -> [(Int, String)]
macroLogicalLines [] = []
macroLogicalLines ((ln0, t0) : rest0) = collect ln0 t0 (macroBalance t0) rest0
  where
    collect ln acc depth rest
      | depth <= 0 = (ln, acc) : macroLogicalLines rest
      | otherwise = case rest of
          [] -> [(ln, acc)]
          (_, t) : rest' -> collect ln (acc ++ " " ++ t) (depth + macroBalance t) rest'

parseMacroDeclaration :: Int -> String -> [(Int, String)] -> IO PreMacro
parseMacroDeclaration ln headSource bodyLines = do
  (name, parameters) <- case break (== '=') headSource of
    (before, '=' : after) | null (strip after) ->
      case words before of
        name : parameters -> pure (name, parameters)
        [] -> fatal ("macro needs a name (line " ++ show ln ++ ")")
    _ -> fatal ("bad macro head (line " ++ show ln ++ ")")
  when (not (validSurfaceName name))
    (fatal ("bad macro name: " ++ name ++ " (line " ++ show ln ++ ")"))
  rejectReservedName ln name
  mapM_ (\parameter -> do
          when (not (validSurfaceName parameter))
            (fatal ("bad macro parameter: " ++ parameter
                    ++ " (line " ++ show ln ++ ")"))
          rejectReservedName ln parameter)
    parameters
  when (length (nub parameters) /= length parameters)
    (fatal ("macro parameters must be distinct (line " ++ show ln ++ ")"))
  (locals, result) <- splitBody [] (macroLogicalLines bodyLines)
  pure PreMacro
    { pmName = name
    , pmParams = parameters
    , pmLocals = locals
    , pmResult = result
    , pmLine = ln
    }
  where
    splitBody accumulated ((lineNumber, line) : rest)
      | Just localSource <- stripPrefix "local " line =
          splitBody (accumulated ++ [(lineNumber, strip localSource)]) rest
      | Just resultSource <- stripPrefix "in " line =
          case rest of
            [] -> pure (accumulated, (lineNumber, strip resultSource))
            _ -> fatal ("macro body must end with its 'in <expression>' line (line "
                        ++ show lineNumber ++ ")")
      | otherwise = fatal
          ("macro body lines must be 'local <binding>' or 'in <expression>': "
           ++ line ++ " (line " ++ show lineNumber ++ ")")
    splitBody _ [] = fatal
      ("macro body needs a final 'in <expression>' line (line " ++ show ln ++ ")")

-- Expand every macro call in the step expressions of an ordered model.
expandMacros :: [PreMacro] -> Model -> IO Model
expandMacros [] model = pure model
expandMacros macros model = do
  mapM_ rejectValueCollision macros
  mapM_ rejectNonStepUse nonStepContexts
  (_, expandedSteps) <- foldM expandStep (initialUsed, []) (mSteps model)
  pure model { mSteps = concat (reverse expandedSteps) }
  where
    macrosByName = [(pmName mc, mc) | mc <- macros]

    modelValueNames =
      mAxes model
      ++ internalCoordNames model
      ++ map fst (mParams model)
      ++ map fdName (mFieldDecls model)
      ++ map defName (mDefs model)
      ++ map sNm (mSteps model)
      ++ maybe [] (: []) (mMetricName model)

    initialUsed = nub
      (modelValueNames
       ++ map pmName macros
       ++ standardNames ++ scalarIntrinsics ++ egisonReservedWords
       ++ generatedIndexNames ++ generatedNormalizationNames
       ++ normalizationDependencies)

    rejectValueCollision mc =
      when (pmName mc `elem` modelValueNames) (fatal
        ("macro name '" ++ pmName mc
         ++ "' conflicts with another value binding (line "
         ++ show (pmLine mc) ++ ")"))

    nonStepContexts =
      [("def " ++ defName df, defBody df) | df <- mDefs model]
      ++ [("init expression", text) | it <- mInits model, text <- initTexts it]
      ++ [("metric scale expression", text)
         | text <- maybe [] id (mMetric model)]
      ++ [("embedding expression", text) | text <- maybe [] id (mEmbed model)]

    initTexts it = case it of
      IRaw _ text -> [text]
      IVec _ texts -> texts
      ISym _ texts -> texts
      IAnti _ texts -> texts
      ITensor2 _ texts -> texts
      ICas _ text -> [text]
      ICasIndex _ _ text -> [text]

    rejectNonStepUse (context, text) =
      case [name | name <- egisonIdentifiers text
                 , name `elem` map pmName macros] of
        name : _ -> fatal
          ("macro '" ++ name ++ "' expands to step statements; it cannot be "
           ++ "used in " ++ context)
        [] -> pure ()

    expandStep (used, expanded) step = do
      ast <- case parseTensorExprEither (sEx step) of
        Right value -> pure value
        Left message -> fatal
          ("macro expansion cannot parse step expression: " ++ sEx step
           ++ " (" ++ message ++ ")")
      (used', lifted, ast') <- expandNode (0 :: Int) (callSiteOf step) used ast
      -- A pure-expression macro lifts no locals, so the rewrite is
      -- detected from the call spelling itself; steps without any macro
      -- call keep their original text and source map.
      let usesMacro = any (`elem` map pmName macros)
            [name | TId name _ <- tokenize (sEx step)]
          step'
            | null lifted && not usesMacro = step
            | otherwise = step
                { sEx = renderTensorExpr ast'
                , sSourceText = syntheticSource (callSiteOf step)
                    (renderTensorExpr ast')
                }
      pure (used', (lifted ++ [step']) : expanded)

    callSiteOf step =
      ( sourcePath (sSourceText step)
      , sourceLine (sSourceText step)
      , sourceColumn (sSourceText step)
      )

    syntheticSource (path, line, column) text = SourceText
      { sourcePath = path
      , sourceLine = line
      , sourceColumn = column
      , sourceOriginal = text
      , sourceTranslated = text
      , sourcePositionMap = [SourcePosition line column | _ <- text]
      }

    freshName used base = go' (base : [base ++ show k | k <- [(2 :: Int) ..]])
      where
        go' (candidate : rest)
          | candidate `notElem` used && validSurfaceName candidate = candidate
          | otherwise = go' rest
        go' [] = base

    -- Bottom-up expansion: children first, then this node if it is a call.
    expandNode depth site used expression = do
      when (depth > 32) (fatal
        "macro expansion did not terminate; recursive macros are not supported")
      case expression of
        -- Axis-suffixed macro names (satNeumann_x) parse as an indexed
        -- head, so the lookup key is the complete spelling.
        TEApply (TEIdent name parts) arguments
          | Just mc <- lookup (name ++ concatMap ixSuffix parts)
              macrosByName ->
              expandCall depth site used mc arguments
        TECall (TEIdent name parts) arguments
          | Just mc <- lookup (name ++ concatMap ixSuffix parts)
              macrosByName ->
              expandCall depth site used mc arguments
        _ -> descend expression
      where
        descend node = case node of
          TENumber _ -> pure (used, [], node)
          TEIdent _ _ -> pure (used, [], node)
          TEUnary op body -> wrap1 (TEUnary op) body
          TECall f args -> wrapN TECall f args
          TEApply f args -> wrapN TEApply f args
          TEIf c t e -> do
            (u1, l1, c') <- expandNode depth site used c
            (u2, l2, t') <- expandNode depth site u1 t
            (u3, l3, e') <- expandNode depth site u2 e
            pure (u3, l1 ++ l2 ++ l3, TEIf c' t' e')
          TEAppendIndexed body parts -> wrap1 (\b -> TEAppendIndexed b parts) body
          TEWithSymbols names body -> wrap1 (TEWithSymbols names) body
          TEContractWith reducer body -> wrap1 (TEContractWith reducer) body
          TETensorMap f body -> do
            (u1, l1, f') <- expandNode depth site used f
            (u2, l2, body') <- expandNode depth site u1 body
            pure (u2, l1 ++ l2, TETensorMap f' body')
          TESubrefs body parts -> wrap1 (\b -> TESubrefs b parts) body
          TETranspose names body -> wrap1 (TETranspose names) body
          TEDisjoint parts -> wrapList TEDisjoint parts
          TEDerivative parts body -> wrap1 (TEDerivative parts) body
          TEGridDerivativeChain parts body ->
            wrap1 (TEGridDerivativeChain parts) body
          TETensorLiteral elements parts ->
            wrapList (\es -> TETensorLiteral es parts) elements
          TEDot parts -> wrapList TEDot parts
          TEBinary op lhs rhs -> do
            (u1, l1, lhs') <- expandNode depth site used lhs
            (u2, l2, rhs') <- expandNode depth site u1 rhs
            pure (u2, l1 ++ l2, TEBinary op lhs' rhs')
          TEGroup body -> wrap1 TEGroup body
        wrap1 rebuild body = do
          (u1, l1, body') <- expandNode depth site used body
          pure (u1, l1, rebuild body')
        wrapN rebuild f args = do
          (u1, l1, f') <- expandNode depth site used f
          (u2, l2, args') <- foldM
            (\(u, ls, done) a -> do
              (u', l', a') <- expandNode depth site u a
              pure (u', ls ++ l', done ++ [a']))
            (u1, [], []) args
            >>= \(u, ls, done) -> pure (u, ls, done)
          pure (u2, l1 ++ l2, rebuild f' args')
        wrapList rebuild parts = do
          (u2, l2, parts') <- foldM
            (\(u, ls, done) a -> do
              (u', l', a') <- expandNode depth site u a
              pure (u', ls ++ l', done ++ [a']))
            (used, [], []) parts
          pure (u2, l2, rebuild parts')

    expandCall depth site used mc arguments = do
      -- arguments first, innermost lifts first
      (used1, argumentLifts, arguments') <- foldM
        (\(u, ls, done) a -> do
          (u', l', a') <- expandNode depth site u a
          pure (u', ls ++ l', done ++ [a']))
        (used, [], []) arguments
      when (length arguments' /= length (pmParams mc)) (fatal
        ("macro '" ++ pmName mc ++ "' expects "
         ++ show (length (pmParams mc)) ++ " argument(s), got "
         ++ show (length arguments')))
      checkBinderCapture mc arguments'
      let parameterSubst = zip (pmParams mc) arguments'
      (used2, localLifts, renames) <- foldM
        (\(u, ls, rns) (localLine, localText) -> do
          (declaration, target, rhsText) <- localForm localLine localText
          let fresh = freshName u (indexedTargetName target)
          rhsAst <- parseMacroPiece mc rhsText
          rhsAst' <- substituteIdents mc parameterSubst rns rhsAst
          (u', innerLifts, rhsAst'') <-
            expandNode (depth + 1) site (fresh : u) rhsAst'
          let liftedStep = Step
                { sk = KLocal
                , sTarget = target { indexedTargetName = fresh }
                , sLocalDecl = Just declaration { ldName = fresh }
                , sEx = renderTensorExpr rhsAst''
                , sSourceText = syntheticSource site
                    (renderTensorExpr rhsAst'')
                }
          pure (u', ls ++ innerLifts ++ [liftedStep]
               , rns ++ [(indexedTargetName target, fresh)]))
        (used1, [], []) (pmLocals mc)
      resultAst <- parseMacroPiece mc (snd (pmResult mc))
      resultAst' <- substituteIdents mc parameterSubst renames resultAst
      (used3, resultLifts, resultAst'') <-
        expandNode (depth + 1) site used2 resultAst'
      pure ( used3
           , argumentLifts ++ localLifts ++ resultLifts
           , TEGroup resultAst''
           )

    parseMacroPiece mc text = case parseTensorExprEither text of
      Right value -> pure value
      Left message -> fatal
        ("bad expression in macro '" ++ pmName mc ++ "' (line "
         ++ show (pmLine mc) ++ "): " ++ message)

    -- v1 hygiene guard: a macro body may bind index symbols with
    -- withSymbols; reject arguments that mention those symbols instead of
    -- silently capturing them.
    checkBinderCapture mc arguments = do
      binders <- collectBinders
      let argumentIndexNames = nub (concatMap indexNames arguments)
          captured = [b | b <- binders, b `elem` argumentIndexNames]
      case captured of
        b : _ -> fatal
          ("macro '" ++ pmName mc ++ "' binds index symbol '" ++ b
           ++ "' that also appears in an argument; rename the index at the "
           ++ "call site")
        [] -> pure ()
      where
        collectBinders = do
          localRhs <- mapM
            (\(localLine, localText) -> do
              (_, _, rhsText) <- localForm localLine localText
              pure rhsText)
            (pmLocals mc)
          pieces <- mapM (parseMacroPiece mc)
            (localRhs ++ [snd (pmResult mc)])
          pure (nub (concatMap withSymbolBinders pieces))
        withSymbolBinders node = case node of
          TEWithSymbols names body -> names ++ withSymbolBinders body
          _ -> concatMap withSymbolBinders (childrenOf node)
        indexNames node =
          [nm | IxPart _ nm <- partsOf node]
          ++ concatMap indexNames (childrenOf node)
        partsOf node = case node of
          TEIdent _ parts -> parts
          TEAppendIndexed _ parts -> parts
          TESubrefs _ parts -> parts
          TEDerivative parts _ -> parts
          TEGridDerivativeChain parts _ -> parts
          TETensorLiteral _ parts -> parts
          _ -> []
        childrenOf node = case node of
          TEUnary _ b -> [b]
          TECall f args -> f : args
          TEApply f args -> f : args
          TEIf c t e -> [c, t, e]
          TEAppendIndexed b _ -> [b]
          TEWithSymbols _ b -> [b]
          TEContractWith _ b -> [b]
          TETensorMap f b -> [f, b]
          TESubrefs b _ -> [b]
          TETranspose _ b -> [b]
          TEDisjoint parts -> parts
          TEDerivative _ b -> [b]
          TEGridDerivativeChain _ b -> [b]
          TETensorLiteral elements _ -> elements
          TEDot parts -> parts
          TEBinary _ lhs rhs -> [lhs, rhs]
          TEGroup b -> [b]
          _ -> []

    substituteIdents mc parameterSubst renames = rewrite
      where
        rewrite node = case node of
          TEIdent name parts
            | Just replacement <- lookup name parameterSubst ->
                if null parts
                  then pure (TEGroup replacement)
                  else fatal
                    ("macro parameter '" ++ name ++ "' of '" ++ pmName mc
                     ++ "' cannot take index suffixes; bind it with a local "
                     ++ "first")
            | Just fresh <- lookup name renames ->
                pure (TEIdent fresh parts)
            | otherwise -> pure node
          TENumber _ -> pure node
          TEUnary op b -> TEUnary op <$> rewrite b
          TECall f args -> TECall <$> rewrite f <*> mapM rewrite args
          TEApply f args -> TEApply <$> rewrite f <*> mapM rewrite args
          TEIf c t e -> TEIf <$> rewrite c <*> rewrite t <*> rewrite e
          TEAppendIndexed b parts ->
            (\b' -> TEAppendIndexed b' parts) <$> rewrite b
          TEWithSymbols names b -> TEWithSymbols names <$> rewrite b
          TEContractWith reducer b -> TEContractWith reducer <$> rewrite b
          TETensorMap f b -> TETensorMap <$> rewrite f <*> rewrite b
          TESubrefs b parts -> (\b' -> TESubrefs b' parts) <$> rewrite b
          TETranspose names b -> TETranspose names <$> rewrite b
          TEDisjoint parts -> TEDisjoint <$> mapM rewrite parts
          TEDerivative parts b -> TEDerivative parts <$> rewrite b
          TEGridDerivativeChain parts b ->
            TEGridDerivativeChain parts <$> rewrite b
          TETensorLiteral elements parts ->
            (\es -> TETensorLiteral es parts) <$> mapM rewrite elements
          TEDot parts -> TEDot <$> mapM rewrite parts
          TEBinary op lhs rhs -> TEBinary op <$> rewrite lhs <*> rewrite rhs
          TEGroup b -> TEGroup <$> rewrite b
