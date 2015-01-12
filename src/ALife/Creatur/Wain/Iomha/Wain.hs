------------------------------------------------------------------------
-- |
-- Module      :  ALife.Creatur.Wain.Iomha.Wain
-- Copyright   :  (c) Amy de Buitléir 2012-2014
-- License     :  BSD-style
-- Maintainer  :  amy@nualeargais.ie
-- Stability   :  experimental
-- Portability :  portable
--
-- A data mining agent, designed for the Créatúr framework.
--
------------------------------------------------------------------------
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE Rank2Types #-}
module ALife.Creatur.Wain.Iomha.Wain
  (
    ImageWain,
    run,
    randomImageWain,
    finishRound,
    energy,
    passion,
    schemaQuality,
    printStats
  ) where

import ALife.Creatur (agentId)
import ALife.Creatur.Database (size)
import ALife.Creatur.Task (checkPopSize)
import ALife.Creatur.Util (stateMap)
import ALife.Creatur.Wain (Wain(..), adjustEnergy, adjustPassion,
  chooseAction, buildWainAndGenerateGenome, incAge, weanMatureChildren,
  tryMating, energy, passion, hasLitter, reflect)
import ALife.Creatur.Wain.Brain (classifier, buildBrain)
import ALife.Creatur.Wain.Checkpoint (enforceAll)
import qualified ALife.Creatur.Wain.ClassificationMetrics as SQ
import ALife.Creatur.Wain.GeneticSOM (RandomExponentialParams(..),
  randomExponential, buildGeneticSOM, numModels, counterMap)
import ALife.Creatur.Wain.Pretty (pretty)
import ALife.Creatur.Wain.Raw (raw)
import ALife.Creatur.Wain.Response (Response, randomResponse, action)
import ALife.Creatur.Wain.Util (unitInterval)
import qualified ALife.Creatur.Wain.Statistics as Stats
import ALife.Creatur.Wain.Iomha.Action (Action(..))
import qualified ALife.Creatur.Wain.Iomha.FMRI as F
import ALife.Creatur.Wain.Iomha.Image (Image, stripedImage, randomImage)
import ALife.Creatur.Wain.Iomha.ImageDB (ImageDB, anyImage)
import qualified ALife.Creatur.Wain.Iomha.Universe as U
import ALife.Creatur.Wain.PersistentStatistics (updateStats, readStats,
  clearStats)
import ALife.Creatur.Wain.Statistics (summarise)
import Control.Applicative ((<$>))
import Control.Conditional (whenM)
import Control.Lens hiding (Action, universe)
import Control.Monad (replicateM, when, unless)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Random (Rand, RandomGen, getRandomR)
import Control.Monad.State.Lazy (StateT, execStateT, evalStateT, get,
  gets)
import Data.List (intercalate)
import Data.Map.Strict (elems)
import Data.Word (Word16)
import System.Directory (createDirectoryIfMissing)
import System.FilePath (dropFileName)
import System.Random (randomIO, randomRIO)
import Text.Printf (printf)

data Object = IObject Image String | AObject ImageWain

isImage :: Object -> Bool
isImage (IObject _ _) = True
isImage (AObject _) = False

objectId :: Object -> String
objectId (IObject _ s) = "Image " ++ s
objectId (AObject a) = agentId a

objectAppearance :: Object -> Image
objectAppearance (IObject img _) = img
objectAppearance (AObject a) = appearance a

addIfAgent :: Object -> [ImageWain] -> [ImageWain]
addIfAgent (IObject _ _) xs = xs
addIfAgent (AObject a) xs = a:xs

randomlyInsertImages :: ImageDB -> [Object] -> IO [Object]
randomlyInsertImages db xs = do
  insert <- randomIO
  if insert
    then do
      (img, imageId) <- evalStateT anyImage db
      n <- randomRIO (0, 1)
      let (fore, aft) = splitAt n xs
      randomlyInsertImages db $ fore ++ IObject img imageId : aft
    else
      return xs

type ImageWain = Wain Image Action

-- TODO: Redo with lenses

randomImageWain
  :: RandomGen r
    => String -> U.Universe ImageWain -> Word16 -> Word16 -> Rand r ImageWain
randomImageWain wainName u classifierSize deciderSize = do
  let w = U.uImageWidth u
  let h = U.uImageHeight u
  imgs <- replicateM (fromIntegral classifierSize) (randomImage w h)
  -- let imgs = replicate classifierSize $ blankImage w h
  let fcp = RandomExponentialParams
               { r0Range = U.uClassifierR0Range u,
                 dRange = U.uClassifierDRange u }
  fc <- randomExponential fcp
  let c = buildGeneticSOM fc imgs
  let fdp = RandomExponentialParams
              { r0Range = U.uDeciderR0Range u,
                dRange = U.uDeciderDRange u }
  fd <- randomExponential fdp
  xs <- replicateM (fromIntegral deciderSize) $
         randomResponse (numModels c) 
  let b = buildBrain c (buildGeneticSOM fd xs)
  d <- getRandomR (U.uDevotionRange u)
  m <- getRandomR (U.uMaturityRange u)
  p <- getRandomR unitInterval
  let app = stripedImage w h
  return $ buildWainAndGenerateGenome wainName app b d m p

data Summary = Summary
  {
    _rPopSize :: Int,
    _rDirectObjectNovelty :: Double,
    _rDirectObjectAdjustedNovelty :: Int,
    _rIndirectObjectNovelty :: Double,
    _rIndirectObjectAdjustedNovelty :: Int,
    _rOtherNovelty :: Double,
    _rOtherAdjustedNovelty :: Int,
    _rSchemaQuality :: Int,
    _rMetabolismDeltaE :: Double,
    _rChildRearingDeltaE :: Double,
    _rCoopDeltaE :: Double,
    _rAgreementDeltaE :: Double,
    _rFlirtingDeltaE :: Double,
    _rMatingDeltaE :: Double,
    _rUndercrowdingDeltaE :: Double,
    _rOvercrowdingDeltaE :: Double,
    _rOtherMatingDeltaE :: Double,
    _rOtherAgreementDeltaE :: Double,
    _rNetSubjectDeltaE :: Double,
    _rNetDeltaE :: Double,
    _rErr :: Double,
    _rBirthCount :: Int,
    _rWeanCount :: Int,
    _rCooperateCount :: Int,
    _rAgreeCount :: Int,
    _rFlirtCount :: Int,
    _rMateCount :: Int,
    _rIgnoreCount :: Int,
    _rDeathCount :: Int
  }
makeLenses ''Summary

initSummary :: Int -> Summary
initSummary p = Summary
  {
    _rPopSize = p,
    _rDirectObjectNovelty = 0,
    _rDirectObjectAdjustedNovelty = 0,
    _rIndirectObjectNovelty = 0,
    _rIndirectObjectAdjustedNovelty = 0,
    _rOtherNovelty = 0,
    _rOtherAdjustedNovelty = 0,
    _rSchemaQuality = 0,
    _rMetabolismDeltaE = 0,
    _rChildRearingDeltaE = 0,
    _rCoopDeltaE = 0,
    _rAgreementDeltaE = 0,
    _rFlirtingDeltaE = 0,
    _rMatingDeltaE = 0,
    _rUndercrowdingDeltaE = 0,
    _rOvercrowdingDeltaE = 0,
    _rOtherMatingDeltaE = 0,
    _rOtherAgreementDeltaE = 0,
    _rNetSubjectDeltaE = 0,
    _rNetDeltaE = 0,
    _rErr = 0,
    _rBirthCount = 0,
    _rWeanCount = 0,
    _rCooperateCount = 0,
    _rAgreeCount = 0,
    _rFlirtCount = 0,
    _rMateCount = 0,
    _rIgnoreCount = 0,
    _rDeathCount = 0
  }

summaryStats :: Summary -> [Stats.Statistic]
summaryStats r =
  [
    Stats.uiStat "pop. size" (view rPopSize r),
    Stats.uiStat "DO novelty" (view rDirectObjectNovelty r),
    Stats.iStat "DO novelty (adj.)"
      (view rDirectObjectAdjustedNovelty r),
    Stats.uiStat "IO novelty" (view rIndirectObjectNovelty r),
    Stats.iStat "IO novelty (adj.)"
      (view rIndirectObjectAdjustedNovelty r),
    Stats.uiStat "novelty to other" (view rOtherNovelty r),
    Stats.iStat "novelty to other (adj.)"
      (view rOtherAdjustedNovelty r),
    Stats.iStat "SQ" (view rSchemaQuality r),
    Stats.uiStat "metabolism Δe" (view rMetabolismDeltaE r),
    Stats.uiStat "child rearing Δe" (view rChildRearingDeltaE r),
    Stats.uiStat "cooperation Δe" (view rCoopDeltaE r),
    Stats.uiStat "agreement Δe" (view rAgreementDeltaE r),
    Stats.uiStat "flirting Δe" (view rFlirtingDeltaE r),
    Stats.uiStat "mating Δe" (view rMatingDeltaE r),
    Stats.uiStat "undercrowding Δe" (view rUndercrowdingDeltaE r),
    Stats.uiStat "overcrowding Δe" (view rOvercrowdingDeltaE r),
    Stats.uiStat "subject net Δe" (view rNetSubjectDeltaE r),
    Stats.uiStat "other mating Δe" (view rOtherMatingDeltaE r),
    Stats.uiStat "other agreement Δe" (view rOtherAgreementDeltaE r),
    Stats.uiStat "net Δe" (view rNetDeltaE r),
    Stats.uiStat "err" (view rErr r),
    Stats.iStat "bore" (view rBirthCount r),
    Stats.iStat "weaned" (view rWeanCount r),
    Stats.iStat "co-operated" (view rCooperateCount r),
    Stats.iStat "agreed" (view rAgreeCount r),
    Stats.iStat "flirted" (view rFlirtCount r),
    Stats.iStat "mated" (view rMateCount r),
    Stats.iStat "ignored" (view rIgnoreCount r),
    Stats.iStat "died" (view rDeathCount r)
  ]

data Experiment = Experiment
  {
    _subject :: ImageWain,
    _directObject :: Object,
    _indirectObject :: Object,
    _weanlings :: [ImageWain],
    _universe :: U.Universe ImageWain,
    _summary :: Summary
  }
makeLenses ''Experiment

run :: U.Universe ImageWain -> [ImageWain]
      -> StateT (U.Universe ImageWain) IO [ImageWain]
run u (me:xs) = do
  when (null xs) $ U.writeToLog "WARNING: Last wain standing!"
  (x, y) <- chooseObjects xs (U.uImageDB u)
  p <- U.popSize
  let e = Experiment { _subject = me,
                       _directObject = x,
                       _indirectObject = y,
                       _weanlings = [],
                       _universe = u,
                       _summary = initSummary p}
  e' <- liftIO $ execStateT run' e
  let modifiedAgents = addIfAgent (view directObject e')
        . addIfAgent (view indirectObject e')
            $ view subject e' : view weanlings e'
  U.writeToLog $
    "Modified agents: " ++ show (map agentId modifiedAgents)
  return modifiedAgents
run _ _ = error "no more wains"

run' :: StateT Experiment IO ()
run' = do
  a <- use subject
  withUniverse . U.writeToLog $ "---------- " ++ agentId a
    ++ "'s turn ----------"
  withUniverse . U.writeToLog $ "At beginning of turn, " ++ agentId a
    ++ "'s summary: " ++ pretty (Stats.stats a)
  (nov, r) <- chooseSubjectAction
  runAction (action r) nov
  letSubjectReflect r
  adjustSubjectPassion
  when (hasLitter a) applyChildrearingCost
  weanChildren
  applyMetabolismCost
  controlPopSize
  incSubjectAge
  a' <- use subject
  withUniverse . U.writeToLog $ "End of " ++ agentId a ++ "'s turn"
  -- assign (summary.rNetDeltaE) (energy a' - energy a)
  assign (summary.rSchemaQuality) (schemaQuality a')
  when (energy a' < 0) $ assign (summary.rDeathCount) 1
  sf <- U.uStatsFile <$> use universe
  agentStats <- ((Stats.stats a' ++) . summaryStats . fillInSummary)
                 <$> use summary
  withUniverse . U.writeToLog $ "At end of turn, " ++ agentId a
    ++ "'s summary: " ++ pretty agentStats
  withUniverse $ updateStats agentStats sf
  rsf <- U.uRawStatsFile <$> use universe
  withUniverse $ writeRawStats (agentId a) rsf agentStats
  whenM (U.uGenFmris <$> use universe) writeFmri

writeFmri :: StateT Experiment IO ()
writeFmri = do
  w <- use subject
  t <- withUniverse U.currentTime
  d <- U.uFmriDir <$> use universe
  let f = d ++ "/" ++ name w ++ '_' : show t ++ ".png"
  liftIO . F.writeFmri w $ f

fillInSummary :: Summary -> Summary
fillInSummary s = s
  {
    _rNetSubjectDeltaE = myDeltaE,
    _rNetDeltaE = myDeltaE + otherDeltaE
  }
  where myDeltaE = _rMetabolismDeltaE s
          + _rChildRearingDeltaE s
          + _rCoopDeltaE s
          + _rAgreementDeltaE s
          + _rFlirtingDeltaE s
          + _rMatingDeltaE s
          + _rUndercrowdingDeltaE s
          + _rOvercrowdingDeltaE s
        otherDeltaE = _rOtherMatingDeltaE s
          + _rOtherAgreementDeltaE s

applyMetabolismCost :: StateT Experiment IO ()
applyMetabolismCost = do
  a <- use subject
  bms <- U.uBaseMetabolismDeltaE <$> use universe
  cps <- U.uEnergyCostPerByte <$> use universe
  let deltaE = metabolismCost bms cps a
  adjustSubjectEnergy deltaE rMetabolismDeltaE "metabolism"

applyChildrearingCost :: StateT Experiment IO ()
applyChildrearingCost = do
  a <- use subject
  ccf <- U.uChildCostFactor <$> use universe
  bms <- U.uBaseMetabolismDeltaE <$> use universe
  cps <- U.uEnergyCostPerByte <$> use universe
  let deltaE = childRearingCost bms cps ccf a
  adjustSubjectEnergy deltaE rChildRearingDeltaE "child rearing"

metabolismCost :: Double -> Double -> ImageWain -> Double
metabolismCost b f a = b + f*s
  where s = fromIntegral (size a)

childRearingCost :: Double -> Double -> Double -> ImageWain -> Double
childRearingCost b f x a = x * (sum . map g $ litter a)
    where g = metabolismCost b f

schemaQuality :: ImageWain -> Int
schemaQuality
  = SQ.discrimination . elems . counterMap . classifier . brain

chooseSubjectAction
  :: StateT Experiment IO (Double, Response Action)
chooseSubjectAction = do
  a <- use subject
  dObj <- use directObject
  iObj <- use indirectObject
  (dObjNovelty, dObjNoveltyAdj, iObjNovelty, iObjNoveltyAdj, r, a')
    <- withUniverse $ chooseAction3 a dObj iObj
  assign (summary.rDirectObjectNovelty) dObjNovelty
  assign (summary.rDirectObjectAdjustedNovelty) dObjNoveltyAdj
  assign (summary.rIndirectObjectNovelty) iObjNovelty
  assign (summary.rIndirectObjectAdjustedNovelty) iObjNoveltyAdj
  assign subject a'
  return (dObjNovelty, r)

choosePartnerAction
  :: StateT Experiment IO (Double, Response Action)
choosePartnerAction = do
  a <- use subject
  dObj <- use directObject
  (AObject b) <- use indirectObject
  (dObjNovelty, dObjNoveltyAdj, _, _, r, b')
    <- withUniverse $ chooseAction3 b dObj (AObject a)
  assign (summary.rOtherNovelty) dObjNovelty
  assign (summary.rOtherAdjustedNovelty) dObjNoveltyAdj
  assign indirectObject (AObject b')
  return (dObjNovelty, r)

chooseAction3
  :: ImageWain -> Object -> Object
    -> StateT (U.Universe ImageWain) IO
        (Double, Int, Double, Int, Response Action, ImageWain)
chooseAction3 w dObj iObj = do
  U.writeToLog $ agentId w ++ " sees " ++ objectId dObj
    ++ " and " ++ objectId iObj
  (_, _, dObjNovelty, dObjNoveltyAdj,
    _, _, iObjNovelty, iObjNoveltyAdj, r, w')
      <- chooseAction (objectAppearance dObj) (objectAppearance iObj) w
  U.writeToLog $ "To " ++ agentId w ++ ", "
    ++ objectId dObj ++ " has adjusted novelty " ++ show dObjNoveltyAdj
  U.writeToLog $ "To " ++ agentId w ++ ", "
    ++ objectId iObj ++ " has adjusted novelty " ++ show iObjNoveltyAdj
  U.writeToLog $ agentId w ++ " sees " ++ objectId dObj
    ++ " and chooses to "
    ++ describe (action r)
  return (dObjNovelty, dObjNoveltyAdj, iObjNovelty, iObjNoveltyAdj, r, w')
  

incSubjectAge :: StateT Experiment IO ()
incSubjectAge = do
  a <- use subject
  a' <- withUniverse (incAge a)
  assign subject a'

describe :: Action -> String
describe Flirt = "flirt"
describe Ignore = "do nothing"
describe _ = "co-operate"

chooseObjects :: [ImageWain] -> ImageDB -> StateT u IO (Object, Object)
chooseObjects xs db = do
  -- withUniverse . U.writeToLog $ "Direct object = " ++ objectId x
  -- withUniverse . U.writeToLog $ "Indirect object = " ++ objectId y
  (x:y:_) <- liftIO . randomlyInsertImages db . map AObject $ xs
  return (x, y)

runAction :: Action -> Double -> StateT Experiment IO ()

--
-- Flirt
--
runAction Flirt _ = do
  applyFlirtationEffects
  a <- use subject
  dObj <- use directObject
  withUniverse . U.writeToLog $
    agentId a ++ " flirts with " ++ objectId dObj
  unless (isImage dObj) flirt

--
-- Ignore
--
runAction Ignore _ = do
  a <- use subject
  dObj <- use directObject
  withUniverse . U.writeToLog $
    agentId a ++ " ignores " ++ objectId dObj
  (summary.rIgnoreCount) += 1

--
-- Co-operate
--
runAction aAction noveltyToMe = do
  applyCooperationEffects
  a <- use subject
  dObj <- use directObject
  iObj <- use indirectObject
  case iObj of
    AObject b   -> do
      withUniverse . U.writeToLog $ agentId a ++ " tells " ++ agentId b
        ++ " that image " ++ objectId dObj ++ " has label "
        ++ show aAction
      (noveltyToOther, r) <- choosePartnerAction
      let bAction = action r
      if aAction == bAction
        then do
          withUniverse . U.writeToLog $ agentId b ++ " agrees with "
            ++  agentId a ++ " that " ++ objectId dObj
            ++ " has label " ++ show aAction
          applyAgreementEffects noveltyToMe noveltyToOther
        else
          withUniverse . U.writeToLog $ agentId b ++ " disagrees with "
            ++ agentId a ++ ", says that " ++ objectId dObj
            ++ " has label " ++ show bAction
    IObject _ _ -> return ()
  
--
-- Utility functions
--

applyCooperationEffects :: StateT Experiment IO ()
applyCooperationEffects = do
  deltaE <- U.uCooperationDeltaE <$> use universe
  adjustSubjectEnergy deltaE rCoopDeltaE "cooperation"
  (summary.rCooperateCount) += 1

applyAgreementEffects :: Double -> Double -> StateT Experiment IO ()
applyAgreementEffects noveltyToMe noveltyToOther = do
  x <- U.uNoveltyBasedAgreementDeltaE <$> use universe
  x0 <- U.uMinAgreementDeltaE <$> use universe
  let reason = "agreement"
  let ra = x0 + x * noveltyToMe
  adjustSubjectEnergy ra rAgreementDeltaE reason
  let rb = x0 + x * noveltyToOther
  adjustObjectEnergy indirectObject rb rOtherAgreementDeltaE reason
  (summary.rAgreeCount) += 1

controlPopSize :: StateT Experiment IO ()
controlPopSize = do
  p <- withUniverse U.popSize
  (c, d) <- U.uPopulationNormalRange <$> use universe
  adjustIfNotIn p (c, d)
  (a, b) <- U.uPopulationAllowedRange <$> use universe
  withUniverse $ checkPopSize (a, b)

adjustIfNotIn :: Int -> (Int, Int) -> StateT Experiment IO ()
adjustIfNotIn p (a, b)
  | p <= a     = do
      w <- use subject
      when (energy w < 0) $ do
        x <- U.uUndercrowdingDeltaE <$> use universe
        adjustSubjectEnergy x rUndercrowdingDeltaE "undercrowding"
  | p >= b     = do
      x <- U.uOvercrowdingDeltaE <$> use universe
      adjustSubjectEnergy x rOvercrowdingDeltaE "overcrowding"
  | otherwise = return ()

flirt :: StateT Experiment IO ()
flirt = do
  a <- use subject
  (AObject b) <- use directObject
  (a':b':_, mated) <- withUniverse (tryMating a b)
  when mated $ do
    assign subject a'
    assign directObject (AObject b')
    recordBirths
    applyMatingEffects a a' b b'

recordBirths :: StateT Experiment IO ()
recordBirths = do
  a <- use subject
  (summary.rBirthCount) += length (litter a)

applyFlirtationEffects :: StateT Experiment IO ()
applyFlirtationEffects = do
  deltaE <- U.uFlirtingDeltaE <$> use universe
  adjustSubjectEnergy deltaE rFlirtingDeltaE "flirting"
  (summary.rFlirtCount) += 1

applyMatingEffects
  :: ImageWain -> ImageWain -> ImageWain -> ImageWain -> StateT Experiment IO ()
applyMatingEffects aBefore aAfter bBefore bAfter = do
  let e1 = energy aAfter - energy aBefore
  (summary . rMatingDeltaE) += e1
  let e2 = energy bAfter - energy bBefore
  (summary . rOtherMatingDeltaE) += e2
  (summary . rMateCount) += 1
  reportAdjustment aBefore "mating" (energy aBefore) e1 (energy aAfter)
  reportAdjustment bBefore "mating" (energy bBefore) e2 (energy bAfter)

weanChildren :: StateT Experiment IO ()
weanChildren = do
  (a:as) <- use subject >>= withUniverse . weanMatureChildren
  assign subject a
  assign weanlings as
  (summary.rWeanCount) += length as

withUniverse
  :: Monad m => StateT (U.Universe ImageWain) m a -> StateT Experiment m a
withUniverse f = do
  e <- get
  stateMap (\u -> set universe u e) (view universe) f

finishRound :: FilePath -> StateT (U.Universe ImageWain) IO ()
finishRound f = do
  xss <- readStats f
  let yss = summarise xss
  printStats yss
  let zs = concat yss
  cs <- gets U.uCheckpoints
  enforceAll zs cs
  clearStats f

printStats :: [[Stats.Statistic]] -> StateT (U.Universe ImageWain) IO ()
printStats = mapM_ f
  where f xs = U.writeToLog $
                 "Summary - " ++ intercalate "," (map pretty xs)

adjustSubjectEnergy
  :: Double -> Simple Lens Summary Double -> String
    -> StateT Experiment IO ()
adjustSubjectEnergy deltaE selector reason = do
  x <- use subject
  let before = energy x
  deltaE' <- adjustedDeltaE deltaE (1 - before)
  -- assign (summary . selector) deltaE'
  (summary . selector) += deltaE'
  assign subject (adjustEnergy deltaE' x)
  after <- energy <$> use subject
  reportAdjustment x reason before deltaE' after

adjustObjectEnergy
  :: Simple Lens Experiment Object -> Double
    -> Simple Lens Summary Double -> String -> StateT Experiment IO ()
adjustObjectEnergy objectSelector deltaE statSelector reason = do
  x <- use objectSelector
  case x of
    AObject a -> do
      let before = energy a
      deltaE' <- adjustedDeltaE deltaE (1 - before)
      (summary . statSelector) += deltaE'
      let a' = adjustEnergy deltaE' a
      let after = energy a'
      assign objectSelector (AObject a')
      reportAdjustment a reason before deltaE' after
    IObject _ _ -> return ()

reportAdjustment
  :: ImageWain -> String -> Double -> Double -> Double -> StateT Experiment IO ()
reportAdjustment x reason before deltaE after =
  withUniverse . U.writeToLog $ "Adjusted energy of " ++ agentId x
    ++ " because of " ++ reason
    ++ ". " ++ printf "%.3f" before ++ " + " ++ printf "%.3f" deltaE
    ++ " = " ++ printf "%.3f" after

adjustedDeltaE
  :: Double -> Double -> StateT Experiment IO Double
adjustedDeltaE deltaE headroom =
  if deltaE <= 0
    then return deltaE
    else do
      let deltaE2 = min deltaE headroom
      when (deltaE2 < deltaE) $
        withUniverse . U.writeToLog $ "Wain at or near max energy, can only give "
          ++ show deltaE2
      return deltaE2

adjustSubjectPassion
  :: StateT Experiment IO ()
adjustSubjectPassion = do
  x <- use subject
  assign subject (adjustPassion x)

letSubjectReflect
  :: Response Action -> StateT Experiment IO ()
letSubjectReflect r = do
  x <- use subject
  p1 <- objectAppearance <$> use directObject
  p2 <- objectAppearance <$> use indirectObject
  (x', err) <- withUniverse (reflect p1 p2 r x)
  assign subject x'
  assign (summary . rErr) err

writeRawStats
  :: String -> FilePath -> [Stats.Statistic]
    -> StateT (U.Universe ImageWain) IO ()
writeRawStats n f xs = do
  liftIO $ createDirectoryIfMissing True (dropFileName f)
  t <- U.currentTime
  liftIO . appendFile f $
    "time=" ++ show t ++ ",agent=" ++ n ++ ',':raw xs ++ "\n"
