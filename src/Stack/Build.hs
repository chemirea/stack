{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE CPP #-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE ViewPatterns #-}

-- | Build project(s).

module Stack.Build
  (build
  ,clean)
  where

import           Control.Applicative
import           Control.Concurrent (getNumCapabilities, forkIO)
import           Control.Concurrent.Execute
import           Control.Concurrent.MVar.Lifted
import           Control.Concurrent.STM
import           Control.Exception.Enclosed (handleIO, tryIO)
import           Control.Exception.Lifted
import           Control.Monad
import           Control.Monad.Catch (MonadCatch, MonadMask)
import           Control.Monad.IO.Class
import           Control.Monad.Logger
import           Control.Monad.Reader (MonadReader, asks, ask, runReaderT)
import           Control.Monad.State.Strict
import           Control.Monad.Trans.Control (liftBaseWith)
import           Control.Monad.Trans.Resource
import           Control.Monad.Writer
import           Data.Binary (Binary)
import qualified Data.Binary as Binary
import           Data.ByteString (ByteString)
import qualified Data.ByteString as S
import qualified Data.ByteString.Char8 as S8
import qualified Data.ByteString.Lazy as L
import           Data.Char (isSpace)
import           Data.Conduit
import qualified Data.Conduit.Binary as CB
import qualified Data.Conduit.List as CL
import           Data.Either
import           Data.Function
import           Data.List
import           Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import qualified Data.Map.Strict as Map
import           Data.Maybe
import           Data.Set (Set)
import qualified Data.Set as S
import qualified Data.Set as Set
import qualified Data.Streaming.Process as Process
import           Data.Streaming.Process hiding (env,callProcess)
import           Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import           Data.Time.Calendar
import           Data.Time.Clock
import           Data.Typeable (Typeable)
import           Distribution.Package (Dependency (..))
import           Distribution.System (Platform (Platform), OS (Windows))
import           Distribution.Text (display)
import           Distribution.Version (intersectVersionRanges, anyVersion)
import           GHC.Generics
import           Network.HTTP.Client.Conduit (HasHttpManager)
import           Path
import           Path.IO
import           Prelude hiding (FilePath, writeFile)
import           Stack.Build.Types
import           Stack.BuildPlan
import           Stack.Constants
import           Stack.Fetch as Fetch
import           Stack.GhcPkg
import           Stack.Package
import           Stack.PackageDump
import           Stack.Types
import           Stack.Types.Internal
import           System.Directory hiding (findFiles, findExecutable)
import           System.Exit (ExitCode (ExitSuccess))
import           System.IO
import           System.IO.Error
import           System.IO.Temp (withSystemTempDirectory)
import           System.Process.Internals (createProcess_)
import           System.Process.Read

----------------------------------------------
-- Exceptions
data ConstructPlanException
    = SnapshotPackageDependsOnLocal PackageName PackageIdentifier
    -- ^ Recommend adding to extra-deps
    | DependencyCycleDetected [PackageName]
    | DependencyPlanFailures PackageName (Set PackageName)
    | UnknownPackage PackageName
    -- ^ Recommend adding to extra-deps, give a helpful version number?
    | VersionOutsideRange PackageName PackageIdentifier VersionRange
    | Couldn'tMakePlanForWanted (Set PackageName)
    deriving (Typeable, Eq)

instance Show ConstructPlanException where
  show e =
    let details = case e of
         (SnapshotPackageDependsOnLocal pName pIdentifier) ->
           "Exception: Stack.Build.SnapshotPackageDependsOnLocal\n" ++
           "  Local package " ++ show pIdentifier ++ " is a dependency of snapshot package " ++ show pName ++ ".\n" ++
           "  Snapshot packages cannot depend on local packages,\n " ++
           "  should you add " ++ show pName ++ " to [extra-deps] in the project's stack.yaml?"
         (DependencyCycleDetected pNames) ->
           "Exception: Stack.Build.DependencyCycle\n" ++
           "  While checking call stack,\n" ++
           "  dependency cycle detected in packages:" ++ indent (appendLines pNames)
         (DependencyPlanFailures pName (S.toList -> pDeps)) ->
           "Exception: Stack.Build.DependencyPlanFailures\n" ++
           "  Failure when adding dependencies:" ++ doubleIndent (appendLines pDeps) ++ "\n" ++
           "  needed for package: " ++ show pName
         (UnknownPackage pName) ->
             "Exception: Stack.Build.UnknownPackage\n" ++
             "  While attempting to add dependency,\n" ++
             "  Could not find package " ++ show pName  ++ "in known packages"
         (VersionOutsideRange pName pIdentifier versionRange) ->
             "Exception: Stack.Build.VersionOutsideRange\n" ++
             "  While adding dependency for package " ++ show pName ++ ",\n" ++
             "  " ++ dropQuotes (show pIdentifier) ++ " was found to be outside its allowed version range.\n" ++
             "  Allowed version range is " ++ display versionRange ++ ",\n" ++
             "  should you correct the version range for " ++ dropQuotes (show pIdentifier) ++ ", found in [extra-deps] in the project's stack.yaml?"
         (Couldn'tMakePlanForWanted (S.toList -> lpSet)) ->
            "Exception: Stack.Build.Couldn'tMakePlanForWanted\n" ++
            "  Couldn't make a build plan while adding local packages:" ++
            doubleIndent (appendLines lpSet)
    in indent details
     where
      appendLines = foldr (\pName-> (++) ("\n" ++ show pName)) ""
      indent = dropWhileEnd isSpace . unlines . fmap (\line -> "  " ++ line) . lines
      dropQuotes = filter ((/=) '\"')
      doubleIndent = indent . indent

newtype ConstructPlanExceptions = ConstructPlanExceptions [ConstructPlanException]
    deriving (Typeable)
instance Exception ConstructPlanExceptions

instance Show ConstructPlanExceptions where
  show (ConstructPlanExceptions exceptions) =
    "Exception: Stack.Build.ConstuctPlanExceptions\n" ++
    "While constructing the BuildPlan the following exceptions were encountered:" ++
    appendExceptions (removeDuplicates exceptions)
     where
         appendExceptions = foldr (\e -> (++) ("\n\n--" ++ show e)) ""
         removeDuplicates = nub
 -- Supressing duplicate output

data UnpackedPackageHasWrongName = UnpackedPackageHasWrongName PackageIdentifier PackageName
    deriving (Show, Typeable)
instance Exception UnpackedPackageHasWrongName

data TestSuiteFailure2 = TestSuiteFailure2 PackageIdentifier (Map Text (Maybe ExitCode)) (Maybe FilePath)
    deriving (Show, Typeable)
instance Exception TestSuiteFailure2

data CabalExitedUnsuccessfully = CabalExitedUnsuccessfully
    ExitCode
    PackageIdentifier
    (Path Abs File)
-- ^ cabal Executable
    [String]
-- ^ cabal arguments
    (Maybe FilePath)
-- ^ logfiles location
    S.ByteString
-- ^ log contents
    deriving (Typeable)
instance Exception CabalExitedUnsuccessfully

instance Show CabalExitedUnsuccessfully where
  show (CabalExitedUnsuccessfully exitCode taskProvides execName fullArgs logFiles _) =
    let fullCmd = (dropQuotes (show execName) ++ " " ++ (unwords fullArgs))
        logLocations = maybe "" (\fp -> "\n    Logs have been written to: " ++ show fp) logFiles
    in "\n--  Exception: CabalExitedUnsuccessfully\n" ++
       "    While building package " ++ dropQuotes (show taskProvides) ++ " using:\n" ++
       "      " ++ fullCmd ++ "\n" ++
       "    Process exited with code: " ++ show exitCode ++
       logLocations
     where
      -- appendLines = foldr (\pName-> (++) ("\n" ++ show pName)) ""
      -- indent = dropWhileEnd isSpace . unlines . fmap (\line -> "  " ++ line) . lines
      dropQuotes = filter ('\"' /=)
      -- doubleIndent = indent . indent


----------------------------------------------

-- | Directory containing files to mark an executable as installed
exeInstalledDir :: M env m => Location -> m (Path Abs Dir)
exeInstalledDir Snap = (</> $(mkRelDir "installed-packages")) `liftM` installationRootDeps
exeInstalledDir Local = (</> $(mkRelDir "installed-packages")) `liftM` installationRootLocal

-- | Get all of the installed executables
getInstalledExes :: M env m => Location -> m [PackageIdentifier]
getInstalledExes loc = do
    dir <- exeInstalledDir loc
    files <- liftIO $ handleIO (const $ return []) $ getDirectoryContents $ toFilePath dir
    return $ mapMaybe parsePackageIdentifierFromString files

-- | Mark the given executable as installed
markExeInstalled :: M env m => Location -> PackageIdentifier -> m ()
markExeInstalled loc ident = do
    dir <- exeInstalledDir loc
    liftIO $ createDirectoryIfMissing True $ toFilePath dir
    ident' <- parseRelFile $ packageIdentifierString ident
    let fp = toFilePath $ dir </> ident'
    -- TODO consideration for the future: list all of the executables
    -- installed, and invalidate this file in getInstalledExes if they no
    -- longer exist
    liftIO $ writeFile fp "Installed"

{- EKB TODO: doc generation for stack-doc-server
#ifndef mingw32_HOST_OS
import           System.Posix.Files (createSymbolicLink,removeLink)
#endif
--}
data Installed = Library GhcPkgId | Executable
    deriving (Show, Eq, Ord)

data Location = Snap | Local
    deriving (Show, Eq)

type M env m = (MonadIO m,MonadReader env m,HasHttpManager env,HasBuildConfig env,MonadLogger m,MonadBaseControl IO m,MonadCatch m,MonadMask m,HasLogLevel env)

type SourceMap = Map PackageName (Version, PackageSource)
data PackageSource
    = PSLocal LocalPackage
    | PSUpstream Location (Map FlagName Bool)
    | PSInstalledLib (Maybe Location) GhcPkgId -- ^ Nothing == Global
    | PSInstalledExe Location

-- | Returns the new SourceMap and all of the locally registered packages.
getInstalled :: M env m
             => EnvOverride
             -> Bool -- ^ profiling?
             -> SourceMap -- ^ does not contain any installed information
             -> m (SourceMap, Set GhcPkgId)
getInstalled menv profiling sourceMap1 = do
    snapDBPath <- packageDatabaseDeps
    localDBPath <- packageDatabaseLocal

    bconfig <- asks getBuildConfig

    mpcache <-
        if profiling
            then liftM Just $ loadProfilingCache $ configProfilingCache bconfig
            else return Nothing

    let loadDatabase' = loadDatabase menv mpcache
    (sourceMap2, localInstalled) <-
        loadDatabase' Nothing sourceMap1 >>=
        loadDatabase' (Just (Snap, snapDBPath)) . fst >>=
        loadDatabase' (Just (Local, localDBPath)) . fst

    case mpcache of
        Nothing -> return ()
        Just pcache -> saveProfilingCache (configProfilingCache bconfig) pcache

    -- Add in the executables that are installed, making sure to only trust a
    -- listed installation under the right circumstances (see below)
    let exesToSM loc = Map.unions . map (exeToSM loc)
        exeToSM loc (PackageIdentifier name version) =
            case Map.lookup name sourceMap2 of
                -- Doesn't conflict with anything, so that's OK
                Nothing -> m
                Just (version', ps)
                    -- Not the version we want, ignore it
                    | version /= version' -> Map.empty
                    | otherwise -> case ps of
                        -- Never mark locals as installed, instead do dirty
                        -- checking
                        PSLocal _ -> Map.empty

                        -- FIXME start recording build flags for installed
                        -- executables, and only count as installed if it
                        -- matches

                        PSUpstream loc' _flags | loc == loc' -> Map.empty

                        -- Passed all the tests, mark this as installed!
                        _ -> m
          where
            m = Map.singleton name (version, PSInstalledExe loc)
    exesSnap <- getInstalledExes Snap
    exesLocal <- getInstalledExes Local
    let sourceMap3 = Map.unions
            [ exesToSM Local exesLocal
            , exesToSM Snap exesSnap
            , sourceMap2
            ]

    return (sourceMap3, localInstalled)

data LocalPackage = LocalPackage
    { lpPackage :: Package
    , lpWanted :: Bool
    , lpDir :: !(Path Abs Dir)                  -- ^ Directory of the package.
    , lpCabalFile :: !(Path Abs File)           -- ^ The .cabal file
    , lpLastConfigOpts :: !(Maybe [Text])       -- ^ configure options used during last Setup.hs configure, if available
    , lpDirtyFiles :: !Bool                     -- ^ are there files that have changed since the last build?
    }
    deriving Show

loadLocals :: M env m
           => BuildOpts
           -> m [LocalPackage]
loadLocals bopts = do
    targets <- mapM parseTarget $
        case boptsTargets bopts of
            Left [] -> ["."]
            Left x -> x
            Right _ -> []
    (dirs, names0) <- case partitionEithers targets of
        ([], targets') -> return $ partitionEithers targets'
        (bad, _) -> throwM $ Couldn'tParseTargets bad
    let names = Set.fromList names0

    bconfig <- asks getBuildConfig
    lps <- forM (Set.toList $ bcPackages bconfig) $ \dir -> do
        cabalfp <- getCabalFileName dir
        name <- parsePackageNameFromFilePath cabalfp
        let wanted = isWanted dirs names dir name
        pkg <- readPackage
            PackageConfig
                { packageConfigEnableTests = wanted && boptsFinalAction bopts == DoTests
                , packageConfigEnableBenchmarks = wanted && boptsFinalAction bopts == DoBenchmarks
                , packageConfigFlags = localFlags bopts bconfig name
                , packageConfigGhcVersion = bcGhcVersion bconfig
                , packageConfigPlatform = configPlatform $ getConfig bconfig
                }
            cabalfp
        when (packageName pkg /= name) $ throwM
            $ MismatchedCabalName cabalfp (packageName pkg)
        mbuildCache <- tryGetBuildCache dir
        mconfigCache <- tryGetConfigCache dir
        fileModTimes <- getPackageFileModTimes pkg cabalfp
        return LocalPackage
            { lpPackage = pkg
            , lpWanted = wanted
            , lpLastConfigOpts =
                  fmap (map T.decodeUtf8 . configCacheOpts) mconfigCache
            , lpDirtyFiles =
                  maybe True
                        ((/= fileModTimes) . buildCacheTimes)
                        mbuildCache
            , lpCabalFile = cabalfp
            , lpDir = dir
            }

    let known = Set.fromList $ map (packageName . lpPackage) lps
        unknown = Set.difference names known
    unless (Set.null unknown) $ throwM $ UnknownTargets $ Set.toList unknown

    return lps
  where
    parseTarget t = do
        let s = T.unpack t
        isDir <- liftIO $ doesDirectoryExist s
        if isDir
            then liftM (Right . Left) $ liftIO (canonicalizePath s) >>= parseAbsDir
            else return $ case parsePackageNameFromString s of
                     Left _ -> Left t
                     Right pname -> Right $ Right pname
    isWanted dirs names dir name =
        name `Set.member` names ||
        any (`isParentOf` dir) dirs ||
        any (== dir) dirs

-- | Stored on disk to know whether the flags have changed or any
-- files have changed.
data BuildCache = BuildCache
    { buildCacheTimes :: !(Map FilePath ModTime)
      -- ^ Modification times of files.
    }
    deriving (Generic,Eq)
instance Binary BuildCache

-- | Stored on disk to know whether the flags have changed or any
-- files have changed.
data ConfigCache = ConfigCache
    { configCacheOpts :: ![ByteString]
      -- ^ All options used for this package.
    }
    deriving (Generic,Eq)
instance Binary ConfigCache

-- | Used for storage and comparison.
newtype ModTime = ModTime (Integer,Rational)
  deriving (Ord,Show,Generic,Eq)
instance Binary ModTime

-- | One-way conversion to serialized time.
modTime :: UTCTime -> ModTime
modTime x =
    ModTime
        ( toModifiedJulianDay
              (utctDay x)
        , toRational
              (utctDayTime x))

-- | Try to read the dirtiness cache for the given package directory.
tryGetBuildCache :: (M env m)
                 => Path Abs Dir -> m (Maybe BuildCache)
tryGetBuildCache = tryGetCache buildCacheFile

-- | Try to read the dirtiness cache for the given package directory.
tryGetConfigCache :: (M env m)
                  => Path Abs Dir -> m (Maybe ConfigCache)
tryGetConfigCache = tryGetCache configCacheFile

-- | Try to load a cache.
tryGetCache :: (M env m,Binary a)
            => (PackageIdentifier -> Path Abs Dir -> m (Path Abs File))
            -> Path Abs Dir
            -> m (Maybe a)
tryGetCache get' dir = do
    menv <- getMinimalEnvOverride
    cabalPkgVer <- getCabalPkgVer menv
    fp <- get' cabalPkgVer dir
    liftIO
        (catch
             (fmap (decodeMaybe . L.fromStrict) (S.readFile (toFilePath fp)))
             (\e -> if isDoesNotExistError e
                       then return Nothing
                       else throwIO e))
  where decodeMaybe =
            either (const Nothing) (Just . thd) . Binary.decodeOrFail
          where thd (_,_,x) = x

-- | Write the dirtiness cache for this package's files.
writeBuildCache :: (M env m)
                => Path Abs Dir -> Map FilePath ModTime -> m ()
writeBuildCache dir times =
    writeCache
        dir
        buildCacheFile
        (BuildCache
         { buildCacheTimes = times
         })

-- | Write the dirtiness cache for this package's configuration.
writeConfigCache :: (M env m)
                => Path Abs Dir -> [Text] -> m ()
writeConfigCache dir opts =
    writeCache
        dir
        configCacheFile
        (ConfigCache
         { configCacheOpts = map T.encodeUtf8 opts
         })

-- | Delete the caches for the project.
deleteCaches :: (M env m)  => Path Abs Dir -> m ()
deleteCaches dir = do
    menv <- getMinimalEnvOverride
    cabalPkgVer <- getCabalPkgVer menv
    bfp <- buildCacheFile cabalPkgVer dir
    removeFileIfExists bfp
    cfp <- configCacheFile cabalPkgVer dir
    removeFileIfExists cfp

-- | Write to a cache.
writeCache :: (Binary a, M env m)
           => Path Abs Dir
           -> (PackageIdentifier -> Path Abs Dir -> m (Path Abs File))
           -> a
           -> m ()
writeCache dir get' content = do
    menv <- getMinimalEnvOverride
    cabalPkgVer <- getCabalPkgVer menv
    fp <- get' cabalPkgVer dir
    liftIO
        (L.writeFile
             (toFilePath fp)
             (Binary.encode content))

flagCacheFile :: (MonadIO m, MonadThrow m, MonadReader env m, HasBuildConfig env)
              => GhcPkgId
              -> m (Path Abs File)
flagCacheFile gid = do
    rel <- parseRelFile $ ghcPkgIdString gid
    dir <- flagCacheLocal
    return $ dir </> rel

-- | Loads the flag cache for the given installed extra-deps
tryGetFlagCache :: (MonadIO m, MonadThrow m, MonadReader env m, HasBuildConfig env)
                => GhcPkgId
                -> m (Maybe (Map FlagName Bool))
tryGetFlagCache gid = do
    file <- flagCacheFile gid
    eres <- liftIO $ tryIO $ Binary.decodeFileOrFail $ toFilePath file
    case eres of
        Right (Right x) -> return $ Just x
        _ -> return Nothing

writeFlagCache :: M env m => GhcPkgId -> Map FlagName Bool -> m ()
writeFlagCache gid flags = do
    file <- flagCacheFile gid
    liftIO $ do
        createDirectoryIfMissing True $ toFilePath $ parent file
        Binary.encodeFile (toFilePath file) flags

-- | Get the modified times of all known files in the package,
-- including the package's cabal file itself.
getPackageFileModTimes :: (MonadIO m, MonadLogger m, MonadThrow m, MonadCatch m)
                       => Package
                       -> Path Abs File -- ^ cabal file
                       -> m (Map FilePath ModTime)
getPackageFileModTimes pkg cabalfp = do
    files <- getPackageFiles (packageFiles pkg) cabalfp
    liftM (M.fromList . catMaybes)
        $ mapM getModTimeMaybe
        $ Set.toList files
  where
    getModTimeMaybe fp =
        liftIO
            (catch
                 (liftM
                      (Just . (toFilePath fp,) . modTime)
                      (getModificationTime (toFilePath fp)))
                 (\e ->
                       if isDoesNotExistError e
                           then return Nothing
                           else throw e))

data LoadHelper = LoadHelper
    { lhId :: !GhcPkgId
    , lhDeps :: ![GhcPkgId]
    , lhNew :: !Bool
    }

-- | Outputs both the modified SourceMap and the Set of all installed packages in this database
loadDatabase :: M env m
             => EnvOverride
             -> Maybe ProfilingCache -- ^ if Just, profiling is required
             -> Maybe (Location, Path Abs Dir) -- ^ package database, Nothing for global
             -> SourceMap
             -> m (SourceMap, Set GhcPkgId)
loadDatabase menv mpcache mdb sourceMap0 = do
    env <- ask
    let sinkDP = (case mpcache of
                    Just pcache -> addProfiling pcache
                    -- Just an optimization to avoid calculating the profiling
                    -- values when they aren't necessary
                    Nothing -> CL.map (\dp -> dp { dpProfiling = False }))
              =$ filterMC (flip runReaderT env . isAllowed)
              =$ CL.map dpToLH
              =$ CL.consume
        sinkGIDs = CL.map dpGhcPkgId =$ CL.consume
        sink = getZipSink $ (,)
            <$> ZipSink sinkDP
            <*> ZipSink sinkGIDs
    (lhs1, gids) <- ghcPkgDump menv (fmap snd mdb) $ conduitDumpPackage =$ sink
    let lhs2 = lhs1 ++ installed0
        lhs3 = pruneDeps
            (packageIdentifierName . ghcPkgIdPackageIdentifier)
            lhId
            lhDeps
            const
            lhs2
        sourceMap1 = Map.fromList
            $ map (\lh ->
                let gid = lhId lh
                    PackageIdentifier name version = ghcPkgIdPackageIdentifier gid
                 in (name, (version, PSInstalledLib (fmap fst mdb) gid)))
            $ filter lhNew
            $ Map.elems lhs3
        sourceMap2 = Map.union sourceMap1 sourceMap0
    return (sourceMap2, Set.fromList gids)
  where
    -- Get a list of all installed GhcPkgIds with their "dependencies". The
    -- dependencies are always an empty list, since we don't need anything to
    -- use an installed dependency
    installed0 = flip mapMaybe (Map.toList sourceMap0) $ \x ->
        case x of
            (_, (_, PSInstalledLib _ gid)) -> Just LoadHelper
                { lhId = gid
                , lhDeps = []
                , lhNew = False
                }
            _ -> Nothing

    dpToLH dp = LoadHelper
        { lhId = dpGhcPkgId dp
        , lhDeps = dpDepends dp
        , lhNew = True
        }

    isAllowed dp
        | isJust mpcache && not (dpProfiling dp) = return False
        | otherwise =
            case Map.lookup name sourceMap0 of
                Nothing -> return True
                Just (version', ps)
                  | version /= version' -> return False
                  | otherwise -> case ps of
                    -- Never trust an installed local, instead we do dirty
                    -- checking later when constructing the plan
                    --
                    -- TODO: This logic is faulty right now, and breaks in the
                    -- case where an extra-dep depends on a local package (such
                    -- as happens in the wai repo). This needs to be rethought
                    PSLocal _ -> return False

                    -- Shadow any installations in the global and snapshot
                    -- databases
                    PSUpstream Local _ | fmap fst mdb /= Just Local -> return False
                    PSUpstream Local flags -> do
                        -- Check that the flags for the installed package match
                        -- what we would use
                        cachedFlags <- tryGetFlagCache gid
                        case cachedFlags of
                            Just flags' | flags == flags' -> return True
                            _ -> return False

                    -- We trust that anything installed in the snapshot
                    PSUpstream Snap _ ->
                        case fmap fst mdb of
                            Just Local -> assert False $ return False
                            _ -> return True

                    -- And then above we just resolve the conflict
                    PSInstalledLib _ _ -> return True

                    -- Something's wrong if we think a package is
                    -- executable-only and it appears in a package datbase
                    PSInstalledExe _ -> assert False $ return False
      where
        gid = dpGhcPkgId dp
        PackageIdentifier name version = ghcPkgIdPackageIdentifier gid

filterMC :: Monad m => (a -> m Bool) -> Conduit a m a
filterMC p =
    loop
  where
    loop = await >>= maybe (return ()) (\x -> go x >> loop)
    go x = do
        b <- lift (p x)
        if b then yield x else return ()

data Task = Task
    { taskProvides :: !PackageIdentifier
    , taskRequiresMissing :: !(Set PackageIdentifier)
    , taskRequiresPresent :: !(Set GhcPkgId)
    , taskLocation :: !Location
    , taskType :: !TaskType
    }
    deriving Show

data TaskType = TTLocal LocalPackage NeededSteps
              | TTUpstream Package Location
    deriving Show

data S = S
    { callStack :: ![PackageName]
    , tasks :: !(Map PackageName Task)
    , failures :: ![ConstructPlanException]
    }

data AddDepRes
    = ADRToInstall PackageIdentifier Location
    | ADRFound GhcPkgId
    | ADRFoundExe
    deriving Show

data BaseConfigOpts = BaseConfigOpts
    { bcoSnapDB :: !(Path Abs Dir)
    , bcoLocalDB :: !(Path Abs Dir)
    , bcoSnapInstallRoot :: !(Path Abs Dir)
    , bcoLocalInstallRoot :: !(Path Abs Dir)
    , bcoLibProfiling :: !Bool
    , bcoExeProfiling :: !Bool
    , bcoFinalAction :: !FinalAction
    , bcoGhcOptions :: ![Text]
    }

configureOpts :: BaseConfigOpts
              -> Set GhcPkgId -- ^ dependencies
              -> Bool -- ^ wanted?
              -> Location
              -> Map FlagName Bool
              -> [Text]
configureOpts bco deps wanted loc flags = map T.pack $ concat
    [ ["--user", "--package-db=clear", "--package-db=global"]
    , map (("--package-db=" ++) . toFilePath) $ case loc of
        Snap -> [bcoSnapDB bco]
        Local -> [bcoSnapDB bco, bcoLocalDB bco]
    , depOptions
    , [ "--libdir=" ++ toFilePath (installRoot </> $(mkRelDir "lib"))
      , "--bindir=" ++ toFilePath (installRoot </> bindirSuffix)
      , "--datadir=" ++ toFilePath (installRoot </> $(mkRelDir "share"))
      , "--docdir=" ++ toFilePath (installRoot </> $(mkRelDir "doc"))
      ]
    , ["--enable-library-profiling" | bcoLibProfiling bco || bcoExeProfiling bco]
    , ["--enable-executable-profiling" | bcoLibProfiling bco]
    , ["--enable-tests" | wanted && bcoFinalAction bco == DoTests]
    , ["--enable-benchmarks" | wanted && bcoFinalAction bco == DoBenchmarks]
    , map (\(name,enabled) ->
                       "-f" <>
                       (if enabled
                           then ""
                           else "-") <>
                       flagNameString name)
                    (Map.toList flags)
    -- FIXME Chris: where does this come from now? , ["--ghc-options=-O2" | gconfigOptimize gconfig]
    , if wanted
        then concatMap (\x -> ["--ghc-options", T.unpack x]) (bcoGhcOptions bco)
        else []
    ]
  where
    installRoot =
        case loc of
            Snap -> bcoSnapInstallRoot bco
            Local -> bcoLocalInstallRoot bco

    depOptions = map toDepOption $ Set.toList deps

    {- TODO does this work with some versions of Cabal?
    toDepOption gid = T.pack $ concat
        [ "--dependency="
        , packageNameString $ packageIdentifierName $ ghcPkgIdPackageIdentifier gid
        , "="
        , ghcPkgIdString gid
        ]
    -}
    toDepOption gid = concat
        [ "--constraint="
        , packageNameString name
        , "=="
        , versionString version
        ]
      where
        PackageIdentifier name version = ghcPkgIdPackageIdentifier gid

data NeededSteps = AllSteps | SkipConfig | JustFinal
    deriving (Show, Eq)
data DirtyResult
    = Dirty NeededSteps
    | CleanLibrary GhcPkgId
    | CleanExecutable

data Plan = Plan
    { planTasks :: !(Map PackageName Task)
    , planUnregisterLocal :: !(Set GhcPkgId)
    }
constructPlan :: MonadThrow m
              => MiniBuildPlan
              -> BaseConfigOpts
              -> [LocalPackage]
              -> [PackageName] -- ^ additional packages that must be built
              -> Set GhcPkgId -- ^ locally registered
              -> (PackageName -> Version -> Map FlagName Bool -> m Package) -- ^ load upstream package
              -> SourceMap
              -> m Plan
constructPlan mbp baseConfigOpts locals extraToBuild locallyRegistered loadPackage sourceMap = do
    let s0 = S
            { callStack = []
            , tasks = M.empty
            , failures = []
            }
    ((), s) <- flip runStateT s0 $ do
        eres1 <- mapM addLocal $ filter lpWanted locals
        eres2 <- mapM
            -- TODO it's pretty ugly that we have to pass in the fake
            -- deps-command package name and anyVersion, would be nice to clean
            -- things up a bit
            (\name -> addDep $(mkPackageName "deps-command") Local name anyVersion)
            extraToBuild
        case partitionEithers $ eres1 ++ eres2 of
            ([], _) -> return ()
            (errs, _) -> addFailure $ Couldn'tMakePlanForWanted $ Set.fromList errs
    let toUnregisterLocal (PackageIdentifier name version)
            | Just task <- Map.lookup name (tasks s) =
                case taskType task of
                    -- If we're just going to be running the tests/benchmarks,
                    -- and the version is the same, do not unregister
                    TTLocal _ JustFinal -> version /= (packageIdentifierVersion $ taskProvides task)
                    _ -> True
            | otherwise =
                case Map.lookup name sourceMap of
                    Nothing -> False
                    Just (version', ps)
                        | version /= version' -> True
                        | otherwise -> case ps of
                            PSLocal _ -> False
                            PSUpstream Local _ -> False
                            PSUpstream Snap _ -> True
                            PSInstalledLib (Just Local) _ -> False
                            PSInstalledLib _ _ -> True
                            PSInstalledExe _ -> assert False False
    if null $ failures s
        then return Plan
            { planTasks = tasks s
            , planUnregisterLocal = Set.filter
                (toUnregisterLocal . ghcPkgIdPackageIdentifier)
                locallyRegistered
            }
        else throwM $ ConstructPlanExceptions $ failures s
  where
    addTask task = do
        modify $ \s -> s
            { tasks = Map.insert
                (packageIdentifierName $ taskProvides task)
                task
                (tasks s)
            }
        return $ Just $ ADRToInstall (taskProvides task) (taskLocation task)

    addFailure e = modify $ \s -> s { failures = e : failures s }
    checkCallStack name inner = do
        s <- get
        if name `elem` callStack s
            then do
                addFailure $ DependencyCycleDetected $ callStack s
                return $ Left name
            else do
                put s { callStack = name : callStack s }
                res <- inner
                s' <- get
                case callStack s' of
                    name':rest | name == name' -> do
                        put s' { callStack = rest }
                        return $ maybe (Left name) Right res
                    _ -> error $ "constructPlan invariant violated: call stack is corrupted: " ++ show (name, callStack s, callStack s')

    toolMap = getToolMap mbp
    toolToPackages (Dependency name _) =
        Map.fromList
      $ map (, anyVersion)
      $ maybe [] Set.toList
      $ Map.lookup (S8.pack . packageNameString . fromCabalPackageName $ name) toolMap
    packageDepsWithTools p = Map.unionsWith intersectVersionRanges
        $ packageDeps p
        : map toolToPackages (packageTools p)

    localMap = Map.fromListWith Set.union $ map
        (\gid -> (packageIdentifierName $ ghcPkgIdPackageIdentifier gid, Set.singleton gid))
        (Set.toList locallyRegistered)
    withDeps loc p isDirty mlastConfigOpts wanted mkTaskType = checkCallStack name $ do
        let deps = M.toList $ packageDepsWithTools p
        eadrs <- mapM (uncurry (addDep name loc)) deps
        let (errs, adrs) = partitionEithers eadrs
            missing = Set.fromList $ mapMaybe toMissing adrs
            present = Set.fromList $ mapMaybe toPresent adrs
            configOpts = configureOpts baseConfigOpts present wanted loc (packageFlags p)
            mlocalGID =
                case fmap Set.toList $ Map.lookup name localMap of
                    Just [gid] -> Just gid
                    _ -> Nothing
        let dres
                | not $ Set.null missing = Dirty AllSteps
                | loc /= Local = Dirty AllSteps
                | otherwise =
                    case mlastConfigOpts of
                        Nothing -> Dirty AllSteps
                        Just oldConfigOpts
                            | oldConfigOpts /= configOpts -> Dirty AllSteps
                            | isDirty -> Dirty SkipConfig

                            -- We want to make sure to run the final action
                            -- if this target is wanted. We should probably
                            -- add an extra flag to indicate "no need to
                            -- build".
                            | wanted && bcoFinalAction baseConfigOpts `elem`
                                [DoTests, DoBenchmarks] ->
                                    case mlocalGID of
                                        Just _ -> Dirty JustFinal
                                        Nothing -> Dirty SkipConfig

                            | not $ packageHasLibrary p -> CleanExecutable
                            | otherwise ->
                                case mlocalGID of
                                    Just gid -> CleanLibrary gid
                                    Nothing -> Dirty SkipConfig
        if null errs
            then
                case dres of
                    Dirty needConfig -> addTask Task
                        { taskProvides = PackageIdentifier name (packageVersion p)
                        , taskRequiresMissing = missing
                        , taskRequiresPresent = present
                        , taskLocation = loc
                        , taskType = mkTaskType needConfig
                        }
                    CleanLibrary gid -> return $ Just $ ADRFound gid
                    CleanExecutable -> return $ Just ADRFoundExe
            else do
                addFailure $ DependencyPlanFailures name $ Set.fromList errs
                return Nothing
      where
        name = packageName p

    addLocal lp = withDeps
        Local
        (lpPackage lp)
        (lpDirtyFiles lp)
        (lpLastConfigOpts lp)
        (lpWanted lp)
        (TTLocal lp)

    addUpstream loc name version flags = do
        p <- lift $ loadPackage name version flags
        let dirty = False -- upstream files are never dirty, since they are immutable
            mlastConfigOpts = Nothing -- FIXME think about this
            wanted = False
        withDeps
            loc
            p
            dirty
            mlastConfigOpts
            wanted
            (const $ TTUpstream p loc)

    addDep user userloc name range =
        case Map.lookup name sourceMap of
            Nothing -> do
                addFailure $ UnknownPackage name
                return $ Left name
            Just (version, ps)
                | version `withinRange` range -> case ps of
                    PSLocal lp -> allowLocal version $ addLocal lp
                    PSUpstream loc flags -> allowLocation (Just loc) version $ addUpstream loc name version flags
                    PSInstalledLib loc gid -> allowLocation loc version $ return $ Right $ ADRFound gid
                    PSInstalledExe loc -> allowLocation (Just loc) version $ return $ Right ADRFoundExe
                | otherwise -> do
                    addFailure $ VersionOutsideRange
                        user
                        (PackageIdentifier name version)
                        range
                    return $ Left name
      where
        allowLocation loc version inner =
            case loc of
                Just Local -> allowLocal version inner
                _ -> inner
        allowLocal version inner =
            case userloc of
                Local -> inner
                _ -> do
                    addFailure $ SnapshotPackageDependsOnLocal user
                        (PackageIdentifier name version)
                    return $ Left name

    toMissing (ADRToInstall pi' _) = Just pi'
    toMissing _ = Nothing

    toPresent (ADRFound gid) = Just gid
    toPresent _ = Nothing

-- | Build using Shake.
build :: M env m => BuildOpts -> m ()
build bopts = do
    menv <- getMinimalEnvOverride
    cabalPkgVer <- getCabalPkgVer menv

    bconfig <- asks getBuildConfig
    mbp0 <- case bcResolver bconfig of
        ResolverSnapshot snapName -> do
            $logDebug $ "Checking resolver: " <> renderSnapName snapName
            mbp <- loadMiniBuildPlan snapName
            return mbp
        ResolverGhc ghc -> return MiniBuildPlan
            { mbpGhcVersion = fromMajorVersion ghc
            , mbpPackages = M.empty
            }

    locals <- loadLocals bopts

    let shadowed = Set.fromList (map (packageName . lpPackage) locals)
                <> Map.keysSet (bcExtraDeps bconfig)
        (mbp, extraDeps0) = shadowMiniBuildPlan mbp0 shadowed

        -- Add the extra deps from the stack.yaml file to the deps grabbed from
        -- the snapshot
        extraDeps1 = Map.union
            (Map.map (\v -> (v, M.empty)) (bcExtraDeps bconfig))
            (Map.map (\mpi -> (mpiVersion mpi, mpiFlags mpi)) extraDeps0)

        -- Overwrite any flag settings with those from the config file
        extraDeps2 = Map.mapWithKey
            (\n (v, f) -> (v, PSUpstream Local $ fromMaybe f $ Map.lookup n $ bcFlags bconfig))
            extraDeps1

    let sourceMap1 = Map.unions
            [ Map.fromList $ flip map locals $ \lp ->
                let p = lpPackage lp
                 in (packageName p, (packageVersion p, PSLocal lp))
            , extraDeps2
            , flip fmap (mbpPackages mbp)
                $ \mpi -> (mpiVersion mpi, PSUpstream Snap $ mpiFlags mpi)
            ]

    (sourceMap2, locallyRegistered) <- getInstalled menv profiling sourceMap1

    snapDBPath <- packageDatabaseDeps
    localDBPath <- packageDatabaseLocal
    snapInstallRoot <- installationRootDeps
    localInstallRoot <- installationRootLocal
    let baseConfigOpts = BaseConfigOpts
            { bcoSnapDB = snapDBPath
            , bcoLocalDB = localDBPath
            , bcoSnapInstallRoot = snapInstallRoot
            , bcoLocalInstallRoot = localInstallRoot
            , bcoLibProfiling = boptsLibProfile bopts
            , bcoExeProfiling = boptsExeProfile bopts
            , bcoFinalAction = boptsFinalAction bopts
            , bcoGhcOptions = boptsGhcOptions bopts
            }
        extraToBuild = either (const []) id $ boptsTargets bopts
    plan <- withCabalLoader menv $ \cabalLoader -> do
        let loadPackage name version flags = do
                bs <- cabalLoader $ PackageIdentifier name version -- TODO automatically update index the first time this fails
                readPackageBS (depPackageConfig bconfig flags) bs
        constructPlan mbp baseConfigOpts locals extraToBuild locallyRegistered loadPackage sourceMap2

    if boptsDryrun bopts
        then printPlan plan
        else withSystemTempDirectory stackProgName $ \tmpdir -> do
            tmpdir' <- parseAbsDir tmpdir
            configLock <- newMVar ()
            installLock <- newMVar ()
            idMap <- liftIO $ newTVarIO M.empty
            let setupHs = tmpdir' </> $(mkRelFile "Setup.hs")
            liftIO $ writeFile (toFilePath setupHs) "import Distribution.Simple\nmain = defaultMain"
            executePlan plan ExecuteEnv
                { eeEnvOverride = menv
                , eeBuildOpts = bopts
                 -- Uncertain as to why we cannot run configures in parallel. This appears
                 -- to be a Cabal library bug. Original issue:
                 -- https://github.com/fpco/stack/issues/84. Ideally we'd be able to remove
                 -- this.
                , eeConfigureLock = configLock
                , eeInstallLock = installLock
                , eeBaseConfigOpts = baseConfigOpts
                , eeGhcPkgIds = idMap
                , eeTempDir = tmpdir'
                , eeSetupHs = setupHs
                , eeCabalPkgVer = cabalPkgVer
                , eeTotalWanted = length $ filter lpWanted locals
                }
  where
    profiling = boptsLibProfile bopts || boptsExeProfile bopts

-- | All flags for a local package
localFlags :: BuildOpts -> BuildConfig -> PackageName -> Map FlagName Bool
localFlags bopts bconfig name = M.union
    (fromMaybe M.empty $ M.lookup name $ boptsFlags bopts)
    (fromMaybe M.empty $ M.lookup name $ bcFlags bconfig)

-- | Package config to be used for dependencies
depPackageConfig :: BuildConfig -> Map FlagName Bool -> PackageConfig
depPackageConfig bconfig flags = PackageConfig
    { packageConfigEnableTests = False
    , packageConfigEnableBenchmarks = False
    , packageConfigFlags = flags
    , packageConfigGhcVersion = bcGhcVersion bconfig
    , packageConfigPlatform = configPlatform (getConfig bconfig)
    }

printPlan :: M env m => Plan -> m ()
printPlan plan = do
    case Set.toList $ planUnregisterLocal plan of
        [] -> $logInfo "Nothing to unregister"
        xs -> do
            $logInfo "Would unregister locally:"
            mapM_ ($logInfo . T.pack . ghcPkgIdString) xs

    $logInfo ""

    case Map.elems $ planTasks plan of
        [] -> $logInfo "Nothing to build"
        xs -> do
            $logInfo "Would build:"
            mapM_ ($logInfo . displayTask) xs

-- | For a dry run
displayTask :: Task -> Text
displayTask task = T.pack $ concat
    [ packageIdentifierString $ taskProvides task
    , ": database="
    , case taskLocation task of
        Snap -> "snapshot"
        Local -> "local"
    , ", source="
    , case taskType task of
        TTLocal lp steps -> concat
            [ toFilePath $ lpDir lp
            , case steps of
                AllSteps -> " (configure)"
                SkipConfig -> " (build)"
                JustFinal -> " (already built)"
            ]
        TTUpstream _ _ -> "package index"
    , if Set.null $ taskRequiresMissing task
        then ""
        else ", after: " ++ intercalate "," (map packageIdentifierString $ Set.toList $ taskRequiresMissing task)
    ]

data ExecuteEnv = ExecuteEnv
    { eeEnvOverride :: !EnvOverride
    , eeConfigureLock :: !(MVar ())
    , eeInstallLock :: !(MVar ())
    , eeBuildOpts :: !BuildOpts
    , eeBaseConfigOpts :: !BaseConfigOpts
    , eeGhcPkgIds :: !(TVar (Map PackageIdentifier Installed))
    , eeTempDir :: !(Path Abs Dir)
    , eeSetupHs :: !(Path Abs File)
    , eeCabalPkgVer :: !PackageIdentifier
    , eeTotalWanted :: !Int
    }

-- | Perform the actual plan
executePlan :: M env m
            => Plan
            -> ExecuteEnv
            -> m ()
executePlan plan ee = do
    case Set.toList $ planUnregisterLocal plan of
        [] -> return ()
        ids -> do
            localDB <- packageDatabaseLocal
            forM_ ids $ \id' -> do
                $logInfo $ T.concat
                    [ T.pack $ ghcPkgIdString id'
                    , ": unregistering"
                    ]
                unregisterGhcPkgId (eeEnvOverride ee) localDB id'

    -- Yes, we're explicitly discarding result values, which in general would
    -- be bad. monad-unlift does this all properly at the type system level,
    -- but I don't want to pull it in for this one use case, when we know that
    -- stack always using transformer stacks that are safe for this use case.
    runInBase <- liftBaseWith $ \run -> return (void . run)

    let actions = concatMap (toActions runInBase ee) $ Map.elems $ planTasks plan
    threads <- liftIO getNumCapabilities -- TODO make a build opt to override this
    liftIO $ runActions threads actions

toActions :: M env m
          => (m () -> IO ())
          -> ExecuteEnv
          -> Task
          -> [Action]
toActions runInBase ee task@Task {..} =
    -- TODO in the future, we need to have proper support for cyclic
    -- dependencies from test suites, in which case we'll need more than one
    -- Action here

    [ Action
        { actionId = ActionId taskProvides ATBuild
        , actionDeps =
            (Set.map (\ident -> ActionId ident ATBuild) taskRequiresMissing)
        , actionDo = \ac -> runInBase $ singleBuild ac ee task
        }
    ]

singleBuild :: M env m
            => ActionContext
            -> ExecuteEnv
            -> Task
            -> m ()
singleBuild ActionContext {..} ExecuteEnv {..} Task {..} =
  withPackage $ \package cabalfp pkgDir ->
  withLogFile package $ \mlogFile ->
  withCabal pkgDir mlogFile $ \cabal -> do
    when needsConfig $ withMVar eeConfigureLock $ \_ -> do
        deleteCaches pkgDir
        idMap <- liftIO $ readTVarIO eeGhcPkgIds
        let getMissing ident =
                case Map.lookup ident idMap of
                    Nothing -> error "singleBuild: invariant violated, missing package ID missing"
                    Just (Library x) -> Just x
                    Just Executable -> Nothing
            allDeps = Set.union
                taskRequiresPresent
                (Set.fromList $ mapMaybe getMissing $ Set.toList taskRequiresMissing)
        let configOpts = configureOpts
                eeBaseConfigOpts
                allDeps
                wanted
                taskLocation
                (packageFlags package)
        announce "configure"
        cabal False $ "configure" : map T.unpack configOpts
        $logDebug $ T.pack $ show configOpts
        writeConfigCache pkgDir configOpts

    fileModTimes <- getPackageFileModTimes package cabalfp
    writeBuildCache pkgDir fileModTimes

    unless justFinal $ do
        announce "build"
        config <- asks getConfig
        cabal (console && configHideTHLoading config) ["build"]

    case boptsFinalAction eeBuildOpts of
        DoTests -> when wanted $ do
            announce "test"
            runTests package pkgDir mlogFile
        DoBenchmarks -> when wanted $ do
            announce "benchmarks"
            cabal False ["bench"]
        DoHaddock -> do
            announce "haddock"
            hscolourExists <- doesExecutableExist eeEnvOverride "hscolour"
              {- EKB TODO: doc generation for stack-doc-server
 #ifndef mingw32_HOST_OS
              liftIO (removeDocLinks docLoc package)
 #endif
              ifcOpts <- liftIO (haddockInterfaceOpts docLoc package packages)
              -}
            cabal False (concat [["haddock", "--html"]
                                ,["--hyperlink-source" | hscolourExists]])
              {- EKB TODO: doc generation for stack-doc-server
                         ,"--hoogle"
                         ,"--html-location=../$pkg-$version/"
                         ,"--haddock-options=" ++ intercalate " " ifcOpts ]
              haddockLocs <-
                liftIO (findFiles (packageDocDir package)
                                  (\loc -> FilePath.takeExtensions (toFilePath loc) ==
                                           "." ++ haddockExtension)
                                  (not . isHiddenDir))
              forM_ haddockLocs $ \haddockLoc ->
                do let hoogleTxtPath = FilePath.replaceExtension (toFilePath haddockLoc) "txt"
                       hoogleDbPath = FilePath.replaceExtension hoogleTxtPath hoogleDbExtension
                   hoogleExists <- liftIO (doesFileExist hoogleTxtPath)
                   when hoogleExists
                        (callProcess
                             "hoogle"
                             ["convert"
                             ,"--haddock"
                             ,hoogleTxtPath
                             ,hoogleDbPath])
                        -}
                 {- EKB TODO: doc generation for stack-doc-server
             #ifndef mingw32_HOST_OS
                 case setupAction of
                   DoHaddock -> liftIO (createDocLinks docLoc package)
                   _ -> return ()
             #endif

-- | Package's documentation directory.
packageDocDir :: (MonadThrow m, MonadReader env m, HasPlatform env)
              => PackageIdentifier -- ^ Cabal version
              -> Package
              -> m (Path Abs Dir)
packageDocDir cabalPkgVer package' = do
  dist <- distDirFromDir cabalPkgVer (packageDir package')
  return (dist </> $(mkRelDir "doc/"))
                 --}
        DoNothing -> return ()

    unless justFinal $ withMVar eeInstallLock $ \_ -> do
        announce "install"
        cabal False ["install"]

    -- It seems correct to leave this outside of the "justFinal" check above,
    -- in case another package depends on a justFinal target
    let pkgDbs =
            case taskLocation of
                Snap -> [bcoSnapDB eeBaseConfigOpts]
                Local ->
                    [ bcoSnapDB eeBaseConfigOpts
                    , bcoLocalDB eeBaseConfigOpts
                    ]
    mpkgid <- findGhcPkgId eeEnvOverride pkgDbs (packageName package)
    mpkgid' <- case (packageHasLibrary package, mpkgid) of
        (False, _) -> assert (isNothing mpkgid) $ do
            markExeInstalled taskLocation taskProvides
            return Executable
        (True, Nothing) -> throwM $ Couldn'tFindPkgId $ packageName package
        (True, Just pkgid) -> do
            writeFlagCache pkgid $ packageFlags package
            return $ Library pkgid
    liftIO $ atomically $ modifyTVar eeGhcPkgIds $ Map.insert taskProvides mpkgid'
  where
    announce x = $logInfo $ T.concat
        [ T.pack $ packageIdentifierString taskProvides
        , ": "
        , x
        ]

    needsConfig =
        case taskType of
            TTLocal _ y -> y == AllSteps
            TTUpstream _ _ -> True
    justFinal =
        case taskType of
            TTLocal _ JustFinal -> True
            _ -> False

    wanted =
        case taskType of
            TTLocal lp _ -> lpWanted lp
            TTUpstream _ _ -> False

    console = wanted && acRemaining == 0 && eeTotalWanted == 1

    withPackage inner =
        case taskType of
            TTLocal lp _ -> inner (lpPackage lp) (lpCabalFile lp) (lpDir lp)
            TTUpstream package _ -> do
                mdist <- liftM Just $ distRelativeDir eeCabalPkgVer
                m <- unpackPackageIdents eeEnvOverride eeTempDir mdist $ Set.singleton taskProvides
                case M.toList m of
                    [(ident, dir)]
                        | ident == taskProvides -> do
                            let name = packageIdentifierName taskProvides
                            cabalfpRel <- parseRelFile $ packageNameString name ++ ".cabal"
                            let cabalfp = dir </> cabalfpRel
                            inner package cabalfp dir
                    _ -> error $ "withPackage: invariant violated: " ++ show m

    withLogFile package inner
        | console = inner Nothing
        | otherwise = do
            logPath <- buildLogPath package
            liftIO $ createDirectoryIfMissing True $ toFilePath $ parent logPath
            let fp = toFilePath logPath
            bracket
                (liftIO $ openBinaryFile fp WriteMode)
                (liftIO . hClose)
                $ \h -> inner (Just (fp, h))

    withCabal pkgDir mlogFile inner = do
        config <- asks getConfig
        menv <- liftIO $ configEnvOverride config EnvSettings
            { esIncludeLocals = taskLocation == Local
            , esIncludeGhcPackagePath = False
            }
        exeName <- liftIO $ join $ findExecutable menv "runhaskell"
        distRelativeDir' <- distRelativeDir eeCabalPkgVer
        msetuphs <- liftIO $ getSetupHs pkgDir
        let setuphs = fromMaybe eeSetupHs msetuphs
        inner $ \stripTHLoading args -> do
            let fullArgs =
                      ("-package=" ++ packageIdentifierString eeCabalPkgVer)
                    : "-clear-package-db"
                    : "-global-package-db"
                    -- TODO: Perhaps we want to include the snapshot package database here
                    -- as well
                    : toFilePath setuphs
                    : ("--builddir=" ++ toFilePath distRelativeDir')
                    : args
                cp0 = proc (toFilePath exeName) fullArgs
                cp = cp0
                    { cwd = Just $ toFilePath pkgDir
                    , Process.env = envHelper menv
                    , std_in = CreatePipe
                    , std_out =
                        if stripTHLoading
                            then CreatePipe
                            else case mlogFile of
                                Nothing -> Inherit
                                Just (_, h) -> UseHandle h
                    , std_err =
                        case mlogFile of
                            Nothing -> Inherit
                            Just (_, h) -> UseHandle h
                    }
            $logDebug $ "Running: " <> T.pack (show $ toFilePath exeName : fullArgs)

            -- Use createProcess_ to avoid the log file being closed afterwards
            (Just inH, moutH, Nothing, ph) <- liftIO $ createProcess_ "singleBuild" cp
            liftIO $ hClose inH
            case moutH of
                Just outH -> assert stripTHLoading $ printWithoutTHLoading outH
                Nothing -> return ()
            ec <- liftIO $ waitForProcess ph
            case ec of
                ExitSuccess -> return ()
                _ -> do
                    bs <- liftIO $
                        case mlogFile of
                            Nothing -> return ""
                            Just (logFile, h) -> do
                                hClose h
                                S.readFile logFile
                    throwM $ CabalExitedUnsuccessfully
                        ec
                        taskProvides
                        exeName
                        fullArgs
                        (fmap fst mlogFile)
                        bs

    runTests package pkgDir mlogFile = do
        bconfig <- asks getBuildConfig
        distRelativeDir' <- distRelativeDir eeCabalPkgVer
        let buildDir = pkgDir </> distRelativeDir'
        let exeExtension =
                case configPlatform $ getConfig bconfig of
                    Platform _ Windows -> ".exe"
                    _ -> ""

        errs <- liftM Map.unions $ forM (Set.toList $ packageTests package) $ \testName -> do
            nameDir <- liftIO $ parseRelDir $ T.unpack testName
            nameExe <- liftIO $ parseRelFile $ T.unpack testName ++ exeExtension
            let exeName = buildDir </> $(mkRelDir "build") </> nameDir </> nameExe
            exists <- liftIO $ doesFileExist $ toFilePath exeName
            config <- asks getConfig
            menv <- liftIO $ configEnvOverride config EnvSettings
                { esIncludeLocals = taskLocation == Local
                , esIncludeGhcPackagePath = True
                }
            if exists
                then do
                    announce $ "test " <> testName
                    let cp = (proc (toFilePath exeName) [])
                            { cwd = Just $ toFilePath pkgDir
                            , Process.env = envHelper menv
                            , std_in = CreatePipe
                            , std_out =
                                case mlogFile of
                                    Nothing -> Inherit
                                    Just (_, h) -> UseHandle h
                            , std_err =
                                case mlogFile of
                                    Nothing -> Inherit
                                    Just (_, h) -> UseHandle h
                            }

                    -- Use createProcess_ to avoid the log file being closed afterwards
                    (Just inH, Nothing, Nothing, ph) <- liftIO $ createProcess_ "singleBuild.runTests" cp
                    liftIO $ hClose inH
                    ec <- liftIO $ waitForProcess ph
                    return $ case ec of
                        ExitSuccess -> M.empty
                        _ -> M.singleton testName $ Just ec
                else do
                    $logError $ T.concat
                        [ "Test suite "
                        , testName
                        , " executable not found for "
                        , T.pack $ packageNameString $ packageName package
                        ]
                    return $ Map.singleton testName Nothing
        unless (Map.null errs) $ throwM $ TestSuiteFailure2 taskProvides errs (fmap fst mlogFile)

-- | Grab all output from the given @Handle@ and print it to stdout, stripping
-- Template Haskell "Loading package" lines. Does work in a separate thread.
printWithoutTHLoading :: MonadIO m => Handle -> m ()
printWithoutTHLoading outH = liftIO $ void $ forkIO $
       CB.sourceHandle outH
    $$ CB.lines
    =$ CL.filter (not . isTHLoading)
    =$ CL.mapM_ S8.putStrLn
  where
    -- | Is this line a Template Haskell "Loading package" line
    -- ByteString
    isTHLoading :: S8.ByteString -> Bool
    isTHLoading bs =
        "Loading package " `S8.isPrefixOf` bs &&
        ("done." `S8.isSuffixOf` bs || "done.\r" `S8.isSuffixOf` bs)


-- | Reset the build (remove Shake database and .gen files).
clean :: (M env m) => m ()
clean = do
    bconfig <- asks getBuildConfig
    menv <- getMinimalEnvOverride
    cabalPkgVer <- getCabalPkgVer menv
    forM_
        (S.toList (bcPackages bconfig))
        (distDirFromDir cabalPkgVer >=> removeTreeIfExists)

{- EKB TODO: doc generation for stack-doc-server
            (boptsFinalAction bopts == DoHaddock)
            (buildDocIndex
                 (wanted pwd)
                 docLoc
                 packages
                 mgr
                 logLevel)
                                  -}

-- | Get the version of Cabal from the global package database.
getCabalPkgVer :: (MonadThrow m,MonadIO m,MonadLogger m)
               => EnvOverride -> m PackageIdentifier
getCabalPkgVer menv = do
    db <- getGlobalDB menv
    findGhcPkgId
        menv
        [db]
        cabalName >>=
        maybe
            (throwM (Couldn'tFindPkgId cabalName))
            (return . ghcPkgIdPackageIdentifier)
  where
    cabalName =
        $(mkPackageName "Cabal")

-- | Ensure Setup.hs exists in the given directory. Returns an action
-- to remove it later.
getSetupHs :: Path Abs Dir -- ^ project directory
           -> IO (Maybe (Path Abs File))
getSetupHs dir = do
    exists1 <- doesFileExist (toFilePath fp1)
    if exists1
        then return $ Just fp1
        else do
            exists2 <- doesFileExist (toFilePath fp2)
            if exists2
                then return $ Just fp2
                else return Nothing
  where
    fp1 = dir </> $(mkRelFile "Setup.hs")
    fp2 = dir </> $(mkRelFile "Setup.lhs")

{- EKB TODO: doc generation for stack-doc-server
-- | Build the haddock documentation index and contents.
buildDocIndex :: (Package -> Wanted)
              -> Path Abs Dir
              -> Set Package
              -> Manager
              -> LogLevel
              -> Rules ()
buildDocIndex wanted docLoc packages mgr logLevel =
  do runHaddock "--gen-contents" $(mkRelFile "index.html")
     runHaddock "--gen-index" $(mkRelFile "doc-index.html")
     combineHoogle
  where
    runWithLogging = runStackLoggingT mgr logLevel
    runHaddock genOpt destFilename =
      do let destPath = toFilePath (docLoc </> destFilename)
         want [destPath]
         destPath %> \_ ->
           runWithLogging
               (do needDeps
                   ifcOpts <- liftIO (fmap concat (mapM toInterfaceOpt (S.toList packages)))
                   runIn docLoc
                         "haddock"
                         mempty
                         (genOpt:ifcOpts)
                         Nothing)
    toInterfaceOpt package =
      do let pv = joinPkgVer (packageName package,packageVersion package)
             srcPath = (toFilePath docLoc) ++ "/" ++
                       pv ++ "/" ++
                       packageNameString (packageName package) ++ "." ++
                       haddockExtension
         exists <- doesFileExist srcPath
         return (if exists
                    then ["-i"
                         ,"../" ++
                          pv ++
                          "," ++
                          srcPath]
                     else [])
    combineHoogle =
      do let destHoogleDbLoc = hoogleDatabaseFile docLoc
             destPath = toFilePath destHoogleDbLoc
         want [destPath]
         destPath %> \_ ->
           runWithLogging
               (do needDeps
                   srcHoogleDbs <- liftIO (fmap concat (mapM toSrcHoogleDb (S.toList packages)))
                   callProcess
                        "hoogle"
                        ("combine" :
                         "-o" :
                         toFilePath destHoogleDbLoc :
                         srcHoogleDbs))
    toSrcHoogleDb package =
      do let srcPath = toFilePath docLoc ++ "/" ++
                       joinPkgVer (packageName package,packageVersion package) ++ "/" ++
                       packageNameString (packageName package) ++ "." ++
                       hoogleDbExtension
         exists <- doesFileExist srcPath
         return (if exists
                    then [srcPath]
                    else [])
    needDeps =
      need (concatMap (\package -> if wanted package == Wanted
                                    then let dir = packageDir package
                                         in [toFilePath (builtFileFromDir dir)]
                                    else [])
                      (S.toList packages))

#ifndef mingw32_HOST_OS
-- | Remove existing links docs for package from @~/.shake/doc@.
removeDocLinks :: Path Abs Dir -> Package -> IO ()
removeDocLinks docLoc package =
  do createDirectoryIfMissing True
                              (toFilePath docLoc)
     userDocLs <-
       fmap (map (toFilePath docLoc ++))
            (getDirectoryContents (toFilePath docLoc))
     forM_ userDocLs $
       \docPath ->
         do isDir <- doesDirectoryExist docPath
            when isDir
                 (case breakPkgVer (FilePath.takeFileName docPath) of
                    Just (p,_) ->
                      when (p == packageName package)
                           (removeLink docPath)
                    Nothing -> return ())

-- | Add link for package to @~/.shake/doc@.
createDocLinks :: Path Abs Dir -> Package -> IO ()
createDocLinks docLoc package =
  do let pkgVer =
           joinPkgVer (packageName package,(packageVersion package))
     pkgVerLoc <- liftIO (parseRelDir pkgVer)
     let pkgDestDocLoc = docLoc </> pkgVerLoc
         pkgDestDocPath =
           FilePath.dropTrailingPathSeparator (toFilePath pkgDestDocLoc)
         cabalDocLoc = parent docLoc </>
                       $(mkRelDir "share/doc/")
     haddockLocs <-
       do cabalDocExists <- doesDirectoryExist (toFilePath cabalDocLoc)
          if cabalDocExists
             then findFiles cabalDocLoc
                            (\fileLoc ->
                               FilePath.takeExtensions (toFilePath fileLoc) ==
                               "." ++ haddockExtension &&
                               dirname (parent fileLoc) ==
                               $(mkRelDir "html/") &&
                               toFilePath (dirname (parent (parent fileLoc))) ==
                               (pkgVer ++ "/"))
                            (\dirLoc ->
                               not (isHiddenDir dirLoc) &&
                               dirname (parent (parent dirLoc)) /=
                               $(mkRelDir "html/"))
             else return []
     case haddockLocs of
       [haddockLoc] ->
         case stripDir (parent docLoc)
                          haddockLoc of
           Just relHaddockPath ->
             do let srcRelPathCollapsed =
                      FilePath.takeDirectory (FilePath.dropTrailingPathSeparator (toFilePath relHaddockPath))
                    {-srcRelPath = "../" ++ srcRelPathCollapsed-}
                createSymbolicLink (FilePath.dropTrailingPathSeparator srcRelPathCollapsed)
                                   pkgDestDocPath
           Nothing -> return ()
       _ -> return ()
#endif /* not defined(mingw32_HOST_OS) */

-- | Get @-i@ arguments for haddock for dependencies.
haddockInterfaceOpts :: Path Abs Dir -> Package -> Set Package -> IO [String]
haddockInterfaceOpts userDocLoc package packages =
  do mglobalDocLoc <- getGlobalDocPath
     globalPkgVers <-
       case mglobalDocLoc of
         Nothing -> return M.empty
         Just globalDocLoc -> getDocPackages globalDocLoc
     let toInterfaceOpt pn =
           case find (\dpi -> packageName dpi == pn) (S.toList packages) of
             Nothing ->
               return (case (M.lookup pn globalPkgVers,mglobalDocLoc) of
                         (Just (v:_),Just globalDocLoc) ->
                           ["-i"
                           ,"../" ++ joinPkgVer (pn,v) ++
                            "," ++
                            toFilePath globalDocLoc ++ "/" ++
                            joinPkgVer (pn,v) ++ "/" ++
                            packageNameString pn ++ "." ++
                            haddockExtension]
                         _ -> [])
             Just dpi ->
               do let destPath = (toFilePath userDocLoc ++ "/" ++
                                 joinPkgVer (pn,packageVersion dpi) ++ "/" ++
                                 packageNameString pn ++ "." ++
                                 haddockExtension)
                  exists <- doesFileExist destPath
                  return (if exists
                             then ["-i"
                                  ,"../" ++
                                   joinPkgVer (pn,packageVersion dpi) ++
                                   "," ++
                                   destPath]
                             else [])
     --TODO: use not only direct dependencies, but dependencies of dependencies etc.
     --(e.g. redis-fp doesn't include @text@ in its dependencies which means the 'Text'
     --datatype isn't linked in its haddocks)
     fmap concat (mapM toInterfaceOpt (S.toList (packageAllDeps package)))

--------------------------------------------------------------------------------
-- Paths

{- EKB TODO: doc generation for stack-doc-server
-- | Returns true for paths whose last directory component begins with ".".
isHiddenDir :: Path b Dir -> Bool
isHiddenDir = isPrefixOf "." . toFilePath . dirname
        -}
--}
