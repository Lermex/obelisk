{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE MultiWayIf #-}
{-# LANGUAGE OverloadedStrings #-}
-- | Provides a logging handler that facilitates safe ouputting to terminal using MVar based locking.
-- | Spinner.hs and Process.hs work on this guarantee.
module Obelisk.CLI.Logging
  ( Severity (Error, Warning, Notice, Debug)
  , LoggingConfig (..)
  , Output (..)
  , failWith
  , putLog
  , putLogRaw
  , handleLog
  ) where

import Control.Concurrent.MVar (MVar, modifyMVar_)
import Control.Monad (void, when)
import Control.Monad.Catch (MonadMask, bracket_)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Reader (MonadIO)
import Data.Text (Text)
import qualified Data.Text.IO as T
import System.Console.ANSI (Color (Red, White, Yellow), ColorIntensity (Vivid),
                            ConsoleIntensity (FaintIntensity), ConsoleLayer (Foreground),
                            SGR (Reset, SetColor, SetConsoleIntensity), clearLine, setSGR)
import System.Exit (ExitCode (ExitFailure), exitWith)
import System.IO (hFlush, stdout)

import Control.Monad.Log (MonadLog, Severity (..), WithSeverity (..), logMessage)

data LoggingConfig = LoggingConfig
  { _loggingConfig_level :: Severity
  , _loggingConfig_noColor :: Bool  -- Disallow coloured output
  , _loggingConfig_lock :: MVar Bool  -- Whether the last message was an Overwrite output
  }

data Output
  = Output_Log (WithSeverity Text)  -- Regular logging message (with colors and newlines)
  | Output_LogRaw (WithSeverity Text)  -- Like `Output_Log` but without the implicit newline added.
  | Output_Overwrite [String]  -- Overwrites the current line (i.e. \r followed by `putStr`)
  | Output_ClearLine  -- Clears the line
  deriving (Eq, Show, Ord)

isOverwrite :: Output -> Bool
isOverwrite = \case
  Output_Overwrite _ -> True
  _ -> False

getSeverity :: Output -> Maybe Severity
getSeverity = \case
  Output_Log (WithSeverity sev _) -> Just sev
  Output_LogRaw (WithSeverity sev _) -> Just sev
  _ -> Nothing

handleLog :: MonadIO m => LoggingConfig -> Output -> m ()
handleLog (LoggingConfig level noColor lock) output = do
  liftIO $ modifyMVar_ lock $ \wasOverwriting -> do
    case getSeverity output of
      Nothing -> handleLog' noColor output
      Just sev -> case sev > level of
        True -> return wasOverwriting  -- Discard if sev is above configured log level
        False -> do
          -- If the last output was an overwrite (with cursor on same line), ...
          when wasOverwriting $
            void $ handleLog' noColor Output_ClearLine  -- first clear it,
          handleLog' noColor output  -- then, actually write the msg.

handleLog' :: MonadIO m => Bool -> Output -> m Bool
handleLog' noColor output = do
  case output of
    Output_Log m -> liftIO $ do
      writeLogWith T.putStrLn noColor m
    Output_LogRaw m -> liftIO $ do
      writeLogWith T.putStr noColor m
      hFlush stdout  -- Explicitly flush, as there is no newline
    Output_Overwrite xs -> liftIO $ do
      mapM_ putStr $ "\r" : xs
      hFlush stdout
    Output_ClearLine -> liftIO $ do
      -- Go to the first column and clear the whole line
      putStr "\r"
      clearLine
      hFlush stdout
  return $ isOverwrite output

-- | Safely log a message to the console. This is what we should use.
putLog :: MonadLog Output m => Severity -> Text -> m ()
putLog sev = logMessage . Output_Log . WithSeverity sev

-- | Like `putLog` but without the implicit newline added.
putLogRaw :: MonadLog Output m => Severity -> Text -> m ()
putLogRaw sev = logMessage . Output_LogRaw . WithSeverity sev

-- | Like `putLog Error` but also abrupts the program.
failWith :: (MonadIO m, MonadLog Output m) => Text -> m a
failWith s = do
  putLog Alert s
  liftIO $ exitWith $ ExitFailure 2

-- | Write log to stdout, with colors (unless `noColor`)
writeLogWith :: (MonadIO m, MonadMask m) => (Text -> IO ()) -> Bool -> WithSeverity Text -> m ()
writeLogWith f noColor (WithSeverity severity s) = case sevColor severity of
  Just setColor -> bracket_ setColor reset $ liftIO (T.putStr s)
  Nothing -> liftIO $ f s
  where
    -- We must reset *before* outputting the newline (if any), otherwise the cursor won't be reset.
    reset = liftIO $ setSGR [Reset] >> f ""
    sevColor sev = if
      | noColor -> Nothing
      | sev <= Error -> Just $ liftIO $ setSGR [SetColor Foreground Vivid Red]
      | sev <= Warning -> Just $ liftIO $ setSGR [SetColor Foreground Vivid Yellow]
      | sev >= Debug -> Just $ liftIO $ setSGR [SetColor Foreground Vivid White, SetConsoleIntensity FaintIntensity]
      | otherwise -> Nothing