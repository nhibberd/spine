{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE GADTs #-}
module Spine.Schema (
    initialise
  , destroy
  ) where

import           Control.Lens (view, (^.), (.~))
import           Control.Monad.IO.Class (liftIO)

import           Data.Conduit ((=$=), ($$))
import qualified Data.Conduit.List as C
import qualified Data.Text.IO as T
import qualified Data.Set as S


import           Mismi (AWS)
import qualified Mismi.Amazonka as A

import qualified Network.AWS.DynamoDB as D

import           P

import           Spine.Data


initialise :: Schema -> AWS ()
initialise schema = do
  tables <- A.paginate D.listTables =$=
    C.mapFoldable (view D.ltrsTableNames) $$
    C.consume
  let
    indexed = S.fromList tables
    missing = filter (\t -> not $ S.member (tableName t) indexed) $ schemaTables schema

  forM_ missing $ \t -> do
    liftIO . T.putStrLn . mconcat $ ["Creating table: ", tableName t]
    void . A.send . tableToCreate $ t
    liftIO . T.putStrLn . mconcat $ ["  ` done"]

  forM_ (schemaTables schema) $ \t -> do
    liftIO . T.putStrLn . mconcat $ ["Waiting for table: ", tableName t]
    void . A.await D.tableExists . D.describeTable $ tableName t
    x <- A.send . D.describeTable $ tableName t
    case x ^. D.drsTable of
      Nothing ->
        -- table doesn't exist
        fail "no table yo ~ invariant. await broken? :<"
      Just v -> do
        let
          checkRead = (v ^. D.tdProvisionedThroughput >>= view D.ptdReadCapacityUnits) /= Just (readThroughput $ tableThroughput t)
          checkWrite = (v ^. D.tdProvisionedThroughput >>= view D.ptdWriteCapacityUnits) /= (Just . writeThroughput $ tableThroughput t)

        -- update modes
        when (checkRead || checkWrite) $ do
          liftIO . T.putStrLn . mconcat $ ["  ` updating throughput"]
          void . A.send $ D.updateTable (tableName t) &
            D.utProvisionedThroughput .~ Just (toThroughput $ tableThroughput t)

        -- failure modes
        when (v ^. D.tdKeySchema /= Just (tableToSchemaElement t)) $
          fail "schema key noobs"

        when (v ^. D.tdAttributeDefinitions /= tableToAttributeDefintions t) $
          fail "schema attribute noobs"

    liftIO . T.putStrLn . mconcat $ ["  ` done"]

destroy :: Schema -> AWS ()
destroy schema =
  forM_ (schemaTables schema) $ \t -> do
    liftIO . T.putStrLn . mconcat $ ["Deleting table: ", tableName t]
    void . A.send . D.deleteTable $ tableName t
    void . A.await D.tableNotExists . D.describeTable $ tableName t
    liftIO . T.putStrLn . mconcat $ ["  ` done"]
