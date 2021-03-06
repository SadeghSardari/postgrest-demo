{-# LANGUAGE DeriveDataTypeable     #-}
{-# LANGUAGE DeriveGeneric          #-}
{-# LANGUAGE FlexibleInstances      #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE MultiParamTypeClasses  #-}
{-# LANGUAGE OverloadedStrings      #-}
{-# LANGUAGE TemplateHaskell        #-}

module Main where

import           Control.Concurrent
import           Control.Concurrent.Async
import           Control.Concurrent.STM
import           Control.Lens                   hiding ((.=))
import           Control.Monad
import           Control.Monad.IO.Class
import           Data.Aeson
import           Data.Aeson.Casing
import           Data.Aeson.Lens
import           Data.ByteString                (ByteString)
import           Data.Default
import           Data.Hashable
import qualified Data.Map
import           Data.Maybe
import           Data.String
import           Data.Text                      (Text)
import qualified Data.Text                      as T
import qualified Data.Text.Encoding             as T
import           Data.Typeable
import           Database.PostgreSQL.Simple
import           Database.PostgreSQL.Simple.URL
import           GHC.Generics
import qualified ListT
import           Network.Wreq
import           Network.Wreq.Types             (Postable (..))
import           STMContainers.Map              (Map)
import qualified STMContainers.Map              as Map
import           STMContainers.Set              (Set)
import qualified STMContainers.Set              as Set
import           System.IO
import           System.IO.Unsafe
import           System.Process
import           Test.Tasty
import           Test.Tasty.HUnit               as HUnit
import           Test.Tasty.QuickCheck          as QC
import           Text.Regex.TDFA
import           Text.Regex.TDFA.Text
import           Web.JWT                        (Algorithm (..), ClaimsMap,
                                                 JSON, JWTClaimsSet,
                                                 encodeSigned, secret,
                                                 unregisteredClaims)

type Account = Text

data Flag
   = FlagLogEntriesJoe
   | FlagLogEntriesScott
   deriving (Eq, Ord, Typeable, Generic)

instance Hashable Flag

data TestEnv
   = TestEnv
      { envPostgresConnection :: !Connection
      , envWebserverHandles   :: !(Maybe Handle, Maybe Handle, Maybe Handle, ProcessHandle)
      , envAccountMap         :: Map Text Account
      , envFlagSet            :: Set Flag
      }

-- BEGIN: Messages

data PostgrestError
   = PostgrestError
      { pgerrCode    :: Text
      , pgerrDetails :: Maybe Text
      , pgerrHint    :: Maybe Text
      , pgerrMessage :: Text
      }
   deriving (Show, Typeable, Generic)

instance ToJSON PostgrestError where
   toJSON = genericToJSON $ aesonPrefix snakeCase
instance FromJSON PostgrestError where
   parseJSON = genericParseJSON $ aesonPrefix snakeCase

--

data RegisterPostReq
   = RegisterPostReq
      { regpostreqEmail    :: Text
      , regpostreqName     :: Text
      , regpostreqPassword :: Text
      }
   deriving (Show, Typeable, Generic)

instance ToJSON RegisterPostReq where
   toJSON = genericToJSON $ aesonPrefix snakeCase
instance FromJSON RegisterPostReq where
   parseJSON = genericParseJSON $ aesonPrefix snakeCase
instance Postable RegisterPostReq where
   postPayload = postPayload . toJSON

--

data RegisterPostRes
   = RegisterPostRes
      { regpostresRegisterAccount :: Text
      }
   deriving (Show, Typeable, Generic)

instance ToJSON RegisterPostRes where
   toJSON = genericToJSON $ aesonPrefix snakeCase
instance FromJSON RegisterPostRes where
   parseJSON = genericParseJSON $ aesonPrefix snakeCase

$(makeLensesWith abbreviatedFields ''PostgrestError)
$(makeLensesWith abbreviatedFields ''RegisterPostReq)
$(makeLensesWith abbreviatedFields ''RegisterPostRes)

-- END: Messages

$(makeLensesWith abbreviatedFields ''TestEnv)

main :: IO ()
main = defaultMain $ withResource initEnv (freeEnv True) tests

initEnv :: IO TestEnv
initEnv = do
   pgConn <- connect $ fromJust
      $ parseDatabaseUrl "postgres://localhost:5432/postgrest_demo"

   depProc@(_, _, _, depPH) <- createProcess
      (shell "cd ../db && sqitch deploy")
   depECode <- waitForProcess depPH
   print depECode

   verProc@(_, _, _, verPH) <- createProcess
      (shell "cd ../db && sqitch verify")
   verECode <- waitForProcess verPH
   print verECode

   wsProc@(_, _, _, wsPH) <- createProcess $
      (shell "postgrest postgres://andrew:@localhost:5432/postgrest_demo -a postgrest_anonymous -s postgrest")
         { std_in  = UseHandle stdin
         , std_out = UseHandle stdout
         , std_err = UseHandle stderr
         }

   threadDelay 500000

   am <- Map.newIO
   fs <- Set.newIO
   return $ TestEnv pgConn wsProc am fs

freeEnv :: Bool -> TestEnv -> IO ()
freeEnv revert (TestEnv pgConn (_, _, _, wsPH) amap fset) = do
   terminateProcess wsPH

   when revert $ do
      revProc@(_, _, _, revPH) <- createProcess
         (shell "cd ../db && sqitch revert -y")
      revECode <- waitForProcess revPH
      print revECode

      lst <- atomically $ ListT.toList $ Map.stream amap
      mapM_ (execute_ pgConn) $ (\(_, a) -> fromString $ "DROP ROLE " ++ T.unpack a ++ ";") <$> lst

encodeRole :: Account -> JSON
encodeRole account =
   let c = def { unregisteredClaims = Data.Map.fromList [("role", toJSON account)] }
    in encodeSigned HS256 (secret "secret") c

buildRoleHeader :: Account -> [ByteString]
buildRoleHeader account =
   let tok = encodeRole account
    in [ T.encodeUtf8 $ T.concat ["Bearer ", tok ] ]

requireRole :: Text -> TestEnv -> STM Account
requireRole rolname env = do
   v <- Map.lookup rolname (env ^. accountMap)
   case v of
      Nothing -> retry
      Just  r -> return r

requireFlag :: Flag -> TestEnv -> STM ()
requireFlag flg env = do
   f <- Set.lookup flg (env ^. flagSet)
   unless f retry

--

tests :: IO TestEnv -> TestTree
tests getEnv = testGroup "HTTP Tests"
   [ testCase "Register User: andrew" $ caseRegisterAndrew getEnv
   , testCase "Register User: joe" $ caseRegisterJoe getEnv
   , testCase "Register User: scott" $ caseRegisterScott getEnv
   , testCase "Get Account info as Anon" $ caseUnauthenticatedAccount getEnv
   , testCase "Get Account for andrew" $ caseGetAccountAndrew getEnv
   , testCase "Get Account for joe" $ caseGetAccountJoe getEnv
   , testCase "Add Log entries for Joe" $ caseLogThreeEntriesJoe getEnv
   , testCase "Add Log entries for Scott" $ caseLogThreeEntriesScott getEnv
   , testCase "Get Log entries for Joe" $ caseGetLogsJoe getEnv
   , testCase "Get Log entries for Scott" $ caseGetLogsScott getEnv
   ]

caseRegisterAndrew :: IO TestEnv -> IO ()
caseRegisterAndrew getEnv = do
   env <- getEnv
   res <- post "http://localhost:3000/rpc/register_account"
      (RegisterPostReq "andrew.rademacher@smrxt.com" "Andrew Rademacher" "12345")
   case res ^? responseBody . nth 0 . _JSON . (registerAccount :: Lens' RegisterPostRes Text) of
      Nothing -> assertFailure "Response did not contain account name."
      Just  a -> atomically $ Map.insert a "andrew" (env ^. accountMap)

caseRegisterJoe :: IO TestEnv -> IO ()
caseRegisterJoe getEnv = do
   env <- getEnv
   res <- post "http://localhost:3000/rpc/register_account"
      (RegisterPostReq "joe.andaverde@smrxt.com" "Joe Andaverde" "12345")
   case res ^? responseBody . nth 0 . _JSON . (registerAccount :: Lens' RegisterPostRes Text) of
      Nothing -> assertFailure "Response did not contain account name."
      Just  a -> atomically $ Map.insert a "joe" (env ^. accountMap)

caseRegisterScott :: IO TestEnv -> IO ()
caseRegisterScott getEnv = do
   env <- getEnv
   res <- post "http://localhost:3000/rpc/register_account"
      (RegisterPostReq "scott.smerchek@smrxt.com" "Scott Smerchek" "12345")
   case res ^? responseBody . nth 0 . _JSON . (registerAccount :: Lens' RegisterPostRes Text) of
      Nothing -> assertFailure "Response did not contain account name."
      Just  a -> atomically $ Map.insert a "scott" (env ^. accountMap)


caseUnauthenticatedAccount :: IO TestEnv -> IO ()
caseUnauthenticatedAccount getEnv = do
   env <- getEnv
   res <- flip getWith "http://localhost:3000/account"
            $ defaults & checkStatus ?~ (\_ _ _ -> Nothing)
   case res ^? responseBody . _JSON . (code :: Lens' PostgrestError Text) of
      Nothing -> assertFailure "Error was not produced."
      Just  a -> "42501" @=? a

caseGetAccountAndrew :: IO TestEnv -> IO ()
caseGetAccountAndrew getEnv = do
   env <- getEnv
   rol <- atomically $ do
      v <- Map.lookup "andrew" (env ^. accountMap)
      case v of
         Nothing -> retry
         Just  r -> return r
   res <- flip getWith "http://localhost:3000/account"
            $ defaults & header "Authorization" .~ buildRoleHeader rol
   case res ^? responseBody . nth 0 . key "name" . _String of
      Nothing -> assertFailure "Response did not contain account holder name."
      Just  n -> "Andrew Rademacher" @=? n

caseGetAccountJoe :: IO TestEnv -> IO ()
caseGetAccountJoe getEnv = do
   env <- getEnv
   rol <- atomically $ do
      v <- Map.lookup "joe" (env ^. accountMap)
      case v of
         Nothing -> retry
         Just  r -> return r
   res <- flip getWith "http://localhost:3000/account"
            $ defaults & header "Authorization" .~ buildRoleHeader rol
   case res ^? responseBody . nth 0 . key "name" . _String of
      Nothing -> assertFailure "Response did not contain account holder name."
      Just  n -> "Joe Andaverde" @=? n

caseLogThreeEntriesJoe :: IO TestEnv -> IO ()
caseLogThreeEntriesJoe getEnv = do
   env <- getEnv
   rol <- atomically $ requireRole "joe" env
   _   <- postWith
            (defaults & header "Authorization" .~ buildRoleHeader rol)
            "http://localhost:3000/private_log"
            (object [ "body" .= ("This is Joe's first entry."::Text) ])
   _   <- postWith (defaults & header "Authorization" .~ buildRoleHeader rol)
            "http://localhost:3000/private_log"
            (object [ "body" .= ("This is Joe's second entry."::Text) ])
   _   <- postWith (defaults & header "Authorization" .~ buildRoleHeader rol)
            "http://localhost:3000/private_log"
            (object [ "body" .= ("This is Joe's third entry."::Text) ])
   atomically $ Set.insert FlagLogEntriesJoe (env ^. flagSet)

caseLogThreeEntriesScott :: IO TestEnv -> IO ()
caseLogThreeEntriesScott getEnv = do
   env <- getEnv
   rol <- atomically $ requireRole "scott" env
   _   <- postWith
            (defaults & header "Authorization" .~ buildRoleHeader rol)
            "http://localhost:3000/private_log"
            (object [ "body" .= ("This is Scott's first entry."::Text) ])
   _   <- postWith (defaults & header "Authorization" .~ buildRoleHeader rol)
            "http://localhost:3000/private_log"
            (object [ "body" .= ("This is Scott's second entry."::Text) ])
   _   <- postWith (defaults & header "Authorization" .~ buildRoleHeader rol)
            "http://localhost:3000/private_log"
            (object [ "body" .= ("This is Scott's third entry."::Text) ])
   atomically $ Set.insert FlagLogEntriesScott (env ^. flagSet)

caseGetLogsJoe :: IO TestEnv -> IO ()
caseGetLogsJoe getEnv = do
   env <- getEnv
   rol <- atomically $ do
      requireFlag FlagLogEntriesJoe env
      requireFlag FlagLogEntriesScott env
      requireRole "joe" env
   res <- flip getWith "http://localhost:3000/private_log"
            $ defaults & header "Authorization" .~ buildRoleHeader rol
   let entries = res ^.. responseBody . values . key "body" . _String
   3 @=? length entries
   True @=? foldl (\b e -> b && e =~ ("Joe's"::Text)) True entries

caseGetLogsScott :: IO TestEnv -> IO ()
caseGetLogsScott getEnv = do
   env <- getEnv
   rol <- atomically $ do
      requireFlag FlagLogEntriesJoe env
      requireFlag FlagLogEntriesScott env
      requireRole "scott" env
   res <- flip getWith "http://localhost:3000/private_log"
            $ defaults & header "Authorization" .~ buildRoleHeader rol
   let entries = res ^.. responseBody . values . key "body" . _String
   3 @=? length entries
   True @=? foldl (\b e -> b && e =~ ("Scott's"::Text)) True entries
