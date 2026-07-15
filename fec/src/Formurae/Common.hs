module Formurae.Common where

import Data.Char
  (isAlpha, isAlphaNum, isDigit, isHexDigit, isLetter, isSpace)
import Data.List (dropWhileEnd, isPrefixOf, stripPrefix)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

fatal :: String -> IO a
fatal msg = hPutStrLn stderr ("pre-fec: error: " ++ msg) >> exitFailure

strip, rstrip :: String -> String
rstrip = dropWhileEnd isSpace
strip = dropWhile isSpace . rstrip

isW :: Char -> Bool
isW c = isAlphaNum c || c == '_'

-- | Remove Egison line comments while preserving strings, character
-- literals, and nested block comments.  Unlike the historical line-local
-- implementation, this function may be applied to a complete source file so
-- block-comment state is carried across newlines.
stripEgisonLineComments :: String -> String
stripEgisonLineComments = inCode
  where
    inCode :: String -> String
    inCode [] = []
    inCode source
      | Just (identifier, rest) <- takeEgisonIdentifier source =
          identifier ++ inCode rest
      | Just (literal, rest) <- takeCharLiteral source =
          literal ++ inCode rest
    inCode ('-':'-':rest) = inLineComment rest
    inCode ('{':'-':rest) = '{' : '-' : inBlockComment 1 rest
    inCode ('"':rest) = '"' : inString rest
    inCode source
      | Just (operator, rest) <- takeEgisonOperator source =
          operator ++ inCode rest
    inCode (c:cs) = c : inCode cs

    inLineComment :: String -> String
    inLineComment [] = []
    inLineComment ('\n':rest) = '\n' : inCode rest
    inLineComment (_:rest) = inLineComment rest

    insideString :: String -> String
    insideString ('\\':escaped:rest) = '\\' : escaped : insideString rest
    insideString ('"':rest) = '"' : inCode rest
    insideString (c:cs) = c : insideString cs
    insideString [] = []

    inString :: String -> String
    inString = insideString

    inBlockComment :: Int -> String -> String
    inBlockComment _ [] = []
    inBlockComment depth ('{':'-':rest) =
      '{' : '-' : inBlockComment (depth + 1) rest
    inBlockComment depth ('-':'}':rest)
      | depth == 1 = '-' : '}' : inCode rest
      | otherwise = '-' : '}' : inBlockComment (depth - 1) rest
    inBlockComment depth (c:cs) = c : inBlockComment depth cs

-- | Replace every non-code character in Egison source with a space while
-- preserving newlines and the positions of executable tokens.  This is used
-- by source capability checks; recognizing character literals is essential
-- because @'"'@ must not open a string that masks the remainder of the line.
maskEgisonNonCode :: String -> String
maskEgisonNonCode = inCode
  where
    inCode :: String -> String
    inCode [] = []
    inCode source
      | Just (identifier, rest) <- takeEgisonIdentifier source =
          identifier ++ inCode rest
      | Just (literal, rest) <- takeCharLiteral source =
          mask literal ++ inCode rest
    inCode ('-':'-':rest) = ' ' : ' ' : inLineComment rest
    inCode ('{':'-':rest) = ' ' : ' ' : inBlockComment 1 rest
    inCode ('"':rest) = ' ' : inString rest
    inCode source
      | Just (operator, rest) <- takeEgisonOperator source =
          operator ++ inCode rest
    inCode (c:cs) = c : inCode cs

    inLineComment :: String -> String
    inLineComment [] = []
    inLineComment ('\n':rest) = '\n' : inCode rest
    inLineComment (_:rest) = ' ' : inLineComment rest

    inString :: String -> String
    inString [] = []
    inString ('\\':_escaped:rest) = ' ' : ' ' : inString rest
    inString ('"':rest) = ' ' : inCode rest
    inString ('\n':rest) = '\n' : inString rest
    inString (_:rest) = ' ' : inString rest

    inBlockComment :: Int -> String -> String
    inBlockComment _ [] = []
    inBlockComment depth ('{':'-':rest) =
      ' ' : ' ' : inBlockComment (depth + 1) rest
    inBlockComment depth ('-':'}':rest)
      | depth == 1 = ' ' : ' ' : inCode rest
      | otherwise = ' ' : ' ' : inBlockComment (depth - 1) rest
    inBlockComment depth ('\n':rest) =
      '\n' : inBlockComment depth rest
    inBlockComment depth (_:rest) = ' ' : inBlockComment depth rest

    mask = map (\c -> if c == '\n' then '\n' else ' ')

-- | Transform complete executable Egison identifiers while copying all other
-- source verbatim.  Identifiers inside strings, character literals, and
-- comments are deliberately left untouched.  This is the shared lexical
-- layer used when raw definitions rename ambient coordinate variables.
mapEgisonCodeIdentifiers :: (String -> String) -> String -> String
mapEgisonCodeIdentifiers transform = inCode
  where
    inCode :: String -> String
    inCode [] = []
    inCode source
      | Just (identifier, rest) <- takeEgisonIdentifier source =
          transform identifier ++ inCode rest
      | Just (literal, rest) <- takeCharLiteral source =
          literal ++ inCode rest
    inCode ('-':'-':rest) = '-' : '-' : inLineComment rest
    inCode ('{':'-':rest) = '{' : '-' : inBlockComment 1 rest
    inCode ('"':rest) = '"' : inString rest
    inCode source
      | Just (operator, rest) <- takeEgisonOperator source =
          operator ++ inCode rest
    inCode (character:rest) = character : inCode rest

    inLineComment :: String -> String
    inLineComment [] = []
    inLineComment ('\n':rest) = '\n' : inCode rest
    inLineComment (character:rest) = character : inLineComment rest

    inString :: String -> String
    inString [] = []
    inString ('\\':escaped:rest) = '\\' : escaped : inString rest
    inString ('"':rest) = '"' : inCode rest
    inString (character:rest) = character : inString rest

    inBlockComment :: Int -> String -> String
    inBlockComment _ [] = []
    inBlockComment depth ('{':'-':rest) =
      '{' : '-' : inBlockComment (depth + 1) rest
    inBlockComment depth ('-':'}':rest)
      | depth == 1 = '-' : '}' : inCode rest
      | otherwise = '-' : '}' : inBlockComment (depth - 1) rest
    inBlockComment depth (character:rest) =
      character : inBlockComment depth rest

-- Egison uses apostrophes both in identifiers and for character literals.
-- These two forms cover a literal character and a one-character escape,
-- including the security-relevant @'"'@ and @'\\"'@ spellings, without
-- mistaking a prime-suffixed identifier such as @flipIndices'@ for a literal.
takeCharLiteral :: String -> Maybe (String, String)
takeCharLiteral ('\'':'\\':rest) = do
  (escape, afterEscape) <- takeCharacterEscape rest
  case afterEscape of
    '\'' : remaining ->
      Just ('\'' : '\\' : escape ++ "'", remaining)
    _ -> Nothing
takeCharLiteral ('\'':character:'\'':rest)
  | character /= '\n'
  , character /= '\r'
  , character /= '\\'
  , character /= '\'' =
      Just (['\'', character, '\''], rest)
takeCharLiteral _ = Nothing

takeCharacterEscape :: String -> Maybe (String, String)
takeCharacterEscape (character:rest)
  | character `elem` "abfnrtv\\\"'" = Just ([character], rest)
takeCharacterEscape ('^':character:rest) = Just (['^', character], rest)
takeCharacterEscape ('o':first:rest)
  | first `elem` "01234567" =
      let (digits, remaining) = span (`elem` "01234567") rest
      in Just ('o' : first : digits, remaining)
takeCharacterEscape ('x':first:rest)
  | isHexDigit first =
      let (digits, remaining) = span isHexDigit rest
      in Just ('x' : first : digits, remaining)
takeCharacterEscape source@(first:_)
  | isDigit first =
      let (digits, remaining) = span isDigit source
      in Just (digits, remaining)
takeCharacterEscape source = firstNamedEscape namedEscapes
  where
    firstNamedEscape [] = Nothing
    firstNamedEscape (name:names) =
      case stripPrefix name source of
        Just remaining -> Just (name, remaining)
        Nothing -> firstNamedEscape names

    -- Longest prefixes precede their shorter ASCII control-code names.
    namedEscapes =
      [ "NUL", "SOH", "STX", "ETX", "EOT", "ENQ", "ACK", "BEL"
      , "DLE", "DC1", "DC2", "DC3", "DC4", "NAK", "SYN", "ETB"
      , "CAN", "SUB", "ESC", "DEL", "BS", "HT", "LF", "VT", "FF"
      , "CR", "SO", "SI", "EM", "FS", "GS", "RS", "US", "SP"
      ]


-- Egison identifiers may contain prime marks and qualified operator
-- segments, for example @safe'x'@ and @M.--foo@.  Consume the complete token
-- before looking for quote/comment openers so those characters are not
-- reinterpreted in the middle of an identifier.
takeEgisonIdentifier :: String -> Maybe (String, String)
takeEgisonIdentifier (first:rest)
  | isEgisonIdentifierHead first =
      let (suffix, remaining) = takeTail rest
      in Just (first : suffix, remaining)
  where
    takeTail [] = ([], [])
    takeTail source@(character:remaining)
      | isEgisonIdentifierCharacter character =
          let (suffix, final) = takeTail remaining
          in (character : suffix, final)
      | character == '.'
      , not (startsWithDot remaining) =
          let (operators, afterOperators) = span isEgisonOperatorCharacter remaining
              (suffix, final) = takeTail afterOperators
          in ('.' : operators ++ suffix, final)
      | otherwise = ([], source)

    startsWithDot ('.':_) = True
    startsWithDot _ = False
takeEgisonIdentifier _ = Nothing

takeEgisonOperator :: String -> Maybe (String, String)
takeEgisonOperator source@(first:_)
  | isEgisonOperatorCharacter first =
      let (operator, rest) = span isEgisonOperatorCharacter source
      in Just (operator, rest)
takeEgisonOperator _ = Nothing

egisonIdentifiers :: String -> [String]
egisonIdentifiers [] = []
egisonIdentifiers source
  | Just (identifier, rest) <- takeEgisonIdentifier source =
      identifier : egisonIdentifiers rest
egisonIdentifiers (_:rest) = egisonIdentifiers rest

-- | Extract complete Egison identifiers together with any contiguous
-- Formurae tensor-index suffix.  Consumers that need variance information
-- can pass each spelling to 'parseIndexedIdent' without falling back to the
-- simpler surface tokenizer, which would split prime/qualified identifiers.
egisonIndexedIdentifiers :: String -> [String]
egisonIndexedIdentifiers [] = []
egisonIndexedIdentifiers source
  | Just (identifier, rest) <- takeEgisonIdentifier source =
      let (suffix, remaining) = takeIndexSuffix rest
      in (identifier ++ suffix) : egisonIndexedIdentifiers remaining
egisonIndexedIdentifiers (_:rest) = egisonIndexedIdentifiers rest

egisonOperators :: String -> [String]
egisonOperators [] = []
egisonOperators source
  | Just (_, rest) <- takeEgisonIdentifier source = egisonOperators rest
  | Just (operator, rest) <- takeEgisonOperator source =
      operator : egisonOperators rest
egisonOperators (_:rest) = egisonOperators rest

takeIndexSuffix :: String -> (String, String)
takeIndexSuffix source =
  let (appendMarker, afterAppend) =
        case source of
          '.':'.':'.':rest -> ("...", rest)
          _ -> ("", source)
      (marks, remaining) = takeMarks afterAppend
  in (appendMarker ++ marks, remaining)
  where
    takeMarks (marker:first:rest)
      | marker `elem` "_~"
      , isAlphaNum first =
          let (nameTail, remaining) = span isAlphaNum rest
              (more, final) = takeMarks remaining
          in (marker : first : nameTail ++ more, final)
    takeMarks remaining = ("", remaining)

isEgisonIdentifierHead :: Char -> Bool
isEgisonIdentifierHead character =
  isLetter character || character `elem` "∂∇"

isEgisonIdentifierCharacter :: Char -> Bool
isEgisonIdentifierCharacter character =
  isAlphaNum character || character `elem` "?'/∂∇"

isEgisonOperatorCharacter :: Char -> Bool
isEgisonOperatorCharacter character =
  character `elem` ("%^&*-+\\|:<>=?!./'#@$" ++ "∧")

stripComment :: String -> String
stripComment = stripEgisonLineComments

reservedInternalPrefix :: String
reservedInternalPrefix = "FormuraeInternal"

isReservedInternalName :: String -> Bool
isReservedInternalName = isPrefixOf reservedInternalPrefix

-- These names provide the capability to construct or encode the opaque
-- FunctionData nodes that cross the trusted Egison/FEIR boundary.  Surface
-- source must not access either constructor directly, nor reach it through
-- the generated Formurae/FEIR namespaces.  The parser applies this predicate
-- only to identifiers outside comments and string literals.
isReservedNormalizationCapability :: String -> Bool
isReservedNormalizationCapability name =
  isReservedInternalName name
  || "Formurae." `isPrefixOf` name
  || "FEIR." `isPrefixOf` name
  || name `elem`
       [ "functionSymbol"
       , "formuraeOpaqueBarrier"
       , "Formurae"
       , "FEIR"
       ]

rejectReservedName :: Int -> String -> IO ()
rejectReservedName ln nm =
  if isReservedInternalName nm
    then fatal ("identifier is reserved for generated code: " ++ nm
                ++ " (line " ++ show ln ++ ")")
    else return ()

validSurfaceName :: String -> Bool
validSurfaceName (c:cs) = isAlpha c && all isAlphaNum cs
validSurfaceName [] = False

splitOn :: Char -> String -> [String]
splitOn ch = foldr step [[]]
  where
    step c acc@(cur:rest) | c == ch = [] : acc
                          | otherwise = (c : cur) : rest
    step _ [] = [[]]

-- split on a separator at paren/bracket depth 0
splitTop :: Char -> String -> [String]
splitTop sep = go 0 []
  where
    go :: Int -> String -> String -> [String]
    go _ acc [] = [strip (reverse acc)]
    go d acc (c:cs)
      | c `elem` "([" = go (d + 1) (c : acc) cs
      | c `elem` ")]" = go (d - 1) (c : acc) cs
      | c == sep && d == 0 = strip (reverse acc) : go 0 [] cs
      | otherwise = go d (c : acc) cs
