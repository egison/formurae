module Formurae.Syntax where

import Data.Char (isAlpha, isAlphaNum, isSpace)

data Mode = CollocatedMode | DecMode
  deriving (Eq, Show)

data GridPolicy = Collocated | Primal | Dual
  deriving (Eq, Show)

data Kind = Scalar | Vector | Form Int | SymM | AntiM | Tensor2
  deriving (Eq, Show)

data Variance = VUp | VDown deriving (Eq, Show)

data SurfaceLatticeClass
  = SurfaceCollocated
  | SurfaceStaggered
  deriving (Eq, Show)

data SurfaceStencilFamily
  = SurfaceCentered
  | SurfaceYee
  deriving (Eq, Show)

data DiscretizationDecl = DiscretizationDecl
  { discretizationLatticeClass :: SurfaceLatticeClass
  , discretizationDerivativeOrder :: Maybe Int
  , discretizationStencilFamily :: SurfaceStencilFamily
  , discretizationFormalAccuracy :: Int
  , discretizationSourceLine :: Int
  } deriving (Eq, Show)

data IxPart = IxPart Variance String deriving (Eq, Show)

data IndexGroup =
    Plain [IxPart]
  | Symmetric [IxPart]
  | Antisymmetric [IxPart]
  deriving (Eq, Show)

newtype FieldIndex = FieldIndex IndexGroup deriving (Eq, Show)

data FieldDecl = FieldDecl
  { fdName      :: String
  , fdIndex     :: Maybe FieldIndex
  , fdPolicy    :: GridPolicy
  , fdKind      :: Kind
  , fdSourceLine :: Int
  } deriving (Eq, Show)

data Init = IRaw String String | IVec String [String]
          | ISym String [String]
          | IAnti String [String]
          | ITensor2 String [String]
          | ICas String String
          | ICasIndex String [IxPart] String

data HelperKind = ExternalHelper | RawHelper
  deriving (Eq, Show)

data SK = KLet | KLocal | KEq deriving Eq

data SourcePosition = SourcePosition
  { positionLine   :: Int
  , positionColumn :: Int
  } deriving (Eq, Show)

-- One expression as it appeared in the original .fme source and after
-- transliteration.  Every character in `sourceTranslated` maps to its exact
-- original line/column; multi-character transliterations therefore map back
-- to the single source character that produced them, and multiline
-- initializers retain their physical lines instead of flattened columns.
data SourceText = SourceText
  { sourcePath       :: FilePath
  , sourceLine       :: Int
  , sourceColumn     :: Int
  , sourceOriginal   :: String
  , sourceTranslated :: String
  , sourcePositionMap :: [SourcePosition]
  } deriving (Eq, Show)

data Step = Step
  { sk :: SK
  , sNm :: String
  , sIdx :: [IxPart]
  , sEx :: String
  , sSourceText :: SourceText
  }

data Def = Def
  { defName   :: String
  , defParams :: [String]
  , defBody   :: String
  , defSourceText :: Maybe SourceText
  } deriving (Eq, Show)

data Model = Model
  { mName   :: String
  , mSourcePath :: FilePath
  , mDim    :: Int
  , mAxes   :: [String]
  , mAxesSourceLine :: Maybe Int
  , mMode   :: Maybe Mode
  , mMetricName :: Maybe String
  , mParams :: [(String, String)]
  , mParamSourceLines :: [Int]
  , mHelp   :: [String]
  , mHelpKinds :: [HelperKind]
  , mHelpSourceLines :: [Int]
  , mFieldDecls :: [FieldDecl]
  , mInits  :: [Init]
  , mInitSourceTexts :: [SourceText]
  , mSteps  :: [Step]
  , mDd     :: Maybe String
  , mMetric :: Maybe [String]
  , mEmbed  :: Maybe [String]
  , mDefs   :: [Def]
  , mDiscretizationDecls :: [DiscretizationDecl]
  }

selectedMode :: Model -> Mode
selectedMode m =
  case mMode m of
    Just mode -> mode
    Nothing -> error "selectedMode: mode declaration has not been validated"

data Tok = TId String Bool | TC Char

tokenize :: String -> [Tok]
tokenize [] = []
tokenize (c:cs)
  | isAlpha c =
      let (a, b) = span isWordChar cs
      in case b of
           ('\'':b') -> TId (c : a) True : tokenize b'
           _ -> TId (c : a) False : tokenize b
  | otherwise = TC c : tokenize cs
  where
    isWordChar ch = isAlphaNum ch || ch == '_'

untok :: [Tok] -> String
untok = concatMap out
  where
    out (TId nm pr) = nm ++ (if pr then "'" else "")
    out (TC c) = [c]

isSpTok :: Tok -> Bool
isSpTok (TC c) = isSpace c
isSpTok _ = False

kindOf :: Model -> String -> Maybe Kind
kindOf m nm = fdKind <$> fieldDeclOf m nm

fieldDeclOf :: Model -> String -> Maybe FieldDecl
fieldDeclOf m nm =
  case [fd | fd <- mFieldDecls m, fdName fd == nm] of
    (fd:_) -> Just fd
    [] -> Nothing
