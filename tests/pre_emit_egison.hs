module Main where

import Data.List (isInfixOf)

import Formurae.FEIR.Syntax (PrimitiveManifestId(..))
import Formurae.Pre.EmitEgison
import Formurae.Pre.Parse (parseModel)

main :: IO ()
main = do
  model <- parseModel "pre-emit.fme" "pre-emit" source
  first <- requireRight =<< emitNormalizationUnit manifestId model
  second <- requireRight =<< emitNormalizationUnit manifestId model

  assertEqual "normalization unit is deterministic" first second
  assertContains "ambient coordinates specialize each used shared operator"
    "def FormuraeInternalLap u := Formurae.lap coordinates u" first
  assertAbsent first "def FormuraeInternalGrad u :="
  assertAbsent first "Formurae.operatorContext"
  assertAbsent first "feOperatorContext"
  assertAbsent first "FormuraeInternalContext"
  assertContains "user definition receives only its surface parameters"
    "FormuraeInternalDefinition3 u" first
  assertContains "prior higher-order user definition receives the ambient operator"
    "FormuraeInternalDefinition1 FormuraeInternalLap u"
    first
  assertContains "indexed analytic derivative uses shared strict diff"
    "(FormuraeInternalDiff X~i)..._i" first
  assertContains "coordinate derivative uses strict analytic differentiation"
    "strict∂/∂ (strict∂/∂ u x) x" first
  assertContains "grid derivative preserves the whole nonlinear operand"
    "FormuraeInternalGridWholeDerivative 1 ((u * u) / 2)"
    first
  assertContains "gridDerivative is an equivalent surface spelling"
    "FormuraeInternalGridWholeDerivative 1 u"
    first
  assertContains "wide derivative is a versioned opaque constructor"
    "FormuraeInternalCoordinateWideDerivative 1 2 2 u"
    first
  assertContains "unicode Laplacian resolves to the shared pure Laplacian"
    "FormuraeInternalLap u" first
  aliasModel <- parseModel "pre-dec-alias.fme" "pre-dec-alias" decAliasSource
  aliasUnit <- requireRight =<< emitNormalizationUnit manifestId aliasModel
  assertContains "dForm alias resolves to the shared exterior derivative"
    "FormuraeInternalD X" aliasUnit
  assertContains "flat resolves to the shared metric contraction"
    "FormuraeInternalFlat X" aliasUnit
  assertContains "sharp resolves to the shared inverse metric contraction"
    "FormuraeInternalSharp X" aliasUnit
  assertContains "stable registry fingerprint"
    "FEIR.atom \"registry-id\", FEIR.string \"sha256:" first
  assertContains "single canonical FEIR output"
    "print (FEIR.render feProgram)" first

  epsilonModel <- parseModel "pre-epsilon.fme" "pre-epsilon" epsilonSource
  epsilonUnit <- requireRight =<< emitNormalizationUnit manifestId epsilonModel
  assertContains "an indexed epsilon use requests the ambient Levi-Civita tensor"
    "def epsilon : Tensor Integer := ε dimension" epsilonUnit

  operatorModel <- parseModel "pre-user-operator.fme" "pre-user-operator"
    userOperatorSource
  operatorUnit <- requireRight =<< emitNormalizationUnit manifestId operatorModel
  assertContains "free covariant result index is canonicalized structurally"
    "def FormuraeInternalDefinition1 X := Formurae.attachExplicitVariances [\"down\"]"
    operatorUnit
  assertContains "free contravariant result index is canonicalized structurally"
    "def FormuraeInternalDefinition2 A := Formurae.attachExplicitVariances [\"up\"]"
    operatorUnit
  assertAbsent aliasUnit
    "def FormuraeInternalDefinition1 X := Formurae.attachExplicitVariances"

  mapM_ (assertAbsent first)
    [ "def dC "
    , "def dC2 "
    , "dYee"
    , "FMR."
    , "fieldEqs"
    , "storage"
    , "pd2r1"
    ]

  shadowModel <- parseModel "pre-shadow.fme" "pre-shadow" shadowSource
  shadowed <- requireRight =<< emitNormalizationUnit manifestId shadowModel
  assertContains "earlier user definition shadows the standard prelude"
    "def FormuraeInternalDefinition2 u := withSymbols [i, j, k, l, m, n] (FormuraeInternalDefinition1 u)"
    shadowed
  assertAbsent shadowed "withSymbols [i, j, k, l, m, n] (FormuraeInternalLap u)"

  dotShadowModel <- parseModel "pre-dot-shadow.fme" "pre-dot-shadow" dotShadowSource
  dotShadowed <- requireRight =<< emitNormalizationUnit manifestId dotShadowModel
  assertContains "user dot is published with Egison operator syntax"
    "def (.) := FormuraeInternalDefinition1"
    dotShadowed
  assertContains "later definition resolves user dot without a hidden argument"
    "def FormuraeInternalDefinition2 a b := withSymbols [i, j, k, l, m, n] (FormuraeInternalDefinition1 a b)"
    dotShadowed

  conditionalSource <- readFile "tests/fixtures/pre_fec_conditional.fme"
  conditionalModel <- parseModel "tests/fixtures/pre_fec_conditional.fme"
    "pre-fec-conditional" conditionalSource
  conditional <- requireRight =<< emitNormalizationUnit manifestId conditionalModel
  assertContains "surface if emits a symbolic canonical Select"
    "Formurae.select (Formurae.predicateOr" conditional
  assertContains "comparison and conjunction stay symbolic until FEIR"
    "Formurae.select (Formurae.predicateAnd (Formurae.predicateLt x threshold) (Formurae.predicateGe u 0))"
    conditional
  assertAbsent conditional "def FormuraeInternalValue1 := if"

  primitiveShadowModel <- parseModel "pre-primitive-shadow.fme"
    "pre-primitive-shadow" primitiveShadowSource
  primitiveShadowed <- requireRight =<< emitNormalizationUnit manifestId
    primitiveShadowModel
  assertContains "explicit primitive name resolves an earlier user definition"
    "def FormuraeInternalDefinition2 x := withSymbols [i, j, k, l, m, n] (FormuraeInternalDefinition1(x))"
    primitiveShadowed
  assertContains "bound parameter shadows an explicit primitive"
    "def FormuraeInternalDefinition3 materialize x := withSymbols [i, j, k, l, m, n] (materialize(x))"
    primitiveShadowed
  assertContains "shadowed explicit primitive remains a higher-order value"
    "def FormuraeInternalValue1 := applyShadow useMaterialize u"
    primitiveShadowed
  assertAbsent primitiveShadowed "FormuraeInternalMaterialized x"

  parameterModel <- parseModel "pre-definition-parameters.fme"
    "pre-definition-parameters" parameterSource
  parameterUnit <- requireRight =<< emitNormalizationUnit manifestId parameterModel
  assertContains "rank-polymorphic marker emits one whole-value parameter"
    "def FormuraeInternalDefinition1 X := withSymbols [i, j, k, l, m, n] (X)"
    parameterUnit
  assertContains "fixed indexed parameter also binds the whole value"
    "def FormuraeInternalDefinition3 X :="
    parameterUnit
  assertContains "fixed indexed parameter checks whole-value metadata"
    "indexed parameter X_i metadata mismatch in fixedIdentity"
    parameterUnit
  assertContains "body append-index syntax is preserved"
    "def FormuraeInternalDefinition2 X := Formurae.attachExplicitVariances [\"down\"] (withSymbols [i, j, k, l, m, n] (X..._i))"
    parameterUnit
  assertAbsent parameterUnit "FormuraeInternalDefinition2 X..."
  assertAbsent parameterUnit "FormuraeInternalDefinition3 X_i"

  invalidAxisModel <- parseModel "pre-invalid-grid-axis.fme"
    "pre-invalid-grid-axis" invalidAxisSource
  invalidAxis <- emitNormalizationUnit manifestId invalidAxisModel
  assertLeft "unknown grid derivative coordinate is rejected"
    isUnknownGridCoordinate invalidAxis

  invalidWideAxisModel <- parseModel "pre-invalid-wide-axis.fme"
    "pre-invalid-wide-axis" invalidWideAxisSource
  invalidWideAxis <- emitNormalizationUnit manifestId invalidWideAxisModel
  assertLeft "unknown wide derivative coordinate is rejected"
    isUnknownWideCoordinate invalidWideAxis

  invalidWideArityModel <- parseModel "pre-invalid-wide-arity.fme"
    "pre-invalid-wide-arity" invalidWideAritySource
  invalidWideArity <- emitNormalizationUnit manifestId invalidWideArityModel
  assertLeft "wide derivative arity is checked before Egison"
    isInvalidWideArity invalidWideArity

  ksSource <- readFile "examples/ks3d/ks3d.fme"
  ksModel <- parseModel "examples/ks3d/ks3d.fme" "ks3d" ksSource
  ksUnit <- requireRight =<< emitNormalizationUnit manifestId ksModel
  assertContains "ks3d uses the whole-expression grid derivative boundary"
    "FormuraeInternalGridWholeDerivative 1 ((u * u) / 2)"
    ksUnit
  putStrLn "pre-fec Egison emitter tests: ok"

manifestId :: PrimitiveManifestId
manifestId = PrimitiveManifestId "sha256:test-manifest"

source :: String
source = unlines
  [ "mode collocated"
  , "dimension 1"
  , "axes r"
  , "discretization collocated derivative 2 centered accuracy 4"
  , "param alpha = 0.25"
  , "field u : scalar"
  , "def pass f u = f u"
  , "def indexed X = withSymbols [i] (∂_i X~i)"
  , "def smooth u = pass lap u + ∂^2_r u + gridD_r (u * u / 2)"
  , "def gridAlias u = gridDerivative_r u"
  , "def wide u = pd2r2_r u"
  , "def lapAlias u = Δ u"
  , "init:"
  , "  u = 0.0"
  , "step:"
  , "  u' = u + alpha * smooth u"
  ]

decAliasSource :: String
decAliasSource = unlines
  [ "mode dec"
  , "dimension 2"
  , "axes x, y"
  , "field A : 1-form"
  , "def ext X = dForm X"
  , "def musical X = flat X + sharp X"
  , "step:"
  , "  A' = A"
  ]

epsilonSource :: String
epsilonSource = unlines
  [ "mode collocated"
  , "dimension 3"
  , "axes x, y, z"
  , "field X_i"
  , "field Y_i"
  , "step:"
  , "  Y'_i = withSymbols [j, k] (epsilon_i~j~k . ∂_j X_k)"
  ]

userOperatorSource :: String
userOperatorSource = unlines
  [ "mode collocated"
  , "dimension 3"
  , "axes x, y, z"
  , "metric g"
  , "metric scale [1, 2, 3]"
  , "field X_i"
  , "field A_i"
  , "field Y_i"
  , "def curl X = withSymbols [i, j, k] (epsilon_i~j~k . ∂_j X_k)"
  , "def raise A = withSymbols [i, j] (g~i~j . A_j)"
  , "step:"
  , "  Y' = curl X"
  ]

shadowSource :: String
shadowSource = unlines
  [ "mode collocated"
  , "dimension 1"
  , "axes x"
  , "field u : scalar"
  , "def lap u = u + 1"
  , "def use u = lap u"
  , "init:"
  , "  u = 0.0"
  , "step:"
  , "  u' = use u"
  ]

dotShadowSource :: String
dotShadowSource = unlines
  [ "mode collocated"
  , "dimension 1"
  , "axes x"
  , "field u : scalar"
  , "def (.) a b = a + b"
  , "def combine a b = a . b"
  , "init:"
  , "  u = 0.0"
  , "step:"
  , "  u' = combine u 2"
  ]

primitiveShadowSource :: String
primitiveShadowSource = unlines
  [ "mode collocated"
  , "dimension 1"
  , "axes x"
  , "field u : scalar"
  , "def materialize x = x + 1"
  , "def useMaterialize x = materialize(x)"
  , "def applyShadow materialize x = materialize(x)"
  , "step:"
  , "  u' = applyShadow useMaterialize u"
  ]

parameterSource :: String
parameterSource = unlines
  [ "mode collocated"
  , "dimension 2"
  , "axes x, y"
  , "field X_i"
  , "def rankIdentity X... = X"
  , "def appendIndex X... = X..._i"
  , "def fixedIdentity X_i = X"
  , "step:"
  , "  X' = fixedIdentity (rankIdentity X)"
  ]

invalidAxisSource :: String
invalidAxisSource = unlines
  [ "mode collocated"
  , "dimension 1"
  , "axes x"
  , "field u : scalar"
  , "step:"
  , "  u' = gridD_q u"
  ]

invalidWideAxisSource :: String
invalidWideAxisSource = unlines
  [ "mode collocated"
  , "dimension 1"
  , "axes x"
  , "field u : scalar"
  , "step:"
  , "  u' = pd2r2_q u"
  ]

invalidWideAritySource :: String
invalidWideAritySource = unlines
  [ "mode collocated"
  , "dimension 1"
  , "axes x"
  , "field u : scalar"
  , "step:"
  , "  u' = pd2r2_x u u"
  ]

requireRight :: Either EmitError a -> IO a
requireRight (Right value) = pure value
requireRight (Left err) = fail (show err)

assertContains :: String -> String -> String -> IO ()
assertContains label needle haystack
  | needle `isInfixOf` haystack = pure ()
  | otherwise = fail (label ++ ": missing " ++ show needle)

assertAbsent :: String -> String -> IO ()
assertAbsent haystack needle
  | needle `isInfixOf` haystack = fail ("unexpected generated text " ++ show needle)
  | otherwise = pure ()

assertEqual :: (Eq a, Show a) => String -> a -> a -> IO ()
assertEqual label expected actual
  | expected == actual = pure ()
  | otherwise = fail
      (label ++ ": expected " ++ show expected ++ ", got " ++ show actual)

assertLeft :: Show a => String -> (e -> Bool) -> Either e a -> IO ()
assertLeft label predicate result =
  case result of
    Left problem | predicate problem -> pure ()
    Left _ -> fail (label ++ ": wrong error")
    Right value -> fail (label ++ ": expected failure, got " ++ show value)

isUnknownGridCoordinate :: EmitError -> Bool
isUnknownGridCoordinate problem =
  case problem of
    EmitAtSource _ nested -> isUnknownGridCoordinate nested
    EmitExpressionError message -> message == "gridD uses unknown coordinate q"
    _ -> False

isUnknownWideCoordinate :: EmitError -> Bool
isUnknownWideCoordinate problem =
  case problem of
    EmitAtSource _ nested -> isUnknownWideCoordinate nested
    EmitExpressionError message -> message == "pd2r2 uses unknown coordinate q"
    _ -> False

isInvalidWideArity :: EmitError -> Bool
isInvalidWideArity problem =
  case problem of
    EmitAtSource _ nested -> isInvalidWideArity nested
    EmitExpressionError message ->
      message == "pd2r2 coordinate derivative needs one operand"
    _ -> False
