{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ExtendedDefaultRules #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE DeriveGeneric #-}

module Api.Services.GameService where

import Control.Exception
import Control.Monad
import Control.Monad.IO.Class
import Database.MongoDB
import Database.MongoDB.Query as MQ
import Database.MongoDB.Connection
import Data.Bson as BS
import Api.Types
import Control.Lens
import Control.Monad.State.Class
import Data.List as DL
import Data.Aeson
import Data.UUID as UUID
import Data.UUID.V4
import Snap.Core
import Snap.Snaplet as SN
import qualified Data.ByteString.Char8 as B
import Data.Text as T
import Data.Text.IO as TIO
import Data.Text.Encoding
import Data.Time.Clock.POSIX

data GameService = GameService { }

makeLenses ''GameService

gemeTimeout :: Int
gemeTimeout = 360000

mapWidth :: Int
mapWidth = 10

mapHeight :: Int
mapHeight = 10
---------------------
-- Routes
gameRoutes :: Host -> Username -> Password -> Database -> FilePath -> [(B.ByteString, SN.Handler b GameService ())]
gameRoutes mongoHost mongoUser mongoPass mongoDb rulePath = [
    ("/", method GET $ getPublicGamesList mongoHost mongoUser mongoPass mongoDb),
    ("/", method POST $ createGame mongoHost mongoUser mongoPass mongoDb rulePath),
    ("/rules", method GET $ getRules rulePath),
    ("/:gameid/:session/setmap", method POST $ sendMap mongoHost mongoUser mongoPass mongoDb rulePath),
    ("/:gameid/:session", method GET $ getStatus mongoHost mongoUser mongoPass mongoDb),
    ("/:gameid/:session/invitebot", method POST $ inviteBot mongoHost mongoUser mongoPass mongoDb),
    ("/:gameid/:session/setpublic", method POST $ setPublic mongoHost mongoUser mongoPass mongoDb),
    ("/:gameid/connect/player", method POST $ connectGamePlayer mongoHost mongoUser mongoPass mongoDb),
    ("/:gameid/connect/guest", method POST $ connectGameGuest mongoHost mongoUser mongoPass mongoDb),
    ("/:gameid/:session/shoot", method POST $ shoot mongoHost mongoUser mongoPass mongoDb),
    ("/:gameid/:session/chat", method POST $ sendMessage mongoHost mongoUser mongoPass mongoDb),
    ("/:gameid/:session/chat", method GET $ readMessages mongoHost mongoUser mongoPass mongoDb)
  ]

-------------------------
-- Actions

---------------------------
-- get list of opened
--   sends nothing
--   GET /api/games/
--   response list of {game id, messsge}
--   200
--   [
--     {
--       "game": {gameid},
--       "owner": {name},
--       "message": {game message}
--     },
--     ...
--   ]
--   500
--   {message}
getPublicGamesList :: Host -> Username -> Password -> Database -> SN.Handler b GameService ()
getPublicGamesList mongoHost mongoUser mongoPass mongoDb = do
  pipe <- liftIO $ connectAndAuth mongoHost mongoUser mongoPass mongoDb
  let a action = liftIO $ performAction pipe mongoDb action
  modifyResponse $ setHeader "Content-Type" "application/json"
  time <- liftIO $ round <$> getPOSIXTime
  let action = rest =<< MQ.find (MQ.select ["date" =: ["$gte" =: time - gemeTimeout], "public" =: True] "games")
  games <- a $ action
  writeLBS . encode $ fmap (\d -> PublicGame (BS.at "game" d) (BS.at "name" (BS.at "owner" d)) (BS.at "message" d) (BS.at "rules" d)) games
  liftIO $ closeConnection pipe
  modifyResponse . setResponseCode $ 200


----------------------------
-- create game 
--   post username, message
--   POST /api/games
--   {
--     "username": {username},
--     "message": {message}
--   }
--   response new game id and session or error
--   201
--   {
--     "game": {gameid},
--     "session": {session}
--   }
--   400, 500
--   {message}
createGame :: Host -> Username -> Password -> Database -> FilePath -> SN.Handler b GameService ()
createGame mongoHost mongoUser mongoPass mongoDb rulePath = do
  pipe <- liftIO $ connectAndAuth mongoHost mongoUser mongoPass mongoDb
  let a action = liftIO $ performAction pipe mongoDb action
  modifyResponse $ setHeader "Content-Type" "application/json"
  user <- fmap (\x -> decode x :: Maybe NewGameUser) $ readRequestBody 4096
  case user of Just (NewGameUser name message rules) -> do
                 gameId <- liftIO $ UUID.toString <$> nextRandom
                 sessionId <- liftIO $ UUID.toString <$> nextRandom
                 time <- liftIO $ round <$> getPOSIXTime
                 crules <- liftIO $ currentRulesId rules rulePath
                 let game = [
                              "game" =: gameId,
                              "date" =: time,
                              "message" =: "",
                              "owner" =: ["name" =: name, "message" =: message, "session" =: sessionId],
                              "turn" =: ["notready"],
                              "public" =: False,
                              "rules" =: crules
                            ]
                 a $ MQ.insert "games" game
                 writeLBS $ encode $ NewGame gameId sessionId crules
                 modifyResponse $ setResponseCode 201
               Nothing -> do
                 writeLBS . encode $ APIError "Name message and rules can't be empty!"
                 modifyResponse $ setResponseCode 400
  liftIO $ closeConnection pipe

-----------------------
-- send map
--   post session id (owner and player can send map), json with map. Only empty or ship on map
--   POST /api/games/{gameid}/{session}/setmap
--   [[0,0,0,1,1,0,0...],[...],[...],...]
--   response ok or error (wrong map or other)
--   202
--   "ok"
--   406, 500
--   {message}
sendMap :: Host -> Username -> Password -> Database -> FilePath -> SN.Handler b GameService ()
sendMap mongoHost mongoUser mongoPass mongoDb rulePath = do
  time <- liftIO $ round <$> getPOSIXTime
  modifyResponse $ setHeader "Content-Type" "application/json"
  pgame <- getParam "gameid"
  session <- getParam "session"
  let game = case pgame of Just g -> B.unpack g
                           Nothing -> ""
  let msess = B.unpack <$> session
  mbseamap <- fmap (\x -> decode x :: Maybe [[Int]]) $ readRequestBody 4096
  case mbseamap of 
    Just seamap -> do
      pipe <- liftIO $ connectAndAuth mongoHost mongoUser mongoPass mongoDb
      let a action = liftIO $ performAction pipe mongoDb action
      rights <- liftIO $ fillRights pipe mongoDb game msess
      let act user sm t = [(
                   [
                     "game" =: game
                   ]::Selector,
                   [
                     "$set" =: [user =: ["map" =: sm]],
                     "$push" =: ["turn" =: t]
                   ]::Document,
                   [ ]::[UpdateOption]
                )]
      
      let chat n m= [ "game" =: game
                   , "name" =: n
                   , "session" =: msess
                   , "time" =: time
                   , "message" =: m
                   ]::Document
      let doit n u m t r = do
          myrules <- liftIO $ currentRules r rulePath
          case (isGood seamap myrules) of
            True -> do
              a $ MQ.updateAll "games" $ act u seamap t
              a $ MQ.insert "chats" $ chat n m
              writeLBS "ok"
              modifyResponse $ setResponseCode 200
            _ -> do
              writeLBS . encode $ APIError "Can't send this map for this game!"
              modifyResponse $ setResponseCode 406
      case rights of
        GameRights True True _ NOTREADY _ name _ rid _ -> do
          doit name "owner" "I've sent map." "owner_map" rid
        GameRights True True _ NOTREADY_WITH_MAP _ name _ rid _ -> do
          doit name "owner" "I've sent new map." "owner_map" rid
        GameRights True True _ CONFIG _ name _ rid _ -> do
          doit name "owner" "I've sent map. Waiting for you!" "owner_map" rid
        GameRights True True _ CONFIG_WAIT_OWNER _ name _ rid _ -> do
          doit name "owner" "I've sent map. Let's do this!" "owner_map" rid
        GameRights True True _ CONFIG_WAIT_PLAYER _ name _ rid _ -> do
          doit name "owner" "I've sent new map. Waiting for you!" "owner_map" rid
        GameRights True _ True CONFIG _ name _ rid _ -> do
          doit name "player" "I've sent map. Waiting for you!" "player_map" rid
        GameRights True _ True CONFIG_WAIT_OWNER _ name _ rid _ -> do
          doit name "player" "I've sent new map. Waiting for you!" "player_map" rid
        GameRights True _ True CONFIG_WAIT_PLAYER _ name _ rid _ -> do
          doit name "player" "I've sent map. Let's do this!" "player_map" rid
        _ -> do
           writeLBS . encode $ APIError "Can't send map for this game or game is not exists!"
           modifyResponse $ setResponseCode 403
      liftIO $ closeConnection pipe
    Nothing -> do
      writeLBS . encode $ APIError "Can't find your map!"
      modifyResponse $ setResponseCode 404

getStatus :: Host -> Username -> Password -> Database -> SN.Handler b GameService ()
getStatus mongoHost mongoUser mongoPass mongoDb = do
  pipe <- liftIO $ connectAndAuth mongoHost mongoUser mongoPass mongoDb
  let a action = liftIO $ performAction pipe mongoDb action
  modifyResponse $ setHeader "Content-Type" "application/json"
  modifyResponse . setResponseCode $ 200
  liftIO $ closeConnection pipe

inviteBot :: Host -> Username -> Password -> Database -> SN.Handler b GameService ()
inviteBot mongoHost mongoUser mongoPass mongoDb = do
  pipe <- liftIO $ connectAndAuth mongoHost mongoUser mongoPass mongoDb
  let a action = liftIO $ performAction pipe mongoDb action
  modifyResponse . setResponseCode $ 501
  liftIO $ closeConnection pipe

----------------------------
-- invite stranger
--   post game id and session (only owner can invite strangers) and message
--   POST /api/games/{gameid}/{session}/setpublic
--   {
--     "message": {message}
--   }
--   response success if added in list or error
--   200
--   "ok"
--   404, 500
--   {error}
setPublic :: Host -> Username -> Password -> Database -> SN.Handler b GameService ()
setPublic mongoHost mongoUser mongoPass mongoDb = do
  time <- liftIO $ round <$> getPOSIXTime
  pipe <- liftIO $ connectAndAuth mongoHost mongoUser mongoPass mongoDb
  let a action = liftIO $ performAction pipe mongoDb action
  modifyResponse $ setHeader "Content-Type" "application/json"
  pgame <- getParam "gameid"
  session <- getParam "session"
  message <- fmap (\x -> decode x :: Maybe Message) $ readRequestBody 4096
  case message of 
        Just (Message msg) -> do
              let game = case pgame of Just g -> B.unpack g
                                       Nothing -> ""
              let msess = (B.unpack <$> session)
              rights <- liftIO $ fillRights pipe mongoDb game msess
              let doit n = do
                  let act = [(
                               [
                                 "game" =: game
                               ]::Selector,
                               [
                                 "$set" =: ["public" =: True, "message" =: msg]
                               ]::Document,
                               [ ]::[UpdateOption]
                            )]
                  a $ MQ.updateAll "games" act
                  let chat = [ "game" =: game
                             , "name" =: n
                             , "session" =: msess
                             , "time" =: time
                             , "message" =: "Attention! Game is public now!"
                             ]::Document
                  a $ MQ.insert "chats" chat
                  writeLBS "ok"
                  modifyResponse . setResponseCode $ 200
              case rights of
                GameRights True True _ NOTREADY _ name False _ _ -> do
                  doit name
                GameRights True True _ NOTREADY_WITH_MAP _ name False _ _ -> do
                  doit name
                _ -> do
                  writeLBS . encode $ APIError "Can't make this game public!"
                  modifyResponse $ setResponseCode 400
        _ -> do
              writeLBS . encode $ APIError "Can't find message!"
              modifyResponse $ setResponseCode 400
  liftIO $ closeConnection pipe

---------------------------------
-- connect
--   post game id, username, role (guest|player), short message
--   POST /api/games/{gameid}/connect/{guest|player}
--   {
--     "name": "name",
--     "message": "message"
--   }
--   response session, or error.
--   202
--   {
--     "game": {game}
--     "session": {session}
--   }
--   404, 403, 400, 500
--   {message}
connectGamePlayer :: Host -> Username -> Password -> Database -> SN.Handler b GameService ()
connectGamePlayer mongoHost mongoUser mongoPass mongoDb = do
  time <- liftIO $ round <$> getPOSIXTime
  pipe <- liftIO $ connectAndAuth mongoHost mongoUser mongoPass mongoDb
  let a action = liftIO $ performAction pipe mongoDb action
  modifyResponse $ setHeader "Content-Type" "application/json"
  pgame <- getParam "gameid"
  player <- fmap (\x -> decode x :: Maybe GameUser) $ readRequestBody 4096
  case player of 
        Just (GameUser name message) -> do
              let game = case pgame of Just g -> B.unpack g
                                       Nothing -> ""
              rights <- liftIO $ fillRights pipe mongoDb game Nothing
              let doit = do
                  sessionId <- liftIO $ UUID.toString <$> nextRandom
                  let act = [(
                               [
                                 "game" =: game
                               ]::Selector,
                               [
                                 "$set" =: ["player" =: ["name" =: name, "message" =: message, "session" =: sessionId]],
                                 "$push" =: ["turn" =: "player_join"]
                               ]::Document,
                               [ ]::[UpdateOption]
                            )]
                  a $ MQ.updateAll "games" act
                  let chat = [ "game" =: game
                             , "name" =: name
                             , "session" =: sessionId
                             , "time" =: time
                             , "message" =: ("joined as a player!")
                             ]::Document
                  a $ MQ.insert "chats" chat
                  writeLBS $ encode $ SessionInfo game sessionId
                  modifyResponse . setResponseCode $ 200
              case rights of
                GameRights True False False NOTREADY _ _ _ _ _ -> do
                  doit
                GameRights True False False NOTREADY_WITH_MAP _ _ _ _ _ -> do
                  doit
                _ -> do
                  writeLBS . encode $ APIError "Can't connect as player!"
                  modifyResponse $ setResponseCode 400
        _ -> do
              writeLBS . encode $ APIError "Name and message are required!"
              modifyResponse $ setResponseCode 400
  liftIO $ closeConnection pipe

connectGameGuest :: Host -> Username -> Password -> Database -> SN.Handler b GameService ()
connectGameGuest mongoHost mongoUser mongoPass mongoDb = do
  time <- liftIO $ round <$> getPOSIXTime
  pipe <- liftIO $ connectAndAuth mongoHost mongoUser mongoPass mongoDb
  let a action = liftIO $ performAction pipe mongoDb action
  modifyResponse $ setHeader "Content-Type" "application/json"
  pgame <- getParam "gameid"
  player <- fmap (\x -> decode x :: Maybe GameUser) $ readRequestBody 4096
  case player of 
        Just (GameUser name message) -> do
              let game = case pgame of Just g -> B.unpack g
                                       Nothing -> ""
              rights <- liftIO $ fillRights pipe mongoDb game Nothing
              case rights of
                GameRights True _ _ _ _ _ _ _ _ -> do
                  sessionId <- liftIO $ UUID.toString <$> nextRandom
                  let act = [(
                               [
                                 "game" =: game
                               ]::Selector,
                               [
                                 "$push" =: ["guests" =: ["name" =: name, "message" =: message, "session" =: sessionId]]
                               ]::Document,
                               [ ]::[UpdateOption]
                            )]
                  a $ MQ.updateAll "games" act
                  let chat = [ "game" =: game
                             , "name" =: name
                             , "session" =: sessionId
                             , "time" =: time
                             , "message" =: ("joined as a guest!")
                             ]::Document
                  a $ MQ.insert "chats" chat
                  writeLBS $ encode $ SessionInfo game sessionId
                  modifyResponse . setResponseCode $ 200
                _ -> do
                  writeLBS . encode $ APIError "Can't connect as guest!"
                  modifyResponse $ setResponseCode 400
        _ -> do
              writeLBS . encode $ APIError "Name and message are required!"
              modifyResponse $ setResponseCode 400
  liftIO $ closeConnection pipe

------------------------------
-- shoot
--   post game id, session (only owner and player can shoot and only in ther turn) and coords
--   POST /api/games/{gameid}/{session}/shoot
--   {
--     "x": {x},
--     "y": {y},
--   }
--   response result (hit|miss|sink|win) or error
--   202
--   {hit|miss|sink|win}
--   404, 403, 400, 500
--   {message}
shoot :: Host -> Username -> Password -> Database -> SN.Handler b GameService ()
shoot mongoHost mongoUser mongoPass mongoDb = do
  time <- liftIO $ round <$> getPOSIXTime
  pipe <- liftIO $ connectAndAuth mongoHost mongoUser mongoPass mongoDb
  let a action = liftIO $ performAction pipe mongoDb action
  modifyResponse $ setHeader "Content-Type" "application/json"
  pgame <- getParam "gameid"
  session <- getParam "session"
  mbshot <- fmap (\x -> decode x :: Maybe Shot) $ readRequestBody 4096
  case mbshot of 
        Just shot -> do
              let game = case pgame of Just g -> B.unpack g
                                       Nothing -> ""
              let msess = (B.unpack <$> session)
              rights <- liftIO $ fillRights pipe mongoDb game msess
              let doit n (Shot x y) enemy cell response turn = do
                  let act = [(
                               [
                                 "game" =: game
                               ]::Selector,
                               [
                                 "$set" =: [enemy =: [(T.pack . DL.concat $ ["map.", show y,".",show x]) =: cell]],
                                 "$push" =: ["turn" =: turn]
                               ]::Document,
                               [ ]::[UpdateOption]
                            )]
                  a $ MQ.updateAll "games" act
                  let chat = [ "game" =: game
                             , "name" =: n
                             , "session" =: msess
                             , "time" =: time
                             , "message" =: (T.pack . DL.concat $ [shotLabel x y, " - ", response])
                             ]::Document
                  a $ MQ.insert "chats" chat
                  writeLBS . encode $ response
                  modifyResponse . setResponseCode $ 200
              case rights of
                GameRights True True _ OWNER _ name _ _ (Just gameinfo) -> do
                  let enemymap = (BS.at "map" (BS.at "player" gameinfo)) :: [[Int]]
                  case isShotSane enemymap shot of
                    True -> case getCell enemymap shot of 
                      0 -> doit name shot "player" 2 "miss" "player"
                      1 -> case isSink enemymap shot of
                        True -> case isWin enemymap of
                          True -> doit name shot "player" 3 "WON" "finished"
                          False -> doit name shot "player" 3 "sank" "owner"
                        False -> doit name shot "player" 3 "hit" "owner"
                      2 -> do
                        writeLBS . encode $ APIError "You already shot here!"
                        modifyResponse $ setResponseCode 406
                      3 -> do
                        writeLBS . encode $ APIError "You already shot here!"
                        modifyResponse $ setResponseCode 406
                    otherwise -> do
                      writeLBS . encode $ APIError "Wrong shot!"
                      modifyResponse $ setResponseCode 406
                GameRights True _ True PLAYER _ name _ _ (Just gameinfo) -> do
                  let enemymap = (BS.at "map" (BS.at "owner" gameinfo)) :: [[Int]]
                  case isShotSane enemymap shot of
                    True -> case getCell enemymap shot of 
                      0 -> doit name shot "owner" 2 "miss" "owner"
                      1 -> case isSink enemymap shot of
                        True -> case isWin enemymap of
                          True -> doit name shot "owner" 3 "WON" "finished"
                          False -> doit name shot "owner" 3 "sank" "player"
                        False -> doit name shot "owner" 3 "hit" "player"
                      2 -> do
                        writeLBS . encode $ APIError "You already shot here!"
                        modifyResponse $ setResponseCode 406
                      3 -> do
                        writeLBS . encode $ APIError "You already shot here!"
                        modifyResponse $ setResponseCode 406
                    otherwise -> do
                      writeLBS . encode $ APIError "Wrong shot!"
                      modifyResponse $ setResponseCode 406
                _ -> do
                  writeLBS . encode $ APIError "Can't make this game public!"
                  modifyResponse $ setResponseCode 400
        _ -> do
              writeLBS . encode $ APIError "Can't find coordinates!"
              modifyResponse $ setResponseCode 400
  liftIO $ closeConnection pipe

shotLabel:: Int -> Int -> String
shotLabel x y = DL.concat [DL.take 1 . DL.drop x $ "ABCDEFGHIJKLMNOPQRSTUVWXYZ", show . (+1) $ y]
--------------------------
-- write message
--   post game id, session, message
--   POST /api/games/{gameid}/{session}/chat/
--   {message}
--   response success or error
--   201
--   "ok"
--   404, 403, 400, 500
--   {
--     "error": {message}
--   }
sendMessage :: Host -> Username -> Password -> Database -> SN.Handler b GameService ()
sendMessage mongoHost mongoUser mongoPass mongoDb = do
  time <- liftIO $ round <$> getPOSIXTime
  pipe <- liftIO $ connectAndAuth mongoHost mongoUser mongoPass mongoDb
  let a action = liftIO $ performAction pipe mongoDb action
  modifyResponse $ setHeader "Content-Type" "application/json"
  pgame <- getParam "gameid"
  session <- getParam "session"
  mmessage <- fmap (\x -> decode x :: Maybe String) $ readRequestBody 4096
  case mmessage of 
        Just message -> do
              let game = case pgame of Just g -> B.unpack g
                                       Nothing -> ""
              let msess = B.unpack <$> session
              rights <- liftIO $ fillRights pipe mongoDb game msess
              let chat n = [ "game" =: game
                           , "name" =: n
                           , "session" =: msess
                           , "time" =: time
                           , "message" =: message
                           ]::Document
              case rights of
                GameRights True True _ _ _ n _ _ _ -> do
                  a $ MQ.insert "chats" $ chat n
                  writeLBS "ok"
                  modifyResponse . setResponseCode $ 201
                GameRights True _ True _ _ n _ _ _ -> do
                  a $ MQ.insert "chats" $ chat n
                  writeLBS "ok"
                  modifyResponse . setResponseCode $ 201
                GameRights True _ _ _ True n _ _ _ -> do
                  a $ MQ.insert "chats" $ chat n
                  writeLBS "ok"
                  modifyResponse . setResponseCode $ 201
                _ -> do
                   writeLBS . encode $ APIError "Can't write message here!"
                   modifyResponse $ setResponseCode 403
        _ -> do
              writeLBS . encode $ APIError "Can't find message!"
              modifyResponse $ setResponseCode 404
  liftIO $ closeConnection pipe

------------------------------
-- read messages
--   send game id, session, last check date(or nothing)
--   GET /api/games/{gameid}/{session}/chat?lastcheck={date}
--   response list of [{name, message, date}], last check date or error
--   200
--   [
--     {
--       "name": {name},
--       "message": {message},
--       "date": {date}
--     },
--     ...
--   ]
--   404, 500
--   {message}
readMessages :: Host -> Username -> Password -> Database -> SN.Handler b GameService ()
readMessages mongoHost mongoUser mongoPass mongoDb = do
  pipe <- liftIO $ connectAndAuth mongoHost mongoUser mongoPass mongoDb
  let a action = liftIO $ performAction pipe mongoDb action
  modifyResponse $ setHeader "Content-Type" "application/json"
  pgame <- getParam "gameid"
  pltime <- getQueryParam "lastcheck"
  session <- getParam "session"
  let game = case pgame of Just g -> B.unpack g
                           Nothing -> ""
  let msess = B.unpack <$> session
  let ltime = (Prelude.read (case pltime of Just t -> B.unpack t
                                            Nothing -> "0")) :: Integer
  let action g t = rest =<< MQ.find (MQ.select ["time" =: ["$gt" =: t], "game" =: g] "chats")
  rights <- liftIO $ fillRights pipe mongoDb game msess
  case rights of
    GameRights True True _ _ _ _ _ _ _ -> do
      messages <- a $ action game ltime
      writeLBS . encode $ fmap (\m -> ChatMessage (BS.at "game" m) (BS.at "name" m) (BS.at "session" m) (BS.at "time" m) (BS.at "message" m)) messages
      modifyResponse . setResponseCode $ 200
    GameRights True _ True _ _ _ _ _ _ -> do
      messages <- a $ action game ltime
      writeLBS . encode $ fmap (\m -> ChatMessage (BS.at "game" m) (BS.at "name" m) (BS.at "session" m) (BS.at "time" m) (BS.at "message" m)) messages
      modifyResponse . setResponseCode $ 200
    GameRights True _ _ _ True _ _ _ _ -> do
      messages <- a $ action game ltime 
      writeLBS . encode $ fmap (\m -> ChatMessage (BS.at "game" m) (BS.at "name" m) (BS.at "session" m) (BS.at "time" m) (BS.at "message" m)) messages
      modifyResponse . setResponseCode $ 200
    _ -> do
       writeLBS . encode $ APIError "Can't read messages!"
       modifyResponse $ setResponseCode 403
  liftIO $ closeConnection pipe

------------------------------
-- get rules list
--   sends nothing
--   GET /api/games/rules
--   response rules list or error
--   200
--   [
--     {
--       "id": {id}
--       "name": {name},
--       "description": {text},
--       "rules": {ship set}
--     }
--   ]
--   404, 403, 400, 500
--   {message}
getRules :: FilePath -> SN.Handler b GameService ()
getRules rulePath = do
  rules <- liftIO $ (decodeFileStrict rulePath :: IO (Maybe [Rule]))
  case rules of Just r -> do
                        writeLBS . encode $ rules
                Nothing -> do
                        writeLBS "[]"
  modifyResponse $ setHeader "Content-Type" "application/json"
  modifyResponse . setResponseCode $ 200

----------------------
-- Game authentication
fillRights :: Pipe -> Database -> String -> Maybe String -> IO GameRights
fillRights pipe mongoDb game session = do
  let a action = liftIO $ performAction pipe mongoDb action
  time <- liftIO $ round <$> getPOSIXTime
  game <- a $ MQ.findOne (MQ.select ["date" =: ["$gte" =: time - gemeTimeout], "game" =: game] "games")
  let turn v = case v of Right (BS.Array l) -> getTurn $ DL.map (\v -> case v of (BS.String s) -> T.unpack s 
                                                                                 _ -> "noop") l
                         _ -> NOTREADY
  case game of 
    Just g -> 
      case session of
        Just sess -> do
          vturn <- try (BS.look "turn" g) :: IO (Either SomeException BS.Value)
          public <- try (BS.look "public" g) :: IO (Either SomeException BS.Value)
          let ispublic = case public of Right (BS.Bool p) -> p
                                        _ -> False
          owner <- try (BS.look "owner" g) :: IO (Either SomeException BS.Value)
          osess <- case owner of
              Right (BS.Doc d) -> BS.look "session" d
              _ -> return $ BS.Bool False
          let isowner = case osess of (BS.String s) -> (T.unpack s) == sess
                                      _ -> False
          player <- try (BS.look "player" g) :: IO (Either SomeException BS.Value)
          psess <- case player of
              Right (BS.Doc d) -> BS.look "session" d
              _ -> return $ BS.Bool False
          let isplayer = case psess of (BS.String s) -> (T.unpack s) == sess
                                       _ -> False
          guests <- try (BS.look "guests" g) :: IO (Either SomeException BS.Value)
          let isguest = case guests of 
                Right (BS.Array a) -> and $ fmap (\g -> 
                              (case g of (BS.Doc dg) -> (T.unpack (BS.at "session" dg)) == sess
                                         _ -> False)) a
                _ -> False
          let uname = case isowner of
                True -> T.unpack $ BS.at "name" $ BS.at "owner" g
                False -> case isplayer of
                      True -> T.unpack $ BS.at "name" $ BS.at "player" g
                      False -> case isguest of
                            True -> T.unpack $ BS.at "name" $ Prelude.head $ Prelude.filter (\x -> (BS.at "session" x) == sess) $ BS.at "guests" g
                            False -> ""
          let rules = BS.at "rules" g
          return $ GameRights True isowner isplayer (turn vturn) isguest uname ispublic rules game
        Nothing -> do
          vturn <- try (BS.look "turn" g) :: IO (Either SomeException BS.Value)
          return $ GameRights True False False (turn vturn) False "" False "free" Nothing
    Nothing -> return $ GameRights False False False OWNER False "" False "free" Nothing

getTurn :: [String] -> Turn
getTurn = getTurn' NOTREADY

getTurn' :: Turn -> [String] -> Turn
getTurn' t [] = t
getTurn' t (x:xs) = getTurn' (changeTurn t x) xs

changeTurn :: Turn -> String -> Turn
changeTurn t s = case t of
  NOTREADY -> DL.head $ [CONFIG | s == "player_join"] ++ [NOTREADY_WITH_MAP | s == "owner_map"] ++ [t]
  CONFIG -> DL.head $ [CONFIG_WAIT_PLAYER | s == "owner_map"] ++ [CONFIG_WAIT_OWNER | s == "player_map"] ++ [t]
  NOTREADY_WITH_MAP -> DL.head $ [CONFIG_WAIT_PLAYER | s == "player_join"] ++ [t]
  CONFIG_WAIT_PLAYER -> DL.head $ [OWNER | s == "player_map"] ++ [t]
  CONFIG_WAIT_OWNER -> DL.head $ [OWNER | s == "owner_map"] ++ [t]
  OWNER -> DL.head $ [PLAYER | s == "player"] ++ [OWNER_WIN | s == "finished"] ++ [t]
  PLAYER -> DL.head $ [OWNER | s == "owner"] ++ [PLAYER_WIN | s == "finished"] ++ [t]

currentRulesId :: String -> FilePath -> IO String
currentRulesId rules rulePath = do
  allrules <- liftIO $ (decodeFileStrict rulePath :: IO (Maybe [Rule]))
  case allrules of Just rs -> do
                       return $ case (Prelude.length $ Prelude.filter (\(Rule rid _ _ _ _) -> rid == rules) rs) of 
                            0 -> "free"
                            _ -> rules
                   Nothing -> 
                       return "free"

currentRules :: String -> FilePath -> IO Rule
currentRules rules rulePath = do
  allrules <- liftIO $ (decodeFileStrict rulePath :: IO (Maybe [Rule]))
  case allrules of Just rs -> do
                       let myrules = Prelude.filter (\(Rule rid _ _ _ _) -> rid == rules) rs
                       return $ case (Prelude.length $ myrules) of 
                            0 -> Rule "free" "" "" [] 0
                            _ -> Prelude.head myrules
                   Nothing -> 
                       return $ Rule "free" "" "" [] 0

----------------------
-- Map checks
-- For each rule:  
-- rules: text with description  
-- ships description:   
-- [(1,4), (2,3), (3,2), (4,1)]  
-- in send map I need to check rules. To do it:  
-- get list of counts for separated non empty cells: [0,0,0,1,1,0,1,1,1,0] -> [2,3]  
-- get the same from transposed map  
-- get amount of twos, threes and so on. It should be as it is in the rules set.  
-- for ones amount should be sum of not-ones from another list plus amount of ones  
-- For test:
-- Rules: [[1,2],[2,2],[3,1]]
-- 1 0 1 0 1  1 1 1 0 1
-- 1 0 1 0 0  0 0 0 0 0
-- 1 0 0 0 0  1 1 0 1 0
-- 0 0 1 1 0  0 0 0 1 0
-- 1 0 0 0 0  1 0 0 0 0
-- [[1,0,1,0,1],[1,0,1,0,0],[1,0,0,0,0],[0,0,1,1,0],[1,0,0,0,0]]
-- [[1,1,1,0,1],[0,0,0,0,0],[1,1,0,1,0],[0,0,0,1,0],[1,0,0,0,0]]
isGood :: [[Int]] -> Rule -> Bool
isGood sm (Rule rid _ _ ships _) = (isSane sm) && (rid == "free" || (isShipsByRule sm ships) && (noDiagonalShips sm))

isSane :: [[Int]] -> Bool
isSane m = (mapHeight == DL.length m) && (and [l==mapWidth | l <- [DL.length ra | ra <- m]])

isShipsByRule :: [[Int]] -> [[Int]] -> Bool
isShipsByRule sm r = isProjectionByRule r (getProjection sm) (getProjection . DL.transpose $ sm)

-------------------------
-- getProjection [[1,0,1,0,1],[1,0,1,0,0],[1,0,0,0,0],[0,0,1,1,0],[1,0,0,0,0]]
-- result:[1,1,1,1,1,0,0,1,0,0,0,0,0,0,2,0,1,0,0,0,0]
-- getProjection [[1,1,1,0,1],[0,0,0,0,0],[1,1,0,1,0],[0,0,0,1,0],[1,0,0,0,0]]
-- result [3,1,0,0,0,0,0,0,2,1,0,0,0,0,1,0,1,0,0,0,0]
getProjection :: [[Int]] -> [Int]
getProjection m = DL.concat $ [DL.foldr (\x (y:ys) -> case x of 
                                                   0 -> [0] ++ (y:ys)
                                                   _ -> (y+1:ys)) [0] $ l | l <- m]

----------------------------
-- isProjectionByRule [[1,2],[2,2],[3,1]] [1,1,1,1,1,0,0,1,0,0,0,0,0,0,2,0,1,0,0,0,0] [3,1,0,0,0,0,0,0,2,1,0,0,0,0,1,0,1,0,0,0,0]
-- True
isProjectionByRule :: [[Int]] -> [Int] -> [Int] -> Bool
isProjectionByRule rs p pt = and [checkRule (DL.head r) (DL.head . DL.tail $ r) | r <- rs]
     where checkRule d c = (DL.head $ [c * 2 | d==1] ++ [c]) == (((DL.length $ DL.filter (d==) p) 
                        + (DL.length $ DL.filter (d==) pt))
                        - (DL.head $ [(sum $ DL.filter (1/=) p) + (sum $ DL.filter (1/=) pt) | d==1] ++ [0]))

------------------------------
-- noDiagonalShips [[1,0,1,0,1],[1,0,1,0,0],[1,0,0,0,0],[0,0,1,1,0],[1,0,0,0,0]]
-- True
-- noDiagonalShips [[1,0,1,0,1],[1,0,1,0,0],[1,0,0,0,0],[0,1,1,0,0],[1,0,0,0,0]]
-- False
noDiagonalShips :: [[Int]] -> Bool
noDiagonalShips sm = not $ isIntersected sm ((shiftUp [0]) . (shiftLeft 0) $ sm) 
                        && isIntersected sm ((shiftUp [0]) . (shiftRight 0) $ sm)
                        && isIntersected sm ((shiftDown [0]) . (shiftLeft 0) $ sm)
                        && isIntersected sm ((shiftDown [0]) . (shiftRight 0) $ sm)

shiftUp :: a -> [a] -> [a]
shiftUp z xs = DL.tail xs ++ [z]

shiftDown :: a -> [a] -> [a]
shiftDown z xs = [z] ++ DL.take (-1+DL.length xs) xs

shiftLeft :: a -> [[a]] -> [[a]]
shiftLeft z xss = [shiftUp z xs | xs <- xss]

shiftRight :: a -> [[a]] -> [[a]]
shiftRight z xss = [shiftDown z xs | xs <- xss]

isIntersected :: [[Int]] -> [[Int]] -> Bool
isIntersected m1 m2 = or . DL.concat $ [DL.zipWith (\a b -> (a * b) > 0) x y | (x, y) <- DL.zip m1 m2]

---------------------------------
-- check shot
isShotSane :: [[Int]] -> Shot -> Bool
isShotSane sm (Shot x y) = DL.length sm > y && ((DL.drop x) . (DL.head . DL.drop y) $ sm) /= []

getCell :: [[Int]] -> Shot -> Int
getCell sm (Shot x y) = (DL.head . DL.drop x) . (DL.head . DL.drop y) $ sm

isSink :: [[Int]] -> Shot -> Bool
isSink m (Shot x y) = checkLine x (DL.head . (DL.drop y) $ m)
                      && checkLine y (DL.head . (DL.drop x) $ (DL.transpose m))

checkLine :: Int -> [Int] -> Bool
checkLine x xs = and $ (checkPartOfLine $ DL.drop (x+1) $ xs) ++ 
                       (checkPartOfLine $ DL.drop ((DL.length xs) - x) $ (DL.reverse xs))

checkPartOfLine :: [Int] -> [Bool]
checkPartOfLine [] = [True]
checkPartOfLine xs = DL.map (3==) $ getWhile (\v -> v==1|| v==3) xs

getWhile :: Ord a => (a -> Bool) -> [a] -> [a]
getWhile t [] = []
getWhile t (x:[]) = [x | t x]
getWhile t (x:xs) | t x = [x] ++ getWhile t xs
                  | otherwise = []

isWin :: [[Int]] -> Bool
isWin sm = sum [sum [DL.head $ [0 | c/=1] ++ [1] | c <- l] | l <- sm] == 1

----------------------
-- MongoDB functions
connectAndAuth :: Host -> Username -> Password -> Database -> IO Pipe
connectAndAuth mongoHost mongoUser mongoPass mongoDb = do 
  pipe <- connect mongoHost
  access pipe master mongoDb $ auth mongoUser mongoPass
  return pipe

performAction :: Pipe -> Database -> Action IO a -> IO a
performAction pipe mongoDb action = access pipe master mongoDb action

closeConnection :: Pipe -> IO ()
closeConnection pipe = close pipe

----------------------
-- Initialization
gameServiceInit :: String -> String -> String -> String -> String -> SnapletInit b GameService
gameServiceInit mongoHost mongoUser mongoPass mongoDb rulePath = makeSnaplet "game" "Battleship Service" Nothing $ do
  addRoutes $ gameRoutes (readHostPort mongoHost) (T.pack mongoUser) (T.pack mongoPass) (T.pack mongoDb) rulePath
  return $ GameService
