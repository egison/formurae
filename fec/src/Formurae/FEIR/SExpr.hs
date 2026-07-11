module Formurae.FEIR.SExpr
  ( SExpr(..)
  , SExprError(..)
  , parseSExpr
  , parseSExprs
  , renderSExpr
  ) where

import Data.Char (chr, digitToInt, isHexDigit, isSpace, ord)

data SExpr
  = Atom String
  | StringAtom String
  | List [SExpr]
  deriving (Eq, Ord, Show)

data SExprError = SExprError
  { sexprErrorLine :: Int
  , sexprErrorColumn :: Int
  , sexprErrorMessage :: String
  } deriving (Eq, Ord, Show)

data Cursor = Cursor
  { cursorInput :: String
  , cursorLine :: Int
  , cursorColumn :: Int
  }

parseSExpr :: String -> Either SExprError SExpr
parseSExpr source = do
  (forms, rest) <- parseMany (Cursor source 1 1)
  case forms of
    [form] -> Right form
    [] -> Left (errorAt rest "expected one S-expression")
    _ -> Left (SExprError 1 1 "expected exactly one S-expression")

parseSExprs :: String -> Either SExprError [SExpr]
parseSExprs source = fst <$> parseMany (Cursor source 1 1)

parseMany :: Cursor -> Either SExprError ([SExpr], Cursor)
parseMany cursor0 = go [] (skipTrivia cursor0)
  where
    go acc cursor =
      case cursorInput cursor of
        [] -> Right (reverse acc, cursor)
        ')' : _ -> Left (errorAt cursor "unexpected ')'")
        _ -> do
          (form, rest) <- parseOne cursor
          go (form : acc) (skipTrivia rest)

parseOne :: Cursor -> Either SExprError (SExpr, Cursor)
parseOne cursor0 =
  let cursor = skipTrivia cursor0
  in case cursorInput cursor of
       [] -> Left (errorAt cursor "unexpected end of input")
       '(' : _ -> parseList (advance cursor)
       ')' : _ -> Left (errorAt cursor "unexpected ')'")
       '"' : _ -> parseString (advance cursor)
       _ -> parseAtom cursor

parseList :: Cursor -> Either SExprError (SExpr, Cursor)
parseList = go [] . skipTrivia
  where
    go acc cursor =
      case cursorInput cursor of
        [] -> Left (errorAt cursor "unterminated list")
        ')' : _ -> Right (List (reverse acc), advance cursor)
        _ -> do
          (form, rest) <- parseOne cursor
          go (form : acc) (skipTrivia rest)

parseString :: Cursor -> Either SExprError (SExpr, Cursor)
parseString = go []
  where
    go acc cursor =
      case cursorInput cursor of
        [] -> Left (errorAt cursor "unterminated string")
        '"' : _ -> Right (StringAtom (reverse acc), advance cursor)
        '\\' : _ -> do
          (escaped, rest) <- parseEscape (advance cursor)
          go (escaped : acc) rest
        c : _
          | ord c < 0x20 -> Left (errorAt cursor "unescaped control character in string")
          | otherwise -> go (c : acc) (advance cursor)

parseEscape :: Cursor -> Either SExprError (Char, Cursor)
parseEscape cursor =
  case cursorInput cursor of
    [] -> Left (errorAt cursor "unterminated string escape")
    '"' : _ -> Right ('"', advance cursor)
    '\\' : _ -> Right ('\\', advance cursor)
    'n' : _ -> Right ('\n', advance cursor)
    'r' : _ -> Right ('\r', advance cursor)
    't' : _ -> Right ('\t', advance cursor)
    'u' : _ -> parseUnicodeEscape (advance cursor)
    c : _ -> Left (errorAt cursor ("unknown string escape: \\" ++ [c]))

parseUnicodeEscape :: Cursor -> Either SExprError (Char, Cursor)
parseUnicodeEscape cursor =
  case cursorInput cursor of
    '{' : _ ->
      let afterOpen = advance cursor
          (digits, rest) = spanCursor isHexDigit afterOpen
      in case cursorInput rest of
           '}' : _
             | not (null digits) && length digits <= 6 ->
                 let value = foldl (\n d -> n * 16 + digitToInt d) 0 digits
                 in if value <= 0x10ffff
                      && not (value >= 0xd800 && value <= 0xdfff)
                      then Right (chr value, advance rest)
                      else Left (errorAt afterOpen "invalid Unicode scalar value")
           _ -> Left (errorAt rest "expected '}' after Unicode escape")
    _ -> Left (errorAt cursor "expected '{' after \\u")

parseAtom :: Cursor -> Either SExprError (SExpr, Cursor)
parseAtom cursor =
  let (chars, rest) = spanCursor isAtomChar cursor
  in if null chars
       then Left (errorAt cursor "expected atom")
       else Right (Atom chars, rest)
  where
    isAtomChar c = not (isSpace c || c `elem` "();\"")

spanCursor :: (Char -> Bool) -> Cursor -> (String, Cursor)
spanCursor predicate = go []
  where
    go acc cursor =
      case cursorInput cursor of
        c : _ | predicate c -> go (c : acc) (advance cursor)
        _ -> (reverse acc, cursor)

skipTrivia :: Cursor -> Cursor
skipTrivia cursor =
  case cursorInput cursor of
    c : _ | isSpace c -> skipTrivia (advance cursor)
    ';' : _ -> skipTrivia (skipComment (advance cursor))
    _ -> cursor

skipComment :: Cursor -> Cursor
skipComment cursor =
  case cursorInput cursor of
    [] -> cursor
    '\n' : _ -> advance cursor
    _ -> skipComment (advance cursor)

advance :: Cursor -> Cursor
advance cursor =
  case cursorInput cursor of
    [] -> cursor
    '\n' : rest -> Cursor rest (cursorLine cursor + 1) 1
    _ : rest -> Cursor rest (cursorLine cursor) (cursorColumn cursor + 1)

errorAt :: Cursor -> String -> SExprError
errorAt cursor message =
  SExprError (cursorLine cursor) (cursorColumn cursor) message

renderSExpr :: SExpr -> String
renderSExpr (Atom atom) = atom
renderSExpr (StringAtom value) = '"' : concatMap escapeChar value ++ "\""
renderSExpr (List forms) = "(" ++ unwords (map renderSExpr forms) ++ ")"

escapeChar :: Char -> String
escapeChar '"' = "\\\""
escapeChar '\\' = "\\\\"
escapeChar '\n' = "\\n"
escapeChar '\r' = "\\r"
escapeChar '\t' = "\\t"
escapeChar c
  | ord c < 0x20 = "\\u{" ++ showHex (ord c) ++ "}"
  | otherwise = [c]

showHex :: Int -> String
showHex 0 = "0"
showHex value = reverse (go value)
  where
    digits = "0123456789abcdef"
    go 0 = []
    go n = (digits !! (n `mod` 16)) : go (n `div` 16)
