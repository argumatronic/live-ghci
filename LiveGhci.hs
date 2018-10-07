{-# LANGUAGE OverloadedStrings #-}

module Main where

import qualified System.FSNotify as FSNotify
import System.IO (Handle, hFlush, hWaitForInput, hReady, hGetChar, hSetBuffering, hPutStrLn, BufferMode(..))
import System.Process as Process
import qualified System.Timeout
import Control.Concurrent (threadDelay)
import Control.Concurrent.Chan
import Control.Monad.State
import qualified Data.Map as Map
import Data.Char (isUpper)
import Data.List (isSuffixOf, isInfixOf, intercalate, drop, take)
import Data.List.Split (splitOn)
import Control.Category ((>>>)) -- Reversed composition


type GHCIHandles    = (Handle, Handle, Handle, Process.ProcessHandle)
type GHCIHandlesMap = Map.Map String GHCIHandles


timeoutMilliseconds = 300


(|>) = flip ($)


takeLast :: Int -> [a] -> [a]
takeLast n list = drop (length list - n) list


-- Returns (lines, newLineStr)
splitIntoLines :: String -> ([String], String)
splitIntoLines str =
    (lines, newLineStr)
    where
        lines = [str] >>= splitOn "\r\n" >>= splitOn "\r" >>= splitOn "\n"
        newLineStr =
            case lines of
                firstLine:_ ->
                    case drop (length firstLine) str of
                        '\r':'\n':_   -> "\r\n"
                        newLineChar:_ -> [newLineChar]
                        _             -> "\n"
                _ -> "\n"


isHaskellFileChange :: FSNotify.Event -> Bool
isHaskellFileChange (FSNotify.Modified filePath _ False) = ".hs" `isSuffixOf` filePath
isHaskellFileChange _                                    = False


startGhci :: FilePath -> IO GHCIHandles
startGhci filePath = do
    let ghciCommand = "ghci " ++ filePath
    putStrLn $ "Starting GHCi: " ++ ghciCommand
    (Just ghciIn, Just ghciOut, Just ghciErr, hGhci) <- Process.createProcess (Process.shell ghciCommand){ std_in = Process.CreatePipe, std_out = Process.CreatePipe, std_err = Process.CreatePipe }
    hSetBuffering ghciOut NoBuffering
    hSetBuffering ghciErr NoBuffering
    return (ghciIn, ghciOut, ghciErr, hGhci)


readDataAvailable :: Handle -> IO String
readDataAvailable handle = readDataAvailableReversed handle >>= (return . reverse)


clearBuffer :: Handle -> IO ()
clearBuffer handle = readDataAvailableReversed handle >> return ()


readDataAvailableReversed :: Handle -> IO String
readDataAvailableReversed handle = do
    isAnyInputAvailable <- hReady handle
    if isAnyInputAvailable then do
        char <- hGetChar handle
        rest <- readDataAvailableReversed handle
        return (char:rest)
    else
        return ""


readDataUntilPause :: Handle -> IO String
readDataUntilPause handle = do
    isAnyInputAvailable <- hWaitForInput handle 50
    if isAnyInputAvailable then do
        someData <- readDataAvailable handle
        moreData <- readDataUntilPause handle
        return (someData ++ moreData)
    else
        return ""


isGhciPrompt :: String -> Bool
isGhciPrompt str = takeLast 2 str == "> " && map isUpper (take 1 str) == [True]


squishAndChopOffPrompt :: String -> String
squishAndChopOffPrompt str =
    let (lines, _) = splitIntoLines str in
    lines
    |> filter (not . isGhciPrompt)
    |> map (words >>> unwords)
    |> unwords


ghciRunLine :: GHCIHandles -> String -> IO String
ghciRunLine (ghciIn, ghciOut, ghciErr, hGhci) line = do
    clearBuffer ghciOut
    clearBuffer ghciErr
    maybeResult <- System.Timeout.timeout (timeoutMilliseconds * 100) $ do
        hPutStrLn ghciIn line
        hFlush ghciIn
        putStrLn line
        _ <- hWaitForInput ghciOut timeoutMilliseconds
        stdOut <- readDataUntilPause ghciOut
        stdErr <- readDataUntilPause ghciErr
        putStrLn stdErr
        putStrLn stdOut
        return (squishAndChopOffPrompt stdErr ++ squishAndChopOffPrompt stdOut)
    case maybeResult of
        Just result -> return result
        Nothing -> do
            -- Tell GHCi to abort the computation
            Process.interruptProcessGroupOf hGhci
            threadDelay (10 * 100) -- 10ms
            clearBuffer ghciOut
            clearBuffer ghciErr
            return $ "Computation did not finish within " ++ show timeoutMilliseconds ++ " milliseconds. Infinite loop?"

-- 5 * 5 ==>

-- Returns whatever :reload says
startOrReloadGhciFor :: FilePath -> StateT GHCIHandlesMap IO String
startOrReloadGhciFor filePath = do
    ghciHandles <- ensureGhciRunningFor filePath
    lift $ ghciRunLine ghciHandles ":reload"


ensureGhciRunningFor :: FilePath -> StateT GHCIHandlesMap IO GHCIHandles
ensureGhciRunningFor filePath = do
    ghciHandlesMap <- get
    case Map.lookup filePath ghciHandlesMap of
        Just ghciHandles@(ghciIn, ghciOut, ghciErr, hGhci) -> do
            maybeExitCode <- lift $ Process.getProcessExitCode hGhci
            case maybeExitCode of
                Just _ -> do
                    ghciHandles <- lift $ startGhci filePath
                    put $ Map.insert filePath ghciHandles ghciHandlesMap
                    return ghciHandles

                Nothing ->
                    return ghciHandles

        Nothing -> do
            ghciHandles <- lift $ startGhci filePath
            put $ Map.insert filePath ghciHandles ghciHandlesMap
            return ghciHandles



perhapsRefreshGhciExpression :: FilePath -> Maybe String -> String -> StateT GHCIHandlesMap IO String
perhapsRefreshGhciExpression filePath maybeUniversalMessage line =
    case line of
        '-':'-':restOfLine ->
            case splitOn "==>" restOfLine of
                lhs:_ ->
                    case maybeUniversalMessage of
                        Just universalMessage -> return $ concat ["--", lhs, "==> ", universalMessage]
                        Nothing -> do
                            -- Restart GHCi if...it crashed??? interruptProcessGroupOf above should not quite GHCi completely...
                            ghciHandles <- ensureGhciRunningFor filePath
                            ghciResult <- lift $ ghciRunLine ghciHandles lhs
                            return $ concat ["--", lhs, "==> ", ghciResult]

                _ ->
                    return line

        _ ->
            return line


-- Look for each ==>, evaluate its LHS, replace its RHS
refreshGhciExpressions :: FilePath -> StateT GHCIHandlesMap IO ()
refreshGhciExpressions filePath = do
    lift $ putStrLn ("Refreshing GHCi expressions in " ++ filePath)
    source <- lift $ readFile filePath
    lift $ putStrLn source -- In case of some kind of uber-failure that destroys a file.
    reloadMessage <- startOrReloadGhciFor filePath
    let maybeUniversalMessage = if "Failed, " `isInfixOf` reloadMessage then Just "Compile failed." else Nothing
    let (lines, newLineStr) = splitIntoLines source
    refreshedLines <- mapM (perhapsRefreshGhciExpression filePath maybeUniversalMessage) lines
    lift $ writeFile filePath (intercalate newLineStr refreshedLines)


-- Loops forever!
-- Cache ghciHandles to avoid GHCi startup time
handleHaskellFileChangeEvents :: GHCIHandlesMap -> Chan FSNotify.Event -> IO ()
handleHaskellFileChangeEvents ghciHandlesMap channel = do
    fsNotifyEvent <- readChan channel
    case fsNotifyEvent of
        FSNotify.Modified filePath _ False -> do
            ((), newGhciHandlesMap) <- runStateT (refreshGhciExpressions filePath) ghciHandlesMap
            handleHaskellFileChangeEvents newGhciHandlesMap channel

        _ ->
            handleHaskellFileChangeEvents ghciHandlesMap channel

main :: IO ()
main =
    FSNotify.withManager $ \watchManager -> do
        channel <- newChan
        _       <- FSNotify.watchTreeChan watchManager "." isHaskellFileChange channel
        handleHaskellFileChangeEvents Map.empty channel