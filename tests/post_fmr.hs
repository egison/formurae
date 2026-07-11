module Main where

import Data.Ratio ((%))

import Formurae.FEIR.Syntax
import Formurae.Post.FMR

main :: IO ()
main = do
  testStorageProjection
  testExpressionRendering
  testProgramRendering
  putStrLn "post FMR tests: ok"

testStorageProjection :: IO ()
testStorageProjection = do
  let vector = field (FieldId 1) "V" VectorLayout [3]
        [Just VarianceDown]
      symmetric = field (FieldId 2) "S" SymmetricLayout [3, 3]
        [Just VarianceUp, Just VarianceUp]
      antisymmetric = field (FieldId 3) "A" AntisymmetricLayout [3, 3]
        [Nothing, Nothing]
      form2 = (field (FieldId 4) "omega" FormLayout [3, 3]
        [Just VarianceDown, Just VarianceDown])
        { logicalFieldTensorType = TensorType [3, 3]
            [VarianceDown, VarianceDown] 2 }
  assertEqual "vector storage"
    (Right
      [ (Basis [1], "V_down1")
      , (Basis [2], "V_down2")
      , (Basis [3], "V_down3")
      ])
    (storageNames 3 vector)
  assertEqual "symmetric storage order"
    (Right
      [ (Basis [1, 1], "S_up1_up1")
      , (Basis [2, 2], "S_up2_up2")
      , (Basis [3, 3], "S_up3_up3")
      , (Basis [1, 2], "S_up1_up2")
      , (Basis [1, 3], "S_up1_up3")
      , (Basis [2, 3], "S_up2_up3")
      ])
    (storageNames 3 symmetric)
  assertEqual "unmarked antisymmetric storage"
    (Right
      [ (Basis [1, 2], "A_1_2")
      , (Basis [1, 3], "A_1_3")
      , (Basis [2, 3], "A_2_3")
      ])
    (storageNames 3 antisymmetric)
  assertEqual "form independent basis"
    (Right [Basis [1, 2], Basis [1, 3], Basis [2, 3]])
    (independentBases 3 form2)

testExpressionRendering :: IO ()
testExpressionRendering = do
  let expression = FAdd
        [ FGridReference "u"
            [GridIndex "i" (-2), GridIndex "j" 0]
        , FMul
            [ FExact (-1) 12
            , FGridReference "u"
                [GridIndex "i" (1 % 2), GridIndex "j" 1]
            ]
        ]
  assertEqual "precedence and offsets"
    (Right "u[i-2,j] + (-1 / 12) * u[i+(1 / 2),j+1]")
    (renderExpr expression)
  assertEqual "power denominator"
    (Right "u / dx**2")
    (renderExpr (FDiv (FVariable "u") (FPow (FVariable "dx") (FExact 2 1))))

testProgramRendering :: IO ()
testProgramRendering = do
  let program = FProgram
        { fProgramDimension = 1
        , fProgramAxes = ["x"]
        , fProgramParameters = [("dt", "0.1*dx*dx")]
        , fProgramHelpers = ["extern function :: exp"]
        , fProgramStateStorage = ["u"]
        , fProgramInitializers =
            [ FAssignment (InitialTarget "u" ["i"])
                (FCall "exp" [FVariable "x"]) ]
        , fProgramStepBindings = []
        , fProgramStepUpdates =
            [ FAssignment (StepUpdateTarget "u")
                (FGridReference "u" [GridIndex "i" 0]) ]
        }
      expected = unlines
        [ "dimension :: 1"
        , "axes :: x"
        , ""
        , "double :: dt = 0.1*dx*dx"
        , ""
        , "extern function :: exp"
        , ""
        , "begin function u = init()"
        , "  double [] :: u"
        , "  u[i] = exp(x)"
        , "end function"
        , ""
        , "begin function u' = step(u)"
        , "  u'[i] = u[i]"
        , "end function"
        ]
  assertEqual "program layout" (Right expected) (renderProgram program)

field
    :: FieldId -> String -> Layout -> [Int] -> [Maybe Variance]
    -> LogicalFieldDecl
field fieldId name layout shape declared = LogicalFieldDecl
  { logicalFieldId = fieldId
  , logicalFieldSourceName = name
  , logicalFieldPolicy = CollocatedPolicy
  , logicalFieldTensorType = TensorType shape
      (replicate (length shape) VarianceDown) 0
  , logicalFieldLayout = layout
  , logicalFieldDeclaredVariances = declared
  , logicalFieldLifetime = UserStateLifetime
  , logicalFieldOrigin = OriginId 1
  }

assertEqual :: (Eq a, Show a) => String -> a -> a -> IO ()
assertEqual label expected actual
  | expected == actual = pure ()
  | otherwise = fail
      (label ++ ": expected " ++ show expected ++ ", got " ++ show actual)
