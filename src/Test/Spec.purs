module Test.Spec (
  Name(..),
  Only(..),
  Result(..),
  Group(..),
  Spec(..),
  describe,
  describeOnly,
  parallel,
  sequential,
  pending,
  pending',
  it,
  itOnly,
  collect,
  countTests
  ) where

import Prelude
import Control.Monad.State as State
import Effect.Aff (Aff)
import Effect.Exception (Error)
import Control.Monad.State (State, execState, runState)
import Data.Traversable (for, for_)
import Data.Tuple (snd)

type Name = String
type Only = Boolean

data Group t
  = Describe Only Name (Array (Group t))
  | Parallel (Array (Group t))
  | Sequential (Array (Group t))
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
  show (Parallel groups) = "Parallel " <> show groups
  show (Sequential groups) = "Sequential " <> show groups
  show (Describe only name groups) = "Describe " <> show only <> " " <> show name <> " " <> show groups
  show (It only name test) = "It " <> show only <> " " <> show name <> " " <> show test
  show (Pending name) = "Describe " <> show name

instance eqGroup :: Eq t => Eq (Group t) where
  eq (Parallel g1)       (Parallel g2)       = g1 == g2
  eq (Sequential g1)     (Sequential g2)     = g1 == g2
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
_describe :: Only
         -> String
         -> Spec Unit
         -> Spec Unit
_describe opts name its =
  State.modify_ (_ <> [Describe opts name (collect its)])

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

-- | marks all spec items of the given spec to be safe for parallel evaluation.
parallel :: Spec Unit
         -> Spec Unit
parallel its = State.modify_ (_ <> [Parallel (collect its)])

-- | marks all spec items of the given spec to be evaluated sequentially.
sequential :: Spec Unit
           -> Spec Unit
sequential its = State.modify_ (_ <> [Sequential (collect its)])

-- | Create a pending spec.
pending :: String
        -> Spec Unit
pending name = State.modify_ (_ <> [Pending name])

-- | Create a pending spec with a body that is ignored by
-- | the runner. It can be useful for documenting what the
-- | spec should test when non-pending.
pending' :: String
        -> Aff Unit
        -> Spec Unit
pending' name _ = pending name

-- | Create a spec with a description that either has the "only" modifier
-- | applied or not
_it :: Boolean
   -> String
   -> Aff Unit
   -> Spec Unit
_it only description tests = State.modify_ (_ <> [It only description tests])

-- | Create a spec with a description.
it :: String
   -> Aff Unit
   -> Spec Unit
it = _it false

-- | Create a spec with a description and mark it as the only one to
-- | be run. (useful for quickly narrowing down on a single test)
itOnly :: String
   -> Aff Unit
   -> Spec Unit
itOnly = _it true
