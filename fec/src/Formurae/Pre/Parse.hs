-- Parse and validate Formurae's mathematical surface language.
--
-- This is intentionally only a front-end parser.  It preserves analytic
-- tensor expressions and exact source maps for pre-fec; Egison performs
-- continuum normalization and post-fec selects discrete implementations.
module Formurae.Pre.Parse
  ( parseModel
  ) where

import Data.Char (isAlpha, isAlphaNum, isDigit, isSpace)
import Data.List (dropWhileEnd, intercalate, nub, sort, stripPrefix, isSuffixOf)

import Formurae.Common
import Formurae.Index
import Formurae.Syntax

-- Names provided by the continuum normalization libraries.  They are reserved
-- tensor operators or values and cannot be reused by surface value bindings.
standardNames :: [String]
standardNames =
  [ ".", "wedge", "trace", "sym", "antisym", "norm2"
  , "hessian", "grad", "dGrad", "divg", "curl", "lap", "Δ"
  , "d", "δ", "hodge", "ΔH"
  , "flat", "sharp"
  , "resample"
  , "epsilon"
  ]

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
  , "feContinuumDD", "feContinuumAssertions", "main"
  ]

normalizationDependencies :: [String]
normalizationDependencies =
  [ "print", "nth", "foldl", "map", "sum", "product", "sqrt"
  , "contractWith"
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
parseFieldDecl = parseStorageDecl Primal

-- Field declarations historically default differential forms to Primal.
-- Locals deliberately do not: every omitted local policy is Collocated,
-- independent of tensor kind, and a staggered local must say @primal or
-- @dual explicitly.
parseLocalDecl :: Int -> String -> IO LocalDecl
parseLocalDecl ln source =
  localDeclFromField <$> parseStorageDecl Collocated ln source

parseStorageDecl :: GridPolicy -> Int -> String -> IO FieldDecl
parseStorageDecl defaultFormPolicy ln r =
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
  | selectedMode m == CollocatedMode
  , mDd m /= Nothing =
      fatal "assert-dd-zero requires mode dec"
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
          else if not (supportedV1 lattice derivativeOrder accuracy)
            then fatal ("FEIR v1 supports Yee accuracy 2 and per-axis derivative order 1 or 2 only (line "
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

    supportedV1 SurfaceStaggered derivativeOrder accuracy =
      accuracy == 2 && maybe True (<= 2) derivativeOrder
    supportedV1 SurfaceCollocated _ _ = True

    badSyntax = fatal
      ("bad discretization declaration (line " ++ show lineNumber ++ "): "
       ++ "discretization collocated [derivative ORDER] centered accuracy EVEN, "
       ++ "or discretization staggered [derivative ORDER] yee accuracy 2")

-- Parse and validate the source language without expanding definitions or
-- selecting a discrete implementation.  pre-fec emits this model to Egison
-- for mathematical normalization.
parseModel :: FilePath -> String -> String -> IO Model
parseModel sourceFile name txt = do
  mapM_ rejectInternalOperatorSpelling numberedLines
  mapM_ rejectNormalizationCapability numberedLines
  go STop initialModel
    [(lineNumber, transliterate raw, raw) | (lineNumber, raw) <- numberedLines]
  where
    numberedLines = zip [1 :: Int ..] (lines txt)

    -- Δ_H is lowered to the atomic identifier ΔH before the indexed-expression
    -- parser sees it.  Reserve that compact spelling so it cannot become an
    -- accidental second surface alias for the Hodge Laplacian.
    rejectInternalOperatorSpelling (lineNumber, raw) =
      case [name' | TId name' _ <- tokenize (stripComment raw), name' == "ΔH"] of
        _ : _ -> fatal ("ΔH is an internal spelling; write Δ_H (line "
                        ++ show lineNumber ++ ")")
        [] -> return ()

    -- Generated normalization code is trusted to construct opaque FEIR
    -- requests; user source is not.  Scan every surface context before its
    -- grammar-specific path is selected, including definitions, steps,
    -- initializers, metric scales, and embeddings.  Strings and comments must
    -- be recognized in one pass: stripping comments first would mistake @--@
    -- inside a string for a comment opener and leave later executable source
    -- outside this capability gate.
    rejectNormalizationCapability (lineNumber, raw) =
      case [name' | TId name' _ <- tokenize scanned,
                    isReservedNormalizationCapability name'] of
        name' : _ -> fatal
          ("reserved normalization capability '" ++ name'
           ++ "' cannot be used in Formurae source (line "
           ++ show lineNumber ++ ")")
        [] -> return ()
      where
        scanned = maskSourceNonCode raw

    maskSourceNonCode = outsideString
      where
        outsideString [] = []
        outsideString ('-' : '-' : _rest) = []
        outsideString ('"' : rest) = ' ' : insideString rest
        outsideString (char : rest) = char : outsideString rest

        insideString [] = []
        insideString ('\\' : _escaped : rest) = ' ' : ' ' : insideString rest
        insideString ('"' : rest) = ' ' : outsideString rest
        insideString (_char : rest) = ' ' : insideString rest

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
      , mDd = Nothing
      , mMetric = Nothing
      , mEmbed = Nothing
      , mDefs = []
      , mDiscretizationDecls = []
      }
    -- dimension and axes are required: they fix the coordinate frame
    -- that gives the operators their meaning (which axis ∂_theta is,
    -- what an index letter in ∂_j ranges over)
    go _ m []
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
          let mUse = m
          validateValueBindingNames mUse
          validateMetricName mUse
          validateDimensionFeatures mUse
          validateIndexedStepTargets mUse
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
            { mParams = reverse (mParams mUse)
            , mParamSourceLines = reverse (mParamSourceLines mUse)
            , mHelp = reverse (mHelp mUse)
            , mHelpKinds = reverse (mHelpKinds mUse)
            , mHelpSourceLines = reverse (mHelpSourceLines mUse)
            , mFieldDecls = reverse (mFieldDecls mUse)
            , mInits = reverse (mInits mUse)
            , mInitSourceTexts = reverse (mInitSourceTexts mUse)
            , mSteps = reverse (mSteps mUse)
            , mDefs = reverse (mDefs mUse)
            , mDiscretizationDecls = reverse (mDiscretizationDecls mUse)
            }

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
              STop
                | Just definitionHead <- stripPrefix "def " s
                , definitionNeedsContinuation definitionHead ->
                    let (bodyLines, rest') = takeDefinitionBody rest
                    in case bodyLines of
                         [] -> fatal ("bad def (line " ++ show ln
                                      ++ "): a body must follow '='")
                         _ ->
                           let translatedBody = intercalate "\n" (deindentBlock
                                 [rstrip (stripComment translatedLine)
                                 | (_, translatedLine, _) <- bodyLines])
                               originalBodyLines =
                                 [(lineNumber, rstrip (stripComment originalLine'))
                                 | (lineNumber, _, originalLine') <- bodyLines]
                               combinedHead = definitionHead ++ " " ++ translatedBody
                           in addDefinition ln
                                (sourceTextForContinuationLines originalBodyLines)
                                combinedHead m
                              >>= \m' -> go STop m' rest'
              STop -> top ln originalCode s m >>= \m' -> go STop m' rest
              -- an init line may continue over following lines until its
              -- brackets balance (tensor initializers span rows)
              SInit | bal s > 0 ->
                let (more, moreSourceLines, rest') = grab (bal s) rest
                in ini ((ln, originalCode) : moreSourceLines)
                       (s ++ " " ++ more) m
                     >>= \m' -> go SInit m' rest'
              SInit -> ini [(ln, originalCode)] s m >>= \m' -> go SInit m' rest
              SStep | stepNeedsContinuation s ->
                let (more, moreSourceLines, rest') = grab (bal s) rest
                    sourceLines = (ln, originalCode) : moreSourceLines
                in stp sourceLines (s ++ " " ++ more) m
                     >>= \m' -> go SStep m' rest'
              SStep -> stp [(ln, originalCode)] code m
                >>= \m' -> go SStep m' rest

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
            translatedCode = strip (rstrip (stripComment translated))

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
      | Just r <- stripPrefix "discretization " s =
          parseDiscretizationDecl ln r >>= addDiscretizationDecl
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
        dim r | all isDigit (strip r), n <- read (strip r) =
                  if n < (1 :: Int) || n > 3
                    then fatal ("Formurae currently supports dimension 1, 2, or 3 (got "
                                ++ show n ++ ")")
                    else return m { mDim = n }
              | otherwise = fatal ("bad dimension (line " ++ show ln ++ ")")

    addDefinition ln sourceBuilder source m =
      case defForm source of
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
          definitionSource <- sourceBuilder (defBody df)
          return m
            { mDefs = df { defSourceText = Just definitionSource } : mDefs m }
        Nothing -> fatal ("bad def (line " ++ show ln
                          ++ "): def NAME ARG... = EXPR")

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

    -- Step equations keep superscripts (~i) and subscripts (_i) distinct.
    -- pre-fec preserves that variance in the logical tensor type; Egison
    -- evaluates the indexed equation and post-fec alone projects storage.
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
    checkTok (TId nm _)
      | Just msg <- invalidDerivativeOp m nm =
          Just msg
      | nm == "badPartialDerivative" =
          Just "coordinate derivative must be written with subscript notation, e.g. ∂_x u, ∂^2_x u, or ∂'^2_x u"
      | ("FormuraeInternalKroneckerDelta" : ps) <- splitOn '_' nm
      , any ((> 1) . length) ps =
          Just ("Kronecker delta takes one index per mark (δ~i_j): " ++ nm)
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
-- Unicode input: Greek letters transliterate to their ASCII names.  A
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
    tr '\948' = "δ"        -- δ remains distinct from ASCII delta
    tr '\8722' = "-"       -- − (minus sign)
    tr c = [c]
