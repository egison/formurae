module Main where

import System.Environment (getArgs)

import Formurae.FEIR.Codec (renderFEProgram, setProfileFingerprint)
import Formurae.FEIR.PrimitiveManifest
  ( parsePrimitiveManifest, primitiveManifestId )
import Formurae.FEIR.RegistryFingerprint (computeRegistryId)
import Formurae.FEIR.Syntax

main :: IO ()
main = do
  arguments <- getArgs
  mode <- case arguments of
    [value] -> pure value
    _ -> fail "usage: post_diagnostic_cli_fixture MODE"
  manifestSource <- readFile "spec/feir-primitives.sexp"
  manifest <- either (fail . show) pure
    (parsePrimitiveManifest manifestSource)
  let program0 = case mode of
        "validation" -> baseProgram
          { feProgramFields = [scalarField { logicalFieldLayout = VectorLayout }] }
        "compile" -> baseProgram
          { feProgramStepActions = [UpdateField wideEquation] }
        _ -> error ("unknown fixture mode " ++ mode)
      program1 = program0
        { feProgramPrimitiveManifestId = primitiveManifestId manifest }
      program = program1 { feProgramRegistryId = computeRegistryId program1 }
  putStrLn (renderFEProgram program)

baseProgram :: FEProgram
baseProgram = FEProgram
  { feProgramModel = ModelIdentity (ModelId "cli-model") "cli-model"
      (SourceIdentity (SourceId "cli-source") "/workspace/cli-model.fme")
  , feProgramRegistryId = RegistryId "pending"
  , feProgramPrimitiveManifestId = PrimitiveManifestId "pending"
  , feProgramDiscretization = setProfileFingerprint
      (DiscretizationProfile
        (Fingerprint "") [] FixedAxisOrder)
  , feProgramMode = CollocatedMode
  , feProgramDimension = 1
  , feProgramAxes = [AxisDecl (AxisId 1) "x" "x" (OriginId 1)]
  , feProgramGeometry = GeometryDecl (GeometryId 1) Nothing Nothing
      EuclideanGeometry
  , feProgramParameters = []
  , feProgramFunctions = []
  , feProgramFields = [scalarField]
  , feProgramInitializers = []
  , feProgramStepActions = []
  , feProgramRawHelpers = []
  , feProgramOrigins = OriginTable
      [ (OriginId 1, sourceOrigin 2 1)
      , (OriginId 2, sourceOrigin 10 4)
      , (OriginId 3, sourceOrigin 30 7)
      ]
  , feProgramProvenance = ProvenanceTable []
  }

scalarField :: LogicalFieldDecl
scalarField = LogicalFieldDecl (FieldId 1) "u" CollocatedPolicy
  (TensorType [] [] 0) ScalarLayout [] UserStateLifetime (OriginId 2)

wideEquation :: FEEquation
wideEquation = FEEquation (EquationId 1)
  (WholeFieldTarget (FieldId 1) NextTime)
  (scalarTensor (OpaqueDiscrete missingRadiusWide)) (OriginId 3)

missingRadiusWide :: OpaqueDiscrete
missingRadiusWide = OpaqueDiscreteCall
  (OpId "derivative.coordinate-wide")
  (SemanticKey "wide-missing-radius")
  (RequestGroupId "wide-missing-radius-group")
  (Basis [])
  [ScalarValue (FieldJet sourceJet)]
  [ Attribute (AttributeId "order") (AttributeNatural 2)
  , Attribute (AttributeId "ordered-axes")
      (AttributeValues [AttributeAxis (AxisId 1)])
  ]

sourceJet :: FieldJet
sourceJet = FieldJetValue (FieldId 1) CurrentTime (Basis [])
  [Coordinate (AxisId 1)] []

scalarTensor :: ScalarNF -> TensorNF
scalarTensor scalar = TensorNF [] [] 0 [(Basis [], scalar)]

sourceOrigin :: Int -> Int -> SourceOrigin
sourceOrigin line column = SourceOrigin
  (SourceLocation (SourceId "cli-source") "/workspace/cli-model.fme"
    line line column column) []
