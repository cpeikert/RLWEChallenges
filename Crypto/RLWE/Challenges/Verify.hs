{-|
Module      : Crypto.RLWE.Challenges.Verify
Description : Verify generated challenges.
Copyright   : (c) Eric Crockett, 2011-2017
                  Chris Peikert, 2011-2017
License     : GPL-3
Maintainer  : ecrockett0@email.com
Stability   : experimental
Portability : POSIX

Verify RLWE/RLWR challenges to ensure that challenges are generated faithfully.
-}

{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE GADTs                 #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE PartialTypeSignatures #-}
{-# LANGUAGE RebindableSyntax      #-}
{-# LANGUAGE NamedFieldPuns        #-}
{-# LANGUAGE RecordWildCards       #-}
{-# LANGUAGE ScopedTypeVariables   #-}

{-# OPTIONS_GHC -fno-warn-partial-type-signatures #-}

module Crypto.RLWE.Challenges.Verify
(verifyMain, verifyInstanceU
,readChallenge, regenChallenge
,beaconAvailable, readBeacon) where

import Crypto.RLWE.Challenges.Beacon
import Crypto.RLWE.Challenges.Common
import Crypto.RLWE.Challenges.Generate

import           Crypto.Lol
import qualified Crypto.Lol.RLWE.RLWR        as R
import qualified Crypto.Lol.RLWE.Continuous as C
import qualified Crypto.Lol.RLWE.Discrete   as D
import           Crypto.Lol.Types.Proto
import           Crypto.Lol.Types.Random

import Crypto.Proto.RLWE.Challenges.Challenge
import Crypto.Proto.RLWE.Challenges.Challenge.Params
import Crypto.Proto.RLWE.Challenges.ContParams
import Crypto.Proto.RLWE.Challenges.DiscParams
import Crypto.Proto.RLWE.Challenges.InstanceContProduct
import Crypto.Proto.RLWE.Challenges.InstanceDiscProduct
import Crypto.Proto.RLWE.Challenges.InstanceRLWRProduct
import Crypto.Proto.RLWE.Challenges.InstanceCont
import Crypto.Proto.RLWE.Challenges.InstanceDisc
import Crypto.Proto.RLWE.Challenges.InstanceRLWR
import Crypto.Proto.RLWE.Challenges.RLWRParams
import Crypto.Proto.RLWE.Challenges.SecretProduct
import Crypto.Proto.RLWE.Challenges.Secret

import Crypto.Proto.Lol.KqProduct
import Crypto.Proto.Lol.RqProduct
import Crypto.Proto.RLWE.SampleCont
import Crypto.Proto.RLWE.SampleDisc
import Crypto.Proto.RLWE.SampleRLWR
import Crypto.Proto.RLWE.SampleContProduct
import Crypto.Proto.RLWE.SampleDiscProduct
import Crypto.Proto.RLWE.SampleRLWRProduct

import Crypto.Random.DRBG

import           Control.Applicative
import           Control.Monad.Except hiding (lift)
import           Control.Monad.Random hiding (lift)
import qualified Data.ByteString.Lazy as BS
import           Data.Int
import           Data.List            (nub, sort)
import           Data.Maybe
import           Data.Reflection      hiding (D)
import           Data.Sequence        (singleton)
import qualified Data.Tagged          as T

import Net.Beacon

import System.Console.ANSI
import System.Directory    (doesFileExist)

-- | Verifies all instances in the challenge tree, given the path to the
-- root of the tree.
verifyMain :: FilePath -> IO ()
verifyMain path = do
  -- get a list of challenges to reveal
  challNames' <- challengeList path
  let challNames = sort challNames'

  beaconAddrs <- sequence <$> mapM (readAndVerifyChallenge path) challNames

  -- verify that all beacon addresses are distinct
  case beaconAddrs of
    (Just addrs) -> do
      _ <- printPassFail "Checking for distinct beacon addresses... " "DISTINCT"
        $ throwErrorIf (length (nub addrs) /= length addrs) "NOT DISTINCT"
      putStrLn "\nAttempting to regenerate challenges from random seeds. This will take awhile..."
      regens <- sequence <$> mapM (regenChallenge path) challNames
      when (isNothing regens) $ printANSI Yellow "NOTE: one or more instances could not be\n \
        \regenerated from the provided PRG seed. This is NON-FATAL,\n \
        \and is likely due to the use of a different compiler/platform\n \
        \than the one used to generate the challenges."
    Nothing -> return ()

-- | Reads a challenge and verifies all instances.
-- Returns the beacon address for the challenge.
readAndVerifyChallenge :: MonadIO m => FilePath -> String -> m (Maybe BeaconAddr)
readAndVerifyChallenge path challName =
  printPassFail ("Verifying " ++ challName) "VERIFIED" $ do
    (ba, insts) <- readChallenge path challName
    mapM_ verifyInstanceU insts
    return ba

-- | Reads a challenge and attempts to regenerate all instances from the
-- provided seed.
-- Returns (Just ()) if regeneration succeeded for all instances.
regenChallenge :: MonadIO m => FilePath -> String -> m (Maybe ())
regenChallenge path challName = do
  printPassWarn ("Regenerating " ++ challName ++ "... ") "VERIFIED" $ do
    (_, insts) <- readChallenge path challName
    regens <- mapM regenInstance insts
    unless (and regens) $ throwError "UNSUCCESSFUL"

-- | Read a challenge from a file, outputting the beacon address and a
-- list of instances to be verified.
readChallenge :: (MonadIO m, MonadError String m)
  => FilePath -> String -> m (BeaconAddr, [InstanceU])
readChallenge path challName = do
  let challFile = challFilePath path challName
  c <- readProtoType challFile
  isAvail <- beaconAvailable path $ beaconEpoch c

  let (msg, readChall) =
        if isAvail
        then (" (expecting one missing secret)... ",
              readSuppChallenge)
        else (" (expecting all secrets)... ",
              readFullChallenge)

  liftIO $ putStr msg
  _ <- parseBeaconAddr c -- verify that the beacon address is valid
  readChall path challName c

-- | Whether we have an XML file for the beacon at the given epoch.
beaconAvailable :: (MonadIO m) => FilePath -> BeaconEpoch -> m Bool
beaconAvailable path = liftIO . doesFileExist . beaconFilePath path

readSuppChallenge, readFullChallenge :: (MonadIO m, MonadError String m)
  => FilePath -> String -> Challenge -> m (BeaconAddr, [InstanceU])

readSuppChallenge path challName Challenge{..} = do
  let numInsts' = fromIntegral numInstances
  beacon <- readBeacon path beaconEpoch
  let deletedID = suppressedSecretID numInstances beacon beaconOffset
  let delSecretFile = secretFilePath path challName deletedID
  delSecretExists <- liftIO $ doesFileExist delSecretFile
  throwErrorIf delSecretExists $
    "Secret " ++ show deletedID ++
    " should not exist, but it does! You may need to run the 'suppress' command."
  throwErrorUnless (isJust params) $ "Challenge " ++ challName ++ " does not contain parameters."
  insts <- mapM (readInstanceU (fromJust params) path challName challengeID) $
    filter (/= deletedID) $ take numInsts' [0..]
  checkParamsEq challName "numInstances" (numInsts'-1) (length insts)
  return (BA beaconEpoch beaconOffset, insts)

readFullChallenge path challName Challenge{..} = do
  let numInsts' = fromIntegral numInstances
  throwErrorUnless (isJust params) $ "Challenge " ++ challName ++ " does not contain parameters."
  insts <- mapM (readInstanceU (fromJust params) path challName challengeID) $ take numInsts' [0..]
  checkParamsEq challName "numInstances" numInsts' (length insts)
  return (BA beaconEpoch beaconOffset, insts)

validateSecret :: (MonadError String m)
  => String -> ChallengeID -> InstanceID -> Int32 -> Int64 -> SecretProduct -> m ()
validateSecret sfile cid iid m q (SecretProduct cid' iid' m' q' seed _) = do
  checkParamsEq sfile "challID" cid cid'
  checkParamsEq sfile "instID" iid iid'
  checkParamsEq sfile "m" m m'
  checkParamsEq sfile "q" q q'
  let minSeedLen = fromIntegral $ T.proxy genSeedLength (Proxy::Proxy InstDRBG)
      seedLen = length $ BS.unpack seed
  throwErrorIf (seedLen < minSeedLen) $ "Seed length is too short! Expected at least " ++
    show minSeedLen ++ " bytes, but only found " ++ show seedLen ++ " bytes."

validateInstance :: (MonadError String m)
  => String -> ChallengeID -> InstanceID -> Params
            -> ChallengeID -> InstanceID -> Params -> m ()
validateInstance instFile cid iid params cid' iid' params' = do
  checkParamsEq instFile "challID" cid cid'
  checkParamsEq instFile "instID" iid iid'
  checkParamsEq instFile "params" params params'

-- | Read an 'InstanceU' from a file. Attempts to read in legacy proto format
-- first, then new proto format.
readInstanceU :: (MonadIO m, MonadError String m)
                 => Params -> FilePath -> String
                 -> ChallengeID -> InstanceID -> m InstanceU
readInstanceU params' path challName cid iid = do
  let secFile = secretFilePath path challName iid
  s <- catchError
         (readProtoType secFile >>= \Secret{..} -> return SecretProduct{s=RqProduct $ singleton s,..})
         (\_->readProtoType secFile)
  let instFile = instFilePath path challName iid
  case params' of
    (Cparams ContParams{..}) -> do
      inst@(InstanceContProduct cid' iid' iparams _) <- catchError
        (readProtoType instFile >>= \InstanceCont{..} ->
          return $ InstanceContProduct{samples=updateLegacySampleCont<$>samples,..})
        (\_->readProtoType instFile)
      validateSecret secFile cid iid m q s
      validateInstance instFile cid iid params' cid' iid' (Cparams iparams)
      return $ IC s inst
    (Dparams DiscParams{..}) -> do
      inst@(InstanceDiscProduct cid' iid' iparams _) <- catchError
        (readProtoType instFile >>= \InstanceDisc{..} ->
          return InstanceDiscProduct{samples=updateLegacySampleDisc<$>samples,..})
        (\_->readProtoType instFile)
      validateSecret secFile cid iid m q s
      validateInstance instFile cid iid params' cid' iid' (Dparams iparams)
      return $ ID s inst
    (Rparams RLWRParams{..}) -> do
      inst@(InstanceRLWRProduct cid' iid' iparams _) <- catchError
        (readProtoType instFile >>= \InstanceRLWR{..} ->
          return InstanceRLWRProduct{samples=updateLegacySampleRLWR<$>samples,..})
        (\_->readProtoType instFile)
      validateSecret secFile cid iid m q s
      validateInstance instFile cid iid params' cid' iid' (Rparams iparams)
      return $ IR s inst

updateLegacySampleCont :: SampleCont -> SampleContProduct
updateLegacySampleCont SampleCont{..} = SampleContProduct{a = RqProduct $ singleton a, b = KqProduct $ singleton b}

updateLegacySampleDisc :: SampleDisc -> SampleDiscProduct
updateLegacySampleDisc SampleDisc{..} = SampleDiscProduct{a = RqProduct $ singleton a, b = RqProduct $ singleton b}

updateLegacySampleRLWR :: SampleRLWR -> SampleRLWRProduct
updateLegacySampleRLWR SampleRLWR{..} = SampleRLWRProduct{a = RqProduct $ singleton a, b = RqProduct $ singleton b}

checkParamsEq :: (MonadError String m, Show a, Eq a)
  => String -> String -> a -> a -> m ()
checkParamsEq data' param expected actual =
  throwErrorUnless (expected == actual) $ "Error while reading " ++
    data' ++ ": " ++ param ++ " mismatch. Expected " ++
    show expected ++ " but got " ++ show actual

maximumCycDec :: (Additive r, Ord r, FoldableCyc (Cyc t m) r) => Cyc t m r -> r
maximumCycDec c = foldrCyc (Just Dec) (\a b -> max a b) zero c

-- | Outputs whether or not we successfully regenerated this instance from the DRBG seed.
regenInstance :: forall mon . MonadError String mon => InstanceU -> mon Bool
-- as always with floating point arithmetic, nothing is perfect (even
-- deterministic generation of instances).
-- the secret and a_i are discrete, so they should match exactly.
-- the b_i shouldn't be too far off.
regenInstance (IC (SecretProduct _ _ _ _ seed s) InstanceContProduct{..}) =
  let ContParams {..} = params
      (Right (g :: CryptoRand InstDRBG)) = newGen $ BS.toStrict seed
  in reifyFactI (fromIntegral m) (\(_::proxy m) ->
      reify (fromIntegral q :: Int64) (\(_::Proxy q) -> (do
        let (expectedS, expectedSamples :: [C.Sample (CycT m) (Zq q) (RRq q)]) =
              flip evalRand g $ instanceCont svar (fromIntegral numSamples)
            csampleEq (a,b) (a',b') =
              (a == a') && maximumCycDec (fmapDec abs $ liftAny $ b-b') < 2 ^- (-20)
        s' :: CycT m (Zq q) <- fromProto s
        samples' :: [C.Sample _ _ (RRq q)] <- fromProto $
          fmap (\(SampleContProduct a b) -> (a,b)) samples
        return $ (expectedS == s') && (and $ zipWith csampleEq expectedSamples samples'))))

regenInstance (ID (SecretProduct _ _ _ _ seed s) InstanceDiscProduct{..}) =
  let DiscParams {..} = params
  in reifyFactI (fromIntegral m) (\(_::proxy m) ->
    reify (fromIntegral q :: Int64) (\(_::Proxy q) -> (do
      g :: CryptoRand InstDRBG <- either (throwError . show) return $ newGen $ BS.toStrict seed
      let (expectedS, expectedSamples :: [D.Sample (CycT m) (Zq q)]) =
            flip evalRand g $ instanceDisc svar (fromIntegral numSamples)
      s' :: CycT m (Zq q) <- fromProto s
      samples' <- fromProto $ fmap (\(SampleDiscProduct a b) -> (a,b)) samples
      return $ (expectedS == s') && (expectedSamples == samples'))))

regenInstance (IR (SecretProduct _ _ _ _ seed s) InstanceRLWRProduct{..}) =
  let RLWRParams {..} = params
  in reifyFactI (fromIntegral m) (\(_::proxy m) ->
    reify (fromIntegral q :: Int64) (\(_::Proxy q) ->
      reify (fromIntegral p :: Int64) (\(_::Proxy p) -> (do
        g :: CryptoRand InstDRBG <- either (throwError . show) return $ newGen $ BS.toStrict seed
        let (expectedS, expectedSamples :: [R.Sample (CycT m) (Zq q) (Zq p)]) =
              flip evalRand g $ instanceRLWR (fromIntegral numSamples)
        s' :: CycT m (Zq q) <- fromProto s
        samples' :: [R.Sample _ _ (Zq p)] <- fromProto $
          fmap (\(SampleRLWRProduct a b) -> (a,b)) samples
        return $ (expectedS == s') && (expectedSamples == samples')))))

-- | Verify an 'InstanceU'.
verifyInstanceU :: forall mon . MonadError String mon => InstanceU -> mon ()

verifyInstanceU (IC (SecretProduct _ _ _ _ _ s) InstanceContProduct{..}) =
  let ContParams {..} = params
  in reifyFactI (fromIntegral m) (\(_::proxy m) ->
    reify (fromIntegral q :: Int64) (\(_::Proxy q) -> (do
      s' :: CycT m (Zq q) <- fromProto s
      samples' :: [C.Sample _ _ (RRq q)] <- fromProto $
        fmap (\(SampleContProduct a b) -> (a,b)) samples
      throwErrorUnless (validInstanceCont bound s' samples')
        "A continuous RLWE sample exceeded the error bound.")))

verifyInstanceU (ID (SecretProduct _ _ _ _ _ s) InstanceDiscProduct{..}) =
  let DiscParams {..} = params
  in reifyFactI (fromIntegral m) (\(_::proxy m) ->
    reify (fromIntegral q :: Int64) (\(_::Proxy q) -> (do
      s' :: CycT m (Zq q) <- fromProto s
      samples' <- fromProto $ fmap (\(SampleDiscProduct a b) -> (a,b)) samples
      throwErrorUnless (validInstanceDisc bound s' samples')
        "A discrete RLWE sample exceeded the error bound.")))

verifyInstanceU (IR (SecretProduct _ _ _ _ _ s) InstanceRLWRProduct{..}) =
  let RLWRParams {..} = params
  in reifyFactI (fromIntegral m) (\(_::proxy m) ->
    reify (fromIntegral q :: Int64) (\(_::Proxy q) ->
      reify (fromIntegral p :: Int64) (\(_::Proxy p) -> (do
        s' :: CycT m (Zq q) <- fromProto s
        samples' :: [R.Sample _ _ (Zq p)] <- fromProto $
          fmap (\(SampleRLWRProduct a b) -> (a,b)) samples
        throwErrorUnless (validInstanceRLWR s' samples')
          "An RLWR sample was invalid."))))

-- | Read an XML file for the beacon corresponding to the provided time.
readBeacon :: (MonadIO m, MonadError String m)
              => FilePath -> BeaconEpoch -> m Record
readBeacon path time = do
  let file = beaconFilePath path time
  checkFileExists file
  rec' <- liftIO $ fromXML <$> BS.readFile file
  maybeThrowError rec' $ "Could not parse " ++ file

-- | Test if the 'gSqNorm' of the error for each RLWE sample in the
-- instance (given the secret) is less than the given bound.
validInstanceCont :: (Fact m, Reifies q Int64)
  => LiftOf (RRq q) -> CycT m (Zq q) -> [C.Sample (CycT m) (Zq q) (RRq q)] -> Bool
validInstanceCont bound s = all ((bound > ) . C.errorGSqNorm s)

-- | Test if the 'gSqNorm' of the error for each RLWE sample in the
-- instance (given the secret) is less than the given bound.
validInstanceDisc :: (Fact m, Reifies q Int64)
  => LiftOf (Zq q) -> CycT m (Zq q) -> [D.Sample (CycT m) (Zq q)] -> Bool
validInstanceDisc bound s = all ((bound > ) . D.errorGSqNorm s)

-- | Test if the given RLWR instance is valid for the given secret.
validInstanceRLWR :: (Fact m, Reifies q Int64, Reifies p Int64)
  => CycT m (Zq q) -> [R.Sample (CycT m) (Zq q) (Zq p)] -> Bool
validInstanceRLWR s = let s' = adviseCRT s in all (validSampleRLWR s')

-- | Test if the given RLWR sample is valid for the given secret.
validSampleRLWR :: (Fact m, Reifies q Int64, Reifies p Int64)
  => CycT m (Zq q) -> R.Sample (CycT m) (Zq q) (Zq p) -> Bool
validSampleRLWR s (a,b) = b == R.roundedProd s a
