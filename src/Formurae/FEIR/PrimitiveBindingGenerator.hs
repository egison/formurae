module Formurae.FEIR.PrimitiveBindingGenerator
  ( GeneratedPrimitivePaths(..)
  , defaultGeneratedPrimitivePaths
  , checkGeneratedPrimitiveBindings
  , writeGeneratedPrimitiveBindings
  ) where

import Data.Char (isAlphaNum, toLower, toUpper)
import Data.List (intercalate)
import System.FilePath ((</>))

import Formurae.FEIR.PrimitiveManifest
import Formurae.FEIR.Syntax
  ( PrimitiveManifestId(..)
  , OpId(..)
  )

data GeneratedPrimitivePaths = GeneratedPrimitivePaths
  { generatedManifestPath :: FilePath
  , generatedHaskellPath :: FilePath
  , generatedEgisonPath :: FilePath
  } deriving (Eq, Ord, Show)

defaultGeneratedPrimitivePaths :: FilePath -> GeneratedPrimitivePaths
defaultGeneratedPrimitivePaths root = GeneratedPrimitivePaths
  { generatedManifestPath = root </> "spec/feir-primitives.sexp"
  , generatedHaskellPath =
      root </> "src/Formurae/FEIR/PrimitiveBindings.hs"
  , generatedEgisonPath = root </> "lib/formurae-primitives.egi"
  }

checkGeneratedPrimitiveBindings
  :: GeneratedPrimitivePaths -> IO (Either [String] ())
checkGeneratedPrimitiveBindings paths = do
  manifestResult <- loadPrimitiveManifest (generatedManifestPath paths)
  case manifestResult of
    Left problem -> pure (Left [show problem])
    Right manifest -> do
      actualHaskell <- readFile (generatedHaskellPath paths)
      actualEgison <- readFile (generatedEgisonPath paths)
      let differences = concat
            [ staleDifference
                (generatedHaskellPath paths)
                (renderHaskellPrimitiveBindings manifest)
                actualHaskell
            , staleDifference
                (generatedEgisonPath paths)
                (renderEgisonPrimitiveBindings manifest)
                actualEgison
            ]
      pure (if null differences then Right () else Left differences)

writeGeneratedPrimitiveBindings
  :: GeneratedPrimitivePaths -> IO (Either String ())
writeGeneratedPrimitiveBindings paths = do
  manifestResult <- loadPrimitiveManifest (generatedManifestPath paths)
  case manifestResult of
    Left problem -> pure (Left (show problem))
    Right manifest -> do
      writeFile
        (generatedHaskellPath paths)
        (renderHaskellPrimitiveBindings manifest)
      writeFile
        (generatedEgisonPath paths)
        (renderEgisonPrimitiveBindings manifest)
      pure (Right ())

renderHaskellPrimitiveBindings :: PrimitiveManifest -> String
renderHaskellPrimitiveBindings manifest = unlines
  ( [ "-- This file is generated from spec/feir-primitives.sexp."
    , "-- Run tools/generate-feir-primitives.hs; do not edit it directly."
    , "module Formurae.FEIR.PrimitiveBindings"
    , "  ( primitiveManifestId"
    , "  , primitiveManifest"
    , "  , primitiveSignatures"
    , "  , primitiveOperationIds"
    , "  , lookupPrimitiveSignature"
    ]
    ++ map ("  , " ++) bindingNames
    ++ [ "  ) where"
       , ""
       , "import Formurae.FEIR.PrimitiveManifest"
       ]
    ++ zipWith (++) ("  ( " : repeat "  , ") manifestImports
    ++ [ "  )"
       , "import Formurae.FEIR.Syntax"
       , "  ( PrimitiveManifestId(..)"
       , "  , OpId(..)"
       , "  )"
       , ""
       , "primitiveManifestId :: PrimitiveManifestId"
       , "primitiveManifestId = PrimitiveManifestId " ++ show manifestId
       , ""
       , "primitiveManifest :: PrimitiveManifest"
       , "primitiveManifest = PrimitiveManifest primitiveSignatures"
       , ""
       , "primitiveSignatures :: [PrimitiveSignature]"
       , "primitiveSignatures ="
       ]
    ++ renderHaskellSignatures operations
    ++ [ ""
       , "primitiveOperationIds :: [OpId]"
       , "primitiveOperationIds ="
       , renderHaskellList bindingNames
       , ""
       , "lookupPrimitiveSignature :: OpId -> Maybe PrimitiveSignature"
       , "lookupPrimitiveSignature operationId = lookup operationId"
       , "  [ (primitiveSignatureOpId signature, signature)"
       , "  | signature <- primitiveSignatures"
       , "  ]"
       , ""
       ]
    ++ intercalate [""] (map renderBinding operations)
  )
  where
    operations = primitiveManifestSignatures manifest
    bindingNames = map haskellBindingName operations
    PrimitiveManifestId manifestId = primitiveManifestId manifest

    -- The generated Show output mentions AuxiliaryRole constructors only
    -- when some signature materializes; an unconditional import would be
    -- redundant for an all-pure-local manifest.
    manifestImports =
      [ "AuxiliaryRole(..)" | anyMaterializing ]
      ++ [ "Commutation(..)"
         , "PlacementRule(..)"
         , "PrimitiveEffect(..)"
         , "PrimitiveManifest(..)"
         , "PrimitiveSignature(..)"
         , "ValueCategory(..)"
         ]
    anyMaterializing = or
      [ case primitiveSignatureEffect signature of
          NeedsMaterialization _ -> True
          PureLocal -> False
      | signature <- operations
      ]

    renderBinding signature =
      [ haskellBindingName signature ++ " :: OpId"
      , haskellBindingName signature ++ " = OpId "
          ++ show (versionedOpText (primitiveSignatureOpId signature))
      ]

renderEgisonPrimitiveBindings :: PrimitiveManifest -> String
renderEgisonPrimitiveBindings manifest = unlines
  ( [ "-- This file is generated from spec/feir-primitives.sexp."
    , "-- Run tools/generate-feir-primitives.hs; do not edit it directly."
    , ""
    , "def Formurae.Primitives.primitiveManifestId : String :="
    , "  " ++ show manifestId
    , ""
    ]
    ++ concatMap renderBinding operations
    ++ [ "def Formurae.Primitives.signatures"
       , "      : [(String, String, [String], String, String, String, [String], String)] :="
       , renderEgisonSignatures operations
       , ""
       , "def Formurae.Primitives.signatureOperationId"
       , "      (signature: (String, String, [String], String, String, String, [String], String))"
       , "      : String :="
       , "  let (operationId, _, _, _, _, _, _, _) := signature in operationId"
       , ""
       , "def Formurae.Primitives.signatureFor"
       , "      (operationId: String)"
       , "      : (String, String, [String], String, String, String, [String], String) :="
       , "  let matches :="
       , "        filter"
       , "          (\\entry ->"
       , "            Formurae.Primitives.signatureOperationId entry = operationId)"
       , "          Formurae.Primitives.signatures"
       , "   in match assert \"primitive operation ID is absent or duplicated in the generated manifest\""
       , "                   (length matches = 1)"
       , "        as bool with"
       , "      | #True -> head matches"
       , ""
       , "def Formurae.Primitives.requireOperationId"
       , "      (operationId: String) : String :="
       , "  let signature := Formurae.Primitives.signatureFor operationId"
       , "   in Formurae.Primitives.signatureOperationId signature"
       , ""
       , "def Formurae.Primitives.operationIds : [String] :="
       , "  map Formurae.Primitives.signatureOperationId"
       , "    Formurae.Primitives.signatures"
       ]
  )
  where
    operations = primitiveManifestSignatures manifest
    PrimitiveManifestId manifestId = primitiveManifestId manifest

    renderBinding signature =
      [ "def " ++ egisonQualifiedBindingName signature ++ " : String :="
      , "  " ++ show (versionedOpText (primitiveSignatureOpId signature))
      , ""
      ]

renderHaskellSignatures :: [PrimitiveSignature] -> [String]
renderHaskellSignatures [] = ["  []"]
renderHaskellSignatures signatures =
  concat (zipWith render [0 :: Int ..] signatures) ++ ["  ]"]
  where
    render index signature =
      [ (if index == 0 then "  [ " else "  , ") ++ "PrimitiveSignature"
      , "      { primitiveSignatureOpId = " ++ haskellBindingName signature
      , "      , primitiveSignatureOpName = "
          ++ show (primitiveSignatureOpName signature)
      , "      , primitiveSignatureInputs = "
          ++ show (primitiveSignatureInputs signature)
      , "      , primitiveSignatureOutput = "
          ++ show (primitiveSignatureOutput signature)
      , "      , primitiveSignaturePlacement = "
          ++ show (primitiveSignaturePlacement signature)
      , "      , primitiveSignatureEffect = "
          ++ show (primitiveSignatureEffect signature)
      , "      , primitiveSignatureCommutation = "
          ++ show (primitiveSignatureCommutation signature)
      , "      }"
      ]

renderEgisonSignatures :: [PrimitiveSignature] -> String
renderEgisonSignatures [] = "  []"
renderEgisonSignatures signatures = intercalate "\n"
  (zipWith render [0 :: Int ..] signatures ++ ["  ]"])
  where
    render index signature =
      (if index == 0 then "  [ " else "  , ")
      ++ "(" ++ intercalate ", "
        [ egisonQualifiedBindingName signature
        , show (primitiveSignatureOpName signature)
        , renderEgisonStrings
            (map valueCategoryText (primitiveSignatureInputs signature))
        , show (valueCategoryText (primitiveSignatureOutput signature))
        , show (placementRuleText (primitiveSignaturePlacement signature))
        , show effectName
        , renderEgisonStrings effectRoles
        , show (commutationText (primitiveSignatureCommutation signature))
        ]
      ++ ")"
      where
        (effectName, effectRoles) = effectText
          (primitiveSignatureEffect signature)

renderEgisonStrings :: [String] -> String
renderEgisonStrings values = "[" ++ intercalate ", " (map show values) ++ "]"

valueCategoryText :: ValueCategory -> String
valueCategoryText ScalarCategory = "scalar"
valueCategoryText TensorCategory = "tensor"
valueCategoryText FormCategory = "form"
valueCategoryText AnyCategory = "any"

placementRuleText :: PlacementRule -> String
placementRuleText PreserveSourcePlacement = "preserve-source"
placementRuleText DerivativeTargetPlacement = "derivative-target"
placementRuleText ExplicitTargetPlacement = "explicit-target"
placementRuleText ConservativeCellPlacement = "conservative-cell"
placementRuleText DualAdjointPlacement = "dual-adjoint"

effectText :: PrimitiveEffect -> (String, [String])
effectText PureLocal = ("pure-local", [])
effectText (NeedsMaterialization roles) =
  ("needs-materialization", map auxiliaryRoleText roles)

auxiliaryRoleText :: AuxiliaryRole -> String
auxiliaryRoleText CoefficientRole = "coefficient"
auxiliaryRoleText VolumeRole = "volume"
auxiliaryRoleText FluxRole = "flux"
auxiliaryRoleText ResultRole = "result"
auxiliaryRoleText IntermediateRole = "intermediate"

commutationText :: Commutation -> String
commutationText Ordered = "ordered"
commutationText DeclaredCommutative = "declared-commutative"

staleDifference :: FilePath -> String -> String -> [String]
staleDifference path expected actual
  | expected == actual = []
  | otherwise = [path]

haskellBindingName :: PrimitiveSignature -> String
haskellBindingName signature =
  operationStem signature ++ "OpId"

egisonQualifiedBindingName :: PrimitiveSignature -> String
egisonQualifiedBindingName signature =
  "Formurae.Primitives." ++ haskellBindingName signature

operationStem :: PrimitiveSignature -> String
operationStem signature =
  case splitIdentifier (primitiveSignatureOpName signature) of
    [] -> error "operationStem: validated operation name has no identifier part"
    first : rest -> lowerInitial first ++ concatMap upperInitial rest

splitIdentifier :: String -> [String]
splitIdentifier source =
  case dropWhile (not . isAlphaNum) source of
    [] -> []
    remaining ->
      let (part, suffix) = span isAlphaNum remaining
      in part : splitIdentifier suffix

lowerInitial :: String -> String
lowerInitial [] = []
lowerInitial (first : rest) = toLower first : rest

upperInitial :: String -> String
upperInitial [] = []
upperInitial (first : rest) = toUpper first : rest

renderHaskellList :: [String] -> String
renderHaskellList [] = "  []"
renderHaskellList (first : rest) = intercalate "\n"
  ( ("  [ " ++ first)
  : map ("  , " ++) rest
  ++ ["  ]"])

versionedOpText :: OpId -> String
versionedOpText (OpId value) = value
