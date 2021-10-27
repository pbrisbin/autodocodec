{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

module Autodocodec.Aeson.Document where

import Autodocodec
import Autodocodec.Aeson.Encode
import Data.Aeson (FromJSON (..), ToJSON (..))
import qualified Data.Aeson as JSON
import Data.Foldable
import qualified Data.HashMap.Strict as HM
import Data.List
import Data.List.NonEmpty (NonEmpty (..))
import qualified Data.List.NonEmpty as NE
import Data.Map (Map)
import qualified Data.Map as M
import Data.Maybe
import qualified Data.Set as S
import Data.Text (Text)
import Data.Validity
import Data.Validity.Aeson ()
import Data.Validity.Containers ()
import Data.Validity.Text ()
import GHC.Generics (Generic)

-- TODO think about putting this value in a separate package or directly in autodocodec
--
-- http://json-schema.org/understanding-json-schema/reference/index.html
data JSONSchema
  = AnySchema
  | NullSchema
  | BoolSchema
  | StringSchema
  | NumberSchema
  | ArraySchema !JSONSchema
  | -- | This needs to be a list because keys should stay in their original ordering.
    ObjectSchema ![(Text, (KeyRequirement, JSONSchema))]
  | ValueSchema !JSON.Value
  | ChoiceSchema !(NonEmpty JSONSchema)
  | CommentSchema !Text !JSONSchema
  deriving (Show, Eq, Generic)

validateAccordingTo :: JSON.Value -> JSONSchema -> Bool
validateAccordingTo = go
  where
    go :: JSON.Value -> JSONSchema -> Bool
    go value = \case
      AnySchema -> True
      NullSchema -> value == JSON.Null
      BoolSchema -> case value of
        JSON.Bool _ -> True
        _ -> False
      StringSchema -> case value of
        JSON.String _ -> True
        _ -> False
      NumberSchema -> case value of
        JSON.Number _ -> True
        _ -> False
      ArraySchema as -> case value of
        JSON.Array v -> all (`validateAccordingTo` as) v
        _ -> False
      ObjectSchema kss -> case value of
        JSON.Object hm ->
          let goKey :: Text -> JSON.Value -> Bool
              goKey key value' = case lookup key kss of
                Nothing -> False
                Just (_, ks) -> go value' ks
              goKeySchema :: Text -> (KeyRequirement, JSONSchema) -> Bool
              goKeySchema key (kr, ks) = case HM.lookup key hm of
                Nothing -> kr == Optional
                Just value' -> go value' ks
              actualKeys = HM.toList hm
           in all (uncurry goKey) actualKeys && all (uncurry goKeySchema) kss
        _ -> False
      ValueSchema v -> v == value
      ChoiceSchema ss -> any (go value) ss
      CommentSchema _ s -> go value s

instance Validity JSONSchema where
  validate js =
    mconcat
      [ genericValidate js,
        declare "never has two nested comments" $ case js of
          CommentSchema _ (CommentSchema _ _) -> False
          _ -> True,
        case js of
          ObjectSchema ks ->
            declare "there are no two equal keys in a keys schema" $
              let l = map fst ks
               in nub l == l
          ChoiceSchema cs -> declare "there are 2 of more choices" $ length cs >= 2
          _ -> valid
      ]

data KeyRequirement = Required | Optional
  deriving (Show, Eq, Generic)

instance Validity KeyRequirement

instance ToJSON JSONSchema where
  toJSON = JSON.object . go
    where
      go = \case
        AnySchema -> []
        NullSchema -> ["type" JSON..= ("null" :: Text)]
        BoolSchema -> ["type" JSON..= ("boolean" :: Text)]
        StringSchema -> ["type" JSON..= ("string" :: Text)]
        NumberSchema -> ["type" JSON..= ("number" :: Text)]
        ArraySchema s -> ["type" JSON..= ("array" :: Text), "items" JSON..= s]
        ValueSchema v -> ["const" JSON..= v]
        ObjectSchema os ->
          let combine (ps, rps) (k, (r, s)) =
                ( (k, s) : ps,
                  case r of
                    Required -> S.insert k rps
                    Optional -> rps
                )
              (props, requiredProps) = foldl' combine ([], S.empty) os
           in case props of
                [] -> ["type" JSON..= ("object" :: Text)]
                _ ->
                  if S.null requiredProps
                    then
                      [ "type" JSON..= ("object" :: Text),
                        "properties" JSON..= HM.fromList props
                      ]
                    else
                      [ "type" JSON..= ("object" :: Text),
                        "properties" JSON..= HM.fromList props,
                        "required" JSON..= requiredProps
                      ]
        ChoiceSchema jcs -> ["anyOf" JSON..= jcs]
        CommentSchema comment s -> ("$comment" JSON..= comment) : go s -- TODO this is probably wrong.

instance FromJSON JSONSchema where
  parseJSON = JSON.withObject "JSONSchema" $ \o -> do
    mt <- o JSON..:? "type"
    mc <- o JSON..:? "$comment"
    let commentFunc = maybe id CommentSchema mc
    fmap commentFunc $ case mt :: Maybe Text of
      Just "null" -> pure NullSchema
      Just "boolean" -> pure BoolSchema
      Just "string" -> pure StringSchema
      Just "number" -> pure NumberSchema
      Just "array" -> do
        mI <- o JSON..:? "items"
        case mI of
          Nothing -> pure $ ArraySchema AnySchema
          Just is -> pure $ ArraySchema is
      Just "object" -> do
        mP <- o JSON..:? "properties"
        case mP of
          Nothing -> pure $ ObjectSchema []
          Just (props :: Map Text JSONSchema) -> do
            requiredProps <- fromMaybe [] <$> o JSON..:? "required"
            let keySchemaFor k s =
                  ( k,
                    ( if k `elem` requiredProps
                        then Required
                        else Optional,
                      s
                    )
                  )
            pure $ ObjectSchema $ map (uncurry keySchemaFor) $ M.toList props
      Nothing -> do
        mAny <- o JSON..:? "anyOf"
        case mAny of
          Just anies -> pure $ ChoiceSchema anies
          Nothing -> do
            mConst <- o JSON..:? "const"
            pure $ case mConst of
              Just constant -> ValueSchema constant
              Nothing -> AnySchema
      t -> fail $ "unknown schema type:" <> show t

jsonSchemaViaCodec :: forall a. HasCodec a => JSONSchema
jsonSchemaViaCodec = jsonSchemaVia (codec @a)

jsonSchemaVia :: Codec input output -> JSONSchema
jsonSchemaVia = go
  where
    go :: Codec input output -> JSONSchema
    go = \case
      ValueCodec -> AnySchema
      NullCodec -> NullSchema
      BoolCodec -> BoolSchema
      StringCodec -> StringSchema
      NumberCodec -> NumberSchema
      ArrayCodec mname c -> maybe id CommentSchema mname $ ArraySchema (go c)
      ObjectCodec mname oc -> maybe id CommentSchema mname $ ObjectSchema (goObject oc)
      EqCodec value c -> ValueSchema (toJSONVia c value)
      BimapCodec _ _ c -> go c
      EitherCodec c1 c2 -> ChoiceSchema (goChoice (go c1 :| [go c2]))
      ExtraParserCodec _ _ c -> go c
      CommentCodec t c -> CommentSchema t (go c)

    goChoice :: NonEmpty JSONSchema -> NonEmpty JSONSchema
    goChoice (s :| rest) = case NE.nonEmpty rest of
      Nothing -> goSingle s
      Just ne -> goSingle s <> goChoice ne
      where
        goSingle :: JSONSchema -> NonEmpty JSONSchema
        goSingle = \case
          ChoiceSchema ss -> goChoice ss
          s' -> s' :| []

    goObject :: ObjectCodec input output -> [(Text, (KeyRequirement, JSONSchema))]
    goObject = \case
      RequiredKeyCodec k c -> [(k, (Required, go c))]
      OptionalKeyCodec k c -> [(k, (Optional, go c))]
      BimapObjectCodec _ _ oc -> goObject oc
      PureObjectCodec _ -> []
      ApObjectCodec oc1 oc2 -> goObject oc1 ++ goObject oc2
