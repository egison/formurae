module Main where

import Data.List (find)

import Formurae.FEIR.Codec (profileFingerprintMatches)
import Formurae.FEIR.Syntax
import Formurae.Pre.Parse (parseModel)
import Formurae.Pre.Registry

main :: IO ()
main = do
  model <- parseModel "registry.fme" "registry" source
  registry <- requireRight "build registry" (buildRegistry model)
  registryAgain <- requireRight "stable rebuild" (buildRegistry model)

  assertEqual "registry construction is deterministic"
    registry registryAgain
  assertEqual "stable axis IDs and canonical CAS coordinates"
    [(AxisId 1, "r", "x"), (AxisId 2, "theta", "y")]
    [(axisDeclId axis, axisDeclSourceName axis, axisDeclCanonicalName axis)
    | axis <- preRegistryAxes registry]
  assertEqual "axes declaration origin line"
    [3, 3]
    [originLine registry (axisDeclOrigin axis) | axis <- preRegistryAxes registry]

  assertEqual "stable parameter IDs and declaration origin"
    [(ParamId 1, "alpha", "0.25", 7)]
    [(parameterDeclId parameter, parameterDeclSourceName parameter,
      parameterDeclRawValue parameter,
      originLine registry (parameterDeclOrigin parameter))
    | parameter <- preRegistryParameters registry]

  let potential = requireJust "external function" $ find
        ((== "potential") . functionDeclSourceName)
        (preRegistryFunctions registry)
  assertEqual "external helper classification"
    (ExternalFunction, Just 8)
    (functionDeclClass potential,
     fmap (originLine registry) (functionDeclOrigin potential))
  let exponential = requireJust "intrinsic external declaration" $ find
        ((== "exp") . functionDeclSourceName)
        (preRegistryFunctions registry)
  assertEqual "surface-declared intrinsic keeps its helper origin"
    (IntrinsicFunction, Just 9)
    (functionDeclClass exponential,
     fmap (originLine registry) (functionDeclOrigin exponential))
  assertEqual "raw helper is not reclassified by its text"
    [(RawHelperId 1, "extern function :: raw_only", 10)]
    [(rawHelperId helper, rawHelperText helper,
      originLine registry (rawHelperOrigin helper))
    | helper <- preRegistryRawHelpers registry]

  let fields = preRegistryFields registry
  assertEqual "stable user and step-local field IDs"
    [(FieldId 1, "u"), (FieldId 2, "V"), (FieldId 3, "A"),
     (FieldId 4, "B"), (FieldId 5, "flux"), (FieldId 6, "face"),
     (FieldId 7, "stress"), (FieldId 8, "omega")]
    [(logicalFieldId field, logicalFieldSourceName field) | field <- fields]
  let vectorV = fieldNamed "V" fields
      vectorA = fieldNamed "A" fields
      vectorB = fieldNamed "B" fields
      localFlux = fieldNamed "flux" fields
      localFace = fieldNamed "face" fields
      localStress = fieldNamed "stress" fields
      localOmega = fieldNamed "omega" fields
  assertEqual "unmarked variance remains distinguishable"
    (TensorType [2] [VarianceDown] 0, [Nothing])
    (logicalFieldTensorType vectorV, logicalFieldDeclaredVariances vectorV)
  assertEqual "explicit subscript variance"
    [Just VarianceDown] (logicalFieldDeclaredVariances vectorA)
  assertEqual "explicit superscript and dual policy"
    ([Just VarianceUp], DualPolicy)
    (logicalFieldDeclaredVariances vectorB, logicalFieldPolicy vectorB)
  assertEqual "local becomes a collocated step-local logical field"
    (StepLocalLifetime, CollocatedPolicy, TensorType [] [] 0, 17)
    (logicalFieldLifetime localFlux, logicalFieldPolicy localFlux,
     logicalFieldTensorType localFlux,
     originLine registry (logicalFieldOrigin localFlux))
  assertEqual "indexed local reuses vector descriptor and explicit policy"
    ( StepLocalLifetime, PrimalPolicy
    , TensorType [2] [VarianceDown] 0, VectorLayout
    , [Just VarianceDown], 18
    )
    ( logicalFieldLifetime localFace, logicalFieldPolicy localFace
    , logicalFieldTensorType localFace, logicalFieldLayout localFace
    , logicalFieldDeclaredVariances localFace
    , originLine registry (logicalFieldOrigin localFace)
    )
  assertEqual "rank-two local preserves mixed variance and full layout"
    ( StepLocalLifetime, DualPolicy
    , TensorType [2, 2] [VarianceUp, VarianceDown] 0, FullLayout
    , [Just VarianceUp, Just VarianceDown], 19
    )
    ( logicalFieldLifetime localStress, logicalFieldPolicy localStress
    , logicalFieldTensorType localStress, logicalFieldLayout localStress
    , logicalFieldDeclaredVariances localStress
    , originLine registry (logicalFieldOrigin localStress)
    )
  assertEqual "form local preserves degree/layout and explicit policy"
    ( StepLocalLifetime, PrimalPolicy
    , TensorType [2, 2] [VarianceDown, VarianceDown] 2, FormLayout
    , [Nothing, Nothing], 20
    )
    ( logicalFieldLifetime localOmega, logicalFieldPolicy localOmega
    , logicalFieldTensorType localOmega, logicalFieldLayout localOmega
    , logicalFieldDeclaredVariances localOmega
    , originLine registry (logicalFieldOrigin localOmega)
    )

  let profile = preRegistryDiscretization registry
  assert "profile fingerprint is canonical" (profileFingerprintMatches profile)
  assertEqual "default and order-specific profile rules"
    [ (CollocatedLattice, Nothing, CenteredTaylor, PositiveEven 2, 4)
    , (CollocatedLattice, Just (Positive 2), CenteredTaylor, PositiveEven 4, 5)
    , (StaggeredLattice, Nothing, Yee, PositiveEven 2, 6)
    ]
    [ (derivativeRuleLatticeClass rule, derivativeRuleOrder rule,
       derivativeRuleFamily rule, derivativeRuleAccuracy rule,
       originLine registry (derivativeRuleOrigin rule))
    | rule <- discretizationDerivativeRules profile]

  assertEqual "Euclidean geometry skeleton"
    (GeometryDecl (GeometryId 1) Nothing Nothing EuclideanGeometry)
    (preRegistryGeometry registry)

  quotedModel <- parseModel "registry-quoted.fme" "registry-quoted"
    quotedTraceSource
  quotedRegistry <- requireRight "build quoted trace registry"
    (buildRegistry quotedModel)
  let [quotedStepOriginId] = preRegistryStepOrigins quotedRegistry
      OriginTable quotedOrigins = preRegistryOrigins quotedRegistry
      quotedStepOrigin = requireJust "quoted step origin"
        (lookup quotedStepOriginId quotedOrigins)
  assertEqual "definition tracing traverses a quoted derivative operand"
    ["outer", "inner"]
    [expansionFrameName frame
    | frame <- sourceOriginTrace quotedStepOrigin]

  literalModel <- parseModel "registry-literal.fme" "registry-literal"
    literalTraceSource
  literalRegistry <- requireRight "build literal trace registry"
    (buildRegistry literalModel)
  let [literalStepOriginId] = preRegistryStepOrigins literalRegistry
      OriginTable literalOrigins = preRegistryOrigins literalRegistry
      literalStepOrigin = requireJust "literal step origin"
        (lookup literalStepOriginId literalOrigins)
  assertEqual "definition tracing traverses all tensor literal components"
    ["outer", "first", "second"]
    [expansionFrameName frame
    | frame <- sourceOriginTrace literalStepOrigin]
  putStrLn "pre registry tests: ok"

source :: String
source = unlines
  [ "mode dec"
  , "dimension 2"
  , "axes r, theta"
  , "discretization collocated centered accuracy 2"
  , "discretization collocated derivative 2 centered accuracy 4"
  , "discretization staggered yee accuracy 2"
  , "param alpha = 0.25"
  , "extern potential"
  , "extern exp"
  , "raw extern function :: raw_only"
  , "field u : scalar"
  , "field V : vector"
  , "field A_i"
  , "field B~i @ dual"
  , "step:"
  , "  let q = u + alpha"
  , "  local flux = q"
  , "  local face_i @ primal = A_i"
  , "  local stress~i_j @ dual = B~i * A_j"
  , "  local omega : 2-form @ primal = d face"
  , "  u' = flux"
  ]

quotedTraceSource :: String
quotedTraceSource = unlines
  [ "mode collocated"
  , "dimension 1"
  , "axes x"
  , "field u : scalar"
  , "def inner x = x + 1"
  , "def outer x = `(d_x (inner x))"
  , "step:"
  , "  u' = outer u"
  ]

literalTraceSource :: String
literalTraceSource = unlines
  [ "mode collocated"
  , "dimension 1"
  , "axes x"
  , "field u : scalar"
  , "def first x = x + 1"
  , "def second x = x - 1"
  , "def outer x = [| first x, second x |]_i"
  , "step:"
  , "  u' = outer u"
  ]

originLine :: PreRegistry -> OriginId -> Int
originLine registry originId =
  case lookup originId entries of
    Just origin -> sourceLocationLine (sourceOriginLocation origin)
    Nothing -> error ("missing origin " ++ show originId)
  where
    OriginTable entries = preRegistryOrigins registry

fieldNamed :: String -> [LogicalFieldDecl] -> LogicalFieldDecl
fieldNamed name fields = requireJust ("field " ++ name) $ find
  ((== name) . logicalFieldSourceName) fields

requireRight :: String -> Either RegistryError a -> IO a
requireRight _ (Right value) = pure value
requireRight label (Left err) = fail (label ++ ": " ++ show err)

requireJust :: String -> Maybe a -> a
requireJust _ (Just value) = value
requireJust label Nothing = error ("missing " ++ label)

assert :: String -> Bool -> IO ()
assert _ True = pure ()
assert label False = fail label

assertEqual :: (Eq a, Show a) => String -> a -> a -> IO ()
assertEqual label expected actual
  | expected == actual = pure ()
  | otherwise = fail
      (label ++ ": expected " ++ show expected ++ ", got " ++ show actual)
