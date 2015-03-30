{-# LANGUAGE ConstraintKinds       #-}
{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE DeriveFunctor         #-}
{-# LANGUAGE DeriveGeneric         #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE RankNTypes            #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE TypeFamilies          #-}
{-# LANGUAGE TypeSynonymInstances  #-}

-- | "getopt-generics" tries to make it very simple to create command line
-- argument parsers. Documentation can be found in the
-- <https://github.com/zalora/getopt-generics#getopt-generics README>.

module System.Console.GetOpt.Generics (
  withArguments,
  parseArguments,
  Result(..),
  Option(..),
 ) where

import           Control.Applicative
import           Data.Char
import           Data.List
import           Data.Monoid (Monoid, mempty)
import           Generics.SOP
import           Safe
import           System.Console.GetOpt
import           System.Environment
import           System.Exit
import           System.IO

withArguments :: (Generic a, HasDatatypeInfo a, All2 Option (Code a)) =>
  (a -> IO ()) -> IO ()
withArguments action = do
  args <- getArgs
  progName <- getProgName
  case parseArguments progName args of
    Success a -> action a
    OutputAndExit message -> do
      putStrLn message
    Errors errs -> do
      mapM_ (hPutStrLn stderr) errs
      exitWith $ ExitFailure 1

data Result a
  = Success a
  | OutputAndExit String
  | Errors [String]
  deriving (Show, Eq, Ord)

parseArguments :: forall a . (Generic a, HasDatatypeInfo a, All2 Option (Code a)) =>
  String -> [String] -> Result a
parseArguments header args = case datatypeInfo (Proxy :: Proxy a) of
    ADT typeName _ (constructorInfo :* Nil) ->
      case constructorInfo of
        (Record _ fields) -> processFields header args fields
        Constructor{} ->
          err typeName "constructors without field labels"
        Infix{} ->
          err typeName "infix constructors"
    ADT typeName _ Nil ->
      err typeName "empty data types"
    ADT typeName _ (_ :* _ :* _) ->
      err typeName "sum-types"
    Newtype _ _ (Record _ fields) ->
      processFields header args fields
    Newtype typeName _ (Constructor _) ->
      err typeName "constructors without field labels"
  where
    err typeName message =
      Errors ["getopt-generics doesn't support " ++ message ++ " (" ++ typeName ++ ")."]

processFields :: forall a xs . (Generic a, Code a ~ '[xs], SingI xs, All Option xs) =>
  String -> [String] -> NP FieldInfo xs -> Result a
processFields header args fields =
  helpWrapper header args fields $
  fmap (to . SOP . Z) $
  case getOpt Permute (mkOptDescrs fields) args of
    (options, arguments, parseErrors) ->
      let result :: Either [String] (NP I xs) =
            collectErrors $ project options (mkEmptyArguments fields)
          allErrors =
            parseErrors ++
            map mkUnknownArgumentError arguments ++
            ignoreRight result
      in case allErrors of
        [] -> result
        _ -> Left allErrors
  where
    mkUnknownArgumentError :: String -> String
    mkUnknownArgumentError arg = "unknown argument: " ++ arg

    ignoreRight :: Monoid e => Either e o -> e
    ignoreRight = either id (const mempty)

mkOptDescrs :: forall xs . All Option xs =>
  NP FieldInfo xs -> [OptDescr (NS FieldState xs)]
mkOptDescrs fields =
  map toOptDescr $ sumList $ npMap mkOptDescr fields

newtype OptDescrE a = OptDescrE (OptDescr (FieldState a))

mkOptDescr :: forall a . Option a => FieldInfo a -> OptDescrE a
mkOptDescr (FieldInfo name) = OptDescrE $ Option [] [slugify name] toOption ""

slugify :: String -> String
slugify [] = []
slugify (x : xs)
  | isUpper x = '-' : toLower x : slugify xs
  | otherwise = x : slugify xs

toOptDescr :: NS OptDescrE xs -> OptDescr (NS FieldState xs)
toOptDescr (Z (OptDescrE a)) = fmap Z a
toOptDescr (S a) = fmap S (toOptDescr a)

mkEmptyArguments :: forall xs . (SingI xs, All Option xs) =>
  NP FieldInfo xs -> NP FieldState xs
mkEmptyArguments fields = case (sing :: Sing xs, fields) of
  (SNil, Nil) -> Nil
  (SCons, FieldInfo name :* r) ->
    emptyOption name :* mkEmptyArguments r
  _ -> uninhabited "mkEmpty"


-- * showing help?

helpWrapper :: (All Option xs) =>
  String -> [String] -> NP FieldInfo xs -> Either [String] a -> Result a
helpWrapper header args fields result =
    case getOpt Permute [helpOption] args of
      ([], _, _) -> case result of
        Left errs -> Errors errs
        Right a -> Success a
      (() : _, _, _) -> OutputAndExit $
        usageInfo header (mkOptDescrs fields)
  where
    helpOption = Option ['h'] ["help"] (NoArg ()) "show help and exit"


-- * helper functions for NS and NP

collectErrors :: NP FieldState xs -> Either [String] (NP I xs)
collectErrors np = case np of
  Nil -> Right Nil
  (a :* r) -> case (a, collectErrors r) of
    (FieldSuccess a, Right r) -> Right (I a :* r)
    (ParseErrors errs, r) -> Left (errs ++ either id (const []) r)
    (Unset err, r) -> Left (err : either id (const []) r)
    (FieldSuccess _, Left errs) -> Left errs

npMap :: (All Option xs) => (forall a . Option a => f a -> g a) -> NP f xs -> NP g xs
npMap _ Nil = Nil
npMap f (a :* r) = f a :* npMap f r

sumList :: NP f xs -> [NS f xs]
sumList Nil = []
sumList (a :* r) = Z a : map S (sumList r)

project :: (SingI xs, All Option xs) =>
  [NS FieldState xs] -> NP FieldState xs -> NP FieldState xs
project sums empty =
    foldl' inner empty sums
  where
    inner :: (All Option xs) =>
      NP FieldState xs -> NS FieldState xs -> NP FieldState xs
    inner (a :* r) (Z b) = combine a b :* r
    inner (a :* r) (S rSum) = a :* inner r rSum
    inner Nil _ = uninhabited "project"

impossible :: String -> a
impossible name = error ("System.Console.GetOpt.Generics." ++ name ++ ": This should never happen!")

uninhabited :: String -> a
uninhabited = impossible

-- * possible field types

data FieldState a
  = Unset String
  | ParseErrors [String]
  | FieldSuccess a
  deriving (Functor)

class Option a where
  toOption :: ArgDescr (FieldState a)
  emptyOption :: String -> FieldState a
  accumulate :: a -> a -> a
  accumulate _ x = x

combine :: Option a => FieldState a -> FieldState a -> FieldState a
combine _ (Unset _) = impossible "combine"
combine (ParseErrors e) (ParseErrors f) = ParseErrors (e ++ f)
combine (ParseErrors e) _ = ParseErrors e
combine (Unset _) x = x
combine (FieldSuccess _) (ParseErrors e) = ParseErrors e
combine (FieldSuccess a) (FieldSuccess b) = FieldSuccess (accumulate a b)

instance Option Bool where
  toOption = NoArg (FieldSuccess True)
  emptyOption _ = FieldSuccess False

instance Option String where
  toOption = ReqArg FieldSuccess "string"
  emptyOption flagName = Unset
    ("missing option: --" ++ flagName ++ "=string")

instance Option (Maybe String) where
  toOption = ReqArg (FieldSuccess . Just) "string (optional)"
  emptyOption _ = FieldSuccess Nothing

instance Option [String] where
  toOption = ReqArg (FieldSuccess . pure) "strings (multiple possible)"
  emptyOption _ = FieldSuccess []
  accumulate = (++)

parseInt :: String -> FieldState Int
parseInt s = maybe (ParseErrors ["not an integer: " ++ s]) FieldSuccess $ readMay s

instance Option Int where
  toOption = ReqArg parseInt "integer"
  emptyOption flagName = Unset
    ("missing option: --" ++ flagName ++ "=int")

instance Option (Maybe Int) where
  toOption = ReqArg (fmap Just . parseInt) "integer (optional)"
  emptyOption _ = FieldSuccess Nothing

instance Option [Int] where
  toOption = ReqArg (fmap pure . parseInt) "int (multiple possible)"
  emptyOption _ = FieldSuccess []
  accumulate = (++)
