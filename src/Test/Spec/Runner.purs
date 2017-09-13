module Test.Spec.Runner
       ( RunnerEffects
       , run
       , run'
       , runSpec
       , runSpec'
       , defaultConfig
       , timeout
       , Config
       , TestEvents
       , Reporter
       , PROCESS
       ) where

import Prelude
import Control.Monad.Eff.Exception as Error
import Test.Spec as Spec
import Test.Spec.Runner.Event as Event
import Control.Alternative ((<|>))
import Control.Monad.Aff (Aff, runAff, attempt, delay, throwError, try)
import Control.Monad.Eff (Eff, kind Effect)
import Control.Monad.Eff.Class (liftEff)
import Control.Monad.Eff.Console (logShow)
import Control.Monad.Eff.Exception (Error, error)
import Control.Monad.Trans.Class (lift)
import Control.Parallel (sequential, parallel)
import Data.Array (singleton)
import Data.Either (either)
import Data.Foldable (foldl)
import Data.Int (toNumber)
import Data.Maybe (Maybe(..), fromMaybe)
import Data.Time.Duration (Milliseconds(..))
import Data.Traversable (for)
import Pipes ((>->), yield)
import Pipes (for) as P
import Pipes.Core (Pipe, Producer, (//>))
import Pipes.Core (runEffectRec) as P
import Test.Spec (Spec, Group(..), Result(..), SpecEffects, collect)
import Test.Spec.Console (withAttrs)
import Test.Spec.Runner.Event (Event)
import Test.Spec.Speed (speedOf)
import Test.Spec.Summary (successful)

foreign import data PROCESS :: Effect

foreign import exit :: forall eff. Int -> Eff (process :: PROCESS | eff) Unit

type RunnerEffects e = SpecEffects (process :: PROCESS | e)

foreign import dateNow :: ∀ e. Eff e Int

type Config = {
  slow :: Int
, timeout :: Maybe Int
}

defaultConfig :: Config
defaultConfig = {
  slow: 75
, timeout: Just 2000
}

trim :: ∀ r. Array (Group r) -> Array (Group r)
trim xs = fromMaybe xs (singleton <$> findJust findOnly xs)
  where
  findOnly :: Group r -> Maybe (Group r)
  findOnly g@(It true _ _) = pure g
  findOnly g@(Describe o _ gs) = findJust findOnly gs <|> if o then pure g else Nothing
  findOnly _ = Nothing

  findJust :: forall a. (a -> Maybe a) -> Array a -> Maybe a
  findJust f = foldl go Nothing
    where
    go Nothing x = f x
    go acc _ = acc

makeTimeout
  :: ∀ e
   . Int
  -> Aff e Unit
makeTimeout time = do
  delay $ Milliseconds $ toNumber time
  throwError $ error $ "test timed out after " <> show time <> "ms"

timeout
  :: ∀ e
   . Int
  -> Aff (RunnerEffects e) Unit
  -> Aff (RunnerEffects e) Unit
timeout time t = do
  sequential (parallel (try (makeTimeout time)) <|> parallel (try t))
    >>= either throwError pure

-- Run the given spec as `Producer` in the underlying `Aff` monad.
-- This producer has two responsibilities:
--      1) emit events for key moments in the runner's lifecycle
--      2) collect the tst output into an array of results
-- This allows downstream consumers to report about the tests even before the
-- prodocer has completed and still benefit from the array of results the way
-- the runner sees it.
_run
  :: ∀ e
   . Config
  -> Spec (RunnerEffects e) Unit
  -> Producer Event (Aff (RunnerEffects e)) (Array (Group Result))
_run config spec = do
  yield (Event.Start (Spec.countTests spec))
  r <- for (trim $ collect spec) runGroup
  yield (Event.End r)
  pure r

  where
  runGroup (It only name test) = do
    yield Event.Test
    start    <- lift $ liftEff dateNow
    e        <- lift $ attempt case config.timeout of
                                      Just t -> timeout t test
                                      _      -> test
    duration <- lift $ (_ - start) <$> liftEff dateNow
    yield $ either
      (\err ->
        let msg = Error.message err
            stack = Error.stack err
         in Event.Fail name msg stack)
      (const $ Event.Pass name (speedOf config.slow duration) duration)
      e
    yield Event.TestEnd
    pure $ It only name $ either Failure (const Success) e

  runGroup (Pending name) = do
    yield $ Event.Pending name
    pure $ Pending name

  runGroup (Describe only name xs) = do
    yield $ Event.Suite name
    Describe only name <$> (for xs runGroup)
    <* yield Event.SuiteEnd

-- Run a spec, returning the results, without any reporting
runSpec'
  :: ∀ e
   . Config
  -> Spec (RunnerEffects e) Unit
  -> Aff (RunnerEffects e) (Array (Group Result))
runSpec' config spec = P.runEffectRec $ _run config spec //> const (pure unit)

runSpec
  :: ∀ e
   . Spec (RunnerEffects e) Unit
  -> Aff (RunnerEffects e) (Array (Group Result))
runSpec spec = P.runEffectRec $ _run defaultConfig spec //> const (pure unit)

type TestEvents e = Producer Event (Aff e) (Array (Group Result))

type Reporter e = Pipe Event Event (Aff e) (Array (Group Result))

-- Run the spec, report results and exit the program upon completion
run'
  :: ∀ e
   . Config
  -> Array (Reporter (RunnerEffects e))
  -> Spec (RunnerEffects e) Unit
  -> Eff  (RunnerEffects e) Unit
run' config reporters spec = void do
  let events = foldl (>->) (_run config spec) reporters
  runAff (either onError onSuccess) (P.runEffectRec (P.for events onEvent))

  where
    onEvent _ = pure unit

    onError :: Error -> Eff (RunnerEffects e) Unit
    onError err = do withAttrs [31] $ logShow err
                     exit 1

    onSuccess :: Array (Group Result) -> Eff (RunnerEffects e) Unit
    onSuccess results = if successful results
                        then exit 0
                        else exit 1

run
  :: ∀ e
   . Array (Reporter (RunnerEffects e))
  -> Spec (RunnerEffects e) Unit
  -> Eff  (RunnerEffects e) Unit
run = run' defaultConfig
