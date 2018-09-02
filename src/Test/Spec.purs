module Test.Spec (
  Name(..),
  Only(..),
  Result(..),
  Group(..),
  Spec(..),
  describe,
  describeOnly,
  pending,
  pending',
  it,
  itOnly,
  collect,
  countTests,
  class Delay
  ) where

import Prelude

import Control.Monad.State (State, modify, execState, runState)
import Control.Monad.State as State
import Data.Traversable (for, for_)
import Data.Tuple (snd)
import Effect.Aff (Aff)
import Effect.Exception (Error)
import Unsafe.Coerce (unsafeCoerce)

type Name = String
type Only = Boolean

data Group t
  = Describe Only Name (Array (Group t))
  | It Only Name t
  | Pending Name

data Result
  = Success
  | Failure Error

instance showResult :: Show Result where
  show Success = "Success"
  show (Failure err) = "Failure (Error ...)"

instance eqResult :: Eq Result where
  eq Success Success = true
  eq (Failure _) (Failure _) = true
  eq _ _ = false

instance showGroup :: Show t => Show (Group t) where
  show (Describe only name groups) = "Describe " <> show only <> " " <> show name <> " " <> show groups
  show (It only name test) = "It " <> show only <> " " <> show name <> " " <> show test
  show (Pending name) = "Describe " <> show name

instance eqGroup :: Eq t => Eq (Group t) where
  eq (Describe o1 n1 g1) (Describe o2 n2 g2) = o1 == o2 && n1 == n2 && g1 == g2
  eq (It o1 n1 t1)       (It o2 n2 t2)       = o1 == o2 && n1 == n2 && t1 == t2
  eq (Pending n1)        (Pending n2)        = n1 == n2
  eq _                   _                   = false

-- Specifications with unevaluated tests.
type Spec t = State (Array (Group (Aff Unit))) t

collect :: Spec Unit
        -> Array (Group (Aff Unit))
collect r = snd $ runState r []

-- | Count the total number of tests in a spec
countTests :: Spec Unit -> Int
countTests spec = execState (for (collect spec) go) 0
  where
  go (Describe _ _ xs) = for_ xs go
  go _ = void $ State.modify (_ + 1)

---------------------
--       DSL       --
---------------------

-- | Combine a group of specs into a described hierarchy that either has the
-- |"only" modifier applied or not.
_describe :: Boolean
         -> String
         -> Spec Unit
         -> Spec Unit
_describe only name its =
  modify (_ <> [Describe only name (collect its)]) $> unit

-- | Combine a group of specs into a described hierarchy.
describe :: String
         -> Spec Unit
         -> Spec Unit
describe = _describe false

-- | Combine a group of specs into a described hierarchy and mark it as the
-- | only group to actually be evaluated. (useful for quickly narrowing down
-- | on a set)
describeOnly :: String
         -> Spec Unit
         -> Spec Unit
describeOnly = _describe true

-- | Create a pending spec.
pending :: String
        -> Spec Unit
pending name = void $ modify $ \p -> p <> [Pending name]

-- | Create a pending spec with a body that is ignored by
-- | the runner. It can be useful for documenting what the
-- | spec should test when non-pending.
pending' :: String
         -> (Delay => Aff Unit)
         -> Spec Unit
pending' name _ = pending name

-- | Create a spec with a description that either has the "only" modifier
-- | applied or not
_it :: Boolean
   -> String
   -> Aff Unit
   -> Spec Unit
_it only description tests = modify (_ <> [It only description tests]) $> unit

-- | Create a spec with a description.
it :: String
   -> (Delay => Aff Unit)
   -> Spec Unit
it description tests = _it false description (delayAff tests)

-- | Create a spec with a description and mark it as the only one to
-- | be run. (useful for quickly narrowing down on a single test)
itOnly :: String
   -> (Delay => Aff Unit)
   -> Spec Unit
itOnly description tests = _it true description (delayAff tests)

-- | A dummy constraint used to delay evaluation of expressions.
class Delay

-- | Delay evaluation of an `Aff` action until its execution.
-- | 
-- | >>> const unit (unsafeCrashWith "fail" :: Aff Unit)
-- | Error: fail
-- | >>> const unit (delayAff (unsafeCrashWith "fail" :: Aff Unit))
-- | unit
-- |
-- | This is useful for `Aff` actions used in tests, which can sometimes
-- | crash during evaluation, causing the test suite construction to fail.
-- | Using this function, the failure can be postponed until it can be caught
-- | by the test driver.
-- |
-- | A similar trick is used in the
-- | [call-by-name](https://github.com/natefaubion/purescript-call-by-name) library.
delayAff :: forall a. (Delay => Aff a) -> Aff a
delayAff x = pure unit >>= (unsafeCoerce :: (Delay => Aff a) -> (Unit -> Aff a)) x
