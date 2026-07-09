module Formurae.Syntax where

data Kind = Scalar | Vector Bool | Form Int | SymM | AntiM | Tensor2 Bool
  deriving (Eq, Show)

data FieldLayout =
    ScalarLayout
  | Rank1Layout
  | SymRank2Layout
  | AntiRank2Layout
  | FullRank2Layout
  deriving (Eq, Show)

data Variance = VUp | VDown deriving (Eq, Show)

data IxPart = IxPart Variance String deriving (Eq, Show)

data IndexGroup =
    Plain [IxPart]
  | Symmetric [IxPart]
  | Antisymmetric [IxPart]
  deriving (Eq, Show)

data FieldIndex = FieldIndex { fiGroups :: [IndexGroup] } deriving (Eq, Show)

data FieldDecl = FieldDecl
  { fdName      :: String
  , fdIndex     :: Maybe FieldIndex
  , fdLayout    :: FieldLayout
  , fdStaggered :: Bool
  , fdKind      :: Kind
  } deriving (Eq, Show)

data Init = IRaw String String | IVec String [String]
          | ISym String [String]
          | IAnti String [String]
          | ITensor2 String [String]
          | ICas String String
          | ICasIndex String [IxPart] String

data SK = KLet | KLocal | KEq deriving Eq

data Step = Step { sk :: SK, sNm :: String, sIdx :: [IxPart], sEx :: String }

data TensorDef = TensorDef
  { tdName     :: String
  , tdParam    :: String
  , tdResultIx :: [IxPart]
  , tdBody     :: String
  }

data Model = Model
  { mName   :: String
  , mDim    :: Int
  , mAxes   :: [String]
  , mMetricName :: Maybe String
  , mUses   :: [(String, [String])]
  , mParams :: [(String, String)]
  , mHelp   :: [String]
  , mFlds   :: [(String, Kind)]
  , mFieldDecls :: [FieldDecl]
  , mInits  :: [Init]
  , mSteps  :: [Step]
  , mDd     :: Maybe String
  , mMetric :: Maybe [String]
  , mEmbed  :: Maybe [String]
  , mTensorDefs :: [TensorDef]
  , mDefs   :: [(String, (String, String))]
  }

data Tok = TId String Bool | TC Char

data Elem = EId String Bool | EC Char | ERaw String
          | EMarkV String | EMarkL String

kindOf :: Model -> String -> Maybe Kind
kindOf m nm = lookup nm (mFlds m)

fieldDeclOf :: Model -> String -> Maybe FieldDecl
fieldDeclOf m nm =
  case [fd | fd <- mFieldDecls m, fdName fd == nm] of
    (fd:_) -> Just fd
    [] -> Nothing
