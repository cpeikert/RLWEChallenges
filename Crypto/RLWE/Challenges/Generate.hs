{-|
Module      : Crypto.RLWE.Challenges.Generate
Description : Generates challenges in non-legacy proto format.
Copyright   : (c) Eric Crockett, 2011-2017
                  Chris Peikert, 2011-2017
License     : GPL-3
Maintainer  : ecrockett0@email.com
Stability   : experimental
Portability : POSIX

Generates challenges in non-legacy proto format.
-}

{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE KindSignatures        #-}
{-# LANGUAGE MonoLocalBinds        #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE RebindableSyntax      #-}
{-# LANGUAGE RecordWildCards       #-}
{-# LANGUAGE ScopedTypeVariables   #-}

module Crypto.RLWE.Challenges.Generate
(generateMain,genChallengeU
,writeChallengeU
,instanceCont, instanceDisc, instanceRLWR) where

import Crypto.RLWE.Challenges.Beacon
import Crypto.RLWE.Challenges.Common
import Crypto.RLWE.Challenges.Params as P

import Crypto.Lol                 hiding (lift)
import Crypto.Lol.RLWE.Continuous as C
import Crypto.Lol.RLWE.Discrete   as D
import Crypto.Lol.RLWE.RLWR       as R
import Crypto.Lol.Types.Proto
import Crypto.Lol.Types.Random

import Crypto.Proto.RLWE.Challenges.Challenge
import Crypto.Proto.RLWE.Challenges.Challenge.Params
import Crypto.Proto.RLWE.Challenges.ContParams
import Crypto.Proto.RLWE.Challenges.DiscParams
import Crypto.Proto.RLWE.Challenges.InstanceContProduct
import Crypto.Proto.RLWE.Challenges.InstanceDiscProduct
import Crypto.Proto.RLWE.Challenges.InstanceRLWRProduct
import Crypto.Proto.RLWE.Challenges.RLWRParams
import Crypto.Proto.RLWE.Challenges.SecretProduct           as S
import Crypto.Proto.RLWE.SampleContProduct
import Crypto.Proto.RLWE.SampleDiscProduct
import Crypto.Proto.RLWE.SampleRLWRProduct

import Crypto.Random.DRBG

import Control.Applicative
import Control.Monad
import Control.Monad.Except
import Control.Monad.Random

import qualified Data.ByteString.Lazy as BS
import Data.Reflection hiding (D)
import qualified Data.Tagged as T

import System.Directory (createDirectoryIfMissing)

import Text.Printf

-- | Generate and serialize challenges given the path to the root of the tree
-- and an initial beacon address.
generateMain :: FilePath -> BeaconAddr -> [ChallengeParams] -> IO ()
generateMain path beaconStart cps = do
  let len = length cps
      beaconAddrs = take len $ iterate nextBeaconAddr beaconStart
  evalCryptoRandIO (zipWithM_ (genAndWriteChallenge path) cps beaconAddrs
    :: RandT (CryptoRand HashDRBG) IO ())

genAndWriteChallenge :: (MonadRandom m, MonadIO m)
  => FilePath -> ChallengeParams -> BeaconAddr -> m ()
genAndWriteChallenge path cp ba@(BA _ _) = do
  let name = challengeName cp
  liftIO $ putStrLn $ "Generating challenge " ++ name

  -- CJP: not printing warning because it's annoying to implement
  -- correctly: dont want to trust local time, don't want to rely on
  -- network when generating

  -- isAvail <- isBeaconAvailable t
  -- when isAvail $ printANSI Red "Beacon is already available!"

  chall <- genChallengeU cp ba
  liftIO $ writeChallengeU path name chall

-- | The name for each challenge directory.
challengeName :: ChallengeParams -> FilePath
challengeName params =
  "chall-id" ++ printf "%04d" (challID params) ++
    case params of
      C{..} -> "-rlwec-m" ++ show m ++ "-q" ++ show q ++
        "-l" ++ show (P.numSamples params) ++
        if null annotation then "" else "-" ++ annotation
      D{..} -> "-rlwed-m" ++ show m ++ "-q" ++ show q ++
        "-l" ++ show (P.numSamples params) ++
        if null annotation then "" else "-" ++ annotation
      R{..} -> "-rlwr-m" ++ show m ++ "-q" ++ show q ++ "-p" ++ show p ++
        "-l" ++ show (P.numSamples params) ++
        if null annotation then "" else "-" ++ annotation

-- | Generate a challenge with the given parameters.
genChallengeU :: MonadRandom m => ChallengeParams -> BeaconAddr -> m ChallengeU
genChallengeU cp (BA beaconEpoch beaconOffset) = do
  let challengeID = challID cp
      params' = toProtoParams cp
      numInstances = P.numInstances cp
      numInsts = fromIntegral numInstances
      chall = Challenge{params=Just params',..}
      instIDs = take numInsts [0..]
      seedLen = T.proxy genSeedLength (Proxy::Proxy InstDRBG)
  seeds <- replicateM numInsts (BS.pack <$> replicateM seedLen getRandom)
  let insts = zipWith (genInstanceU params' challengeID) instIDs seeds
  return $ CU chall insts

-- | Generate an instance for the given parameters.
genInstanceU :: Params -> ChallengeID -> InstanceID -> BS.ByteString -> InstanceU

genInstanceU (Cparams params@ContParams{..}) challengeID instanceID seed =
  let (Right (g :: CryptoRand InstDRBG)) = newGen $ BS.toStrict seed
  in flip evalRand g $ reify q (\(_::Proxy q) ->
    reifyFactI (fromIntegral m) (\(_::proxy m) -> (do
      (s', samples' :: [C.Sample (CycT m) (Zq q) (RRq q)]) <- instanceCont svar $ fromIntegral numSamples
      let s'' = SecretProduct{s = toProto s', ..}
          samples = uncurry SampleContProduct <$> toProto samples'
      return $ IC s'' InstanceContProduct{..})))

genInstanceU (Dparams params@DiscParams{..}) challengeID instanceID seed =
  let (Right (g :: CryptoRand InstDRBG)) = newGen $ BS.toStrict seed
  in flip evalRand g $ reify q (\(_::Proxy q) ->
    reifyFactI (fromIntegral m) (\(_::proxy m) -> (do
      (s', samples' :: [D.Sample (CycT m) (Zq q)]) <- instanceDisc svar $ fromIntegral numSamples
      let s'' = SecretProduct{s = toProto s', ..}
          samples = uncurry SampleDiscProduct <$> toProto samples'
      return $ ID s'' InstanceDiscProduct{..})))

genInstanceU (Rparams params@RLWRParams{..}) challengeID instanceID seed =
  let (Right (g :: CryptoRand InstDRBG)) = newGen $ BS.toStrict seed
  in flip evalRand g $ reify q (\(_::Proxy q) -> reify p (\(_::Proxy p) ->
    reifyFactI (fromIntegral m) (\(_::proxy m) -> (do
      (s', samples' :: [R.Sample (CycT m) (Zq q) (Zq p)]) <- instanceRLWR $ fromIntegral numSamples
      let s'' = SecretProduct{s = toProto s', ..}
          samples = uncurry SampleRLWRProduct <$> toProto samples'
      return $ IR s'' InstanceRLWRProduct{..}))))

-- | Convert the parsed 'ChallengeParams' into serializable 'Params'
toProtoParams :: ChallengeParams -> Params
toProtoParams C{..} =
  reifyFactI (fromIntegral m) (\(_::proxy m) ->
    let bound = proxy (C.errorBound svar eps) (Proxy::Proxy m)
    in Cparams ContParams {..})
toProtoParams D{..} =
  reifyFactI (fromIntegral m) (\(_::proxy m) ->
    let bound = proxy (D.errorBound svar eps) (Proxy::Proxy m)
    in Dparams DiscParams {..})
toProtoParams R{..} = Rparams RLWRParams {..}

-- | Writes a 'ChallengeU' to a file given a path to the root of the tree
-- and the name of the challenge.
writeChallengeU :: FilePath -> String -> ChallengeU -> IO ()
writeChallengeU path challName (CU c insts) = do
  let challDir = challengeFilesDir path challName
      challFN = challFilePath path challName
  createDirectoryIfMissing True challDir
  writeProtoType challFN c
  mapM_ (writeInstanceU path challName) insts

-- | Writes an 'InstanceU' to a file given a path to the root of the tree
-- and the name of the challenge.
writeInstanceU :: FilePath -> String -> InstanceU -> IO ()
writeInstanceU path challName iu = do
  let s = secret iu
      idx = S.instanceID s
      instFN = instFilePath path challName idx
      secretFN = secretFilePath path challName idx
  case iu of
    (IC _ inst) -> writeProtoType instFN inst
    (ID _ inst) -> writeProtoType instFN inst
    (IR _ inst) -> writeProtoType instFN inst
  writeProtoType secretFN s

-- | Generate a continuous RLWE instance along with its (uniformly
-- random) secret, using the given scaled variance and number of
-- desired samples.
instanceCont :: (Fact m, Reifies q Int64, MonadRandom rnd, ToRational v)
  => v -> Int -> rnd (CycT m (Zq q), [C.Sample (CycT m) (Zq q) (RRq q)])
instanceCont svar num = do
  s <- getRandom
  samples <- replicateM num $ C.sample svar s
  return (s, samples)

-- | Generate a discrete RLWE instance along with its (uniformly
-- random) secret, using the given scaled variance and number of
-- desired samples.
instanceDisc :: (Fact m, Reifies q Int64, MonadRandom rnd, ToRational v)
  => v -> Int -> rnd (CycT m (Zq q), [D.Sample (CycT m) (Zq q)])
instanceDisc svar num = do
  s <- getRandom
  samples <- replicateM num $ D.sample svar s
  return (s, samples)

-- | Generate a discrete RLWR instance along with its (uniformly
-- random) secret, using the given scaled variance and number of
-- desired samples.
instanceRLWR :: (Fact m, Reifies p Int64, Reifies q Int64, MonadRandom rnd)
  => Int -> rnd (CycT m (Zq q), [R.Sample (CycT m) (Zq q) (Zq p)])
instanceRLWR num = do
  s <- getRandom
  samples <- replicateM num $ R.sample s
  return (s, samples)
