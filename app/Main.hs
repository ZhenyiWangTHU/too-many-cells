{- too-many-cells
Gregory W. Schwartz

Clusters single cell data.
-}

{-# LANGUAGE QuasiQuotes       #-}
{-# LANGUAGE BangPatterns      #-}
{-# LANGUAGE DataKinds         #-}
{-# LANGUAGE DeriveGeneric     #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PackageImports    #-}
{-# LANGUAGE TypeOperators     #-}
{-# LANGUAGE TupleSections     #-}

module Main where

-- Remote
import BirchBeer.ColorMap
import BirchBeer.Interactive
import BirchBeer.MainDiagram
import BirchBeer.Plot
import BirchBeer.Types hiding (Delimiter, LabelFile)
import BirchBeer.Utility
import Control.Monad (when, unless, join)
import Data.Bool (bool)
import Data.Colour.SRGB (sRGB24read)
import Data.Matrix.MatrixMarket (readMatrix, writeMatrix)
import Data.Maybe (fromMaybe, isJust, isNothing)
import Data.Monoid ((<>))
import Language.R as R
import Language.R.QQ (r)
import Math.Clustering.Hierarchical.Spectral.Sparse (B (..))
import Math.Clustering.Hierarchical.Spectral.Types (getClusterItemsDend)
import Options.Generic
import System.IO (hPutStrLn, stderr)
import TextShow (showt)
import qualified "find-clumpiness" Types as Clump
import qualified Control.Lens as L
import qualified Data.Aeson as A
import qualified Data.ByteString.Lazy.Char8 as B
import qualified Data.Csv as CSV
import qualified Data.GraphViz as G
import qualified Data.Text as T
import qualified Data.Text.Lazy.IO as T
import qualified Data.Vector as V
import qualified Diagrams.Backend.Cairo as D
import qualified Diagrams.Prelude as D
import qualified Graphics.Matplotlib as P
import qualified H.Prelude as H
import qualified Plots as D
import qualified System.Directory as FP
import qualified System.FilePath as FP

-- Local
import TooManyCells.Differential.Differential
import TooManyCells.Differential.Types
import TooManyCells.Diversity.Diversity
import TooManyCells.Diversity.Load
import TooManyCells.Diversity.Plot
import TooManyCells.Diversity.Types
import TooManyCells.File.Types
import TooManyCells.MakeTree.Clumpiness
import TooManyCells.MakeTree.Cluster
import TooManyCells.MakeTree.Load
import TooManyCells.MakeTree.Plot
import TooManyCells.MakeTree.Types
import TooManyCells.Matrix.Load
import TooManyCells.Matrix.Preprocess
import TooManyCells.Matrix.Types

-- | Command line arguments
data Options
    = MakeTree { matrixPath :: [String] <?> "(PATH) The path to the input directory containing the matrix output of cellranger (matrix.mtx, genes.tsv, and barcodes.tsv) or, if genes-file and cells-file are not specified, or an input csv file containing gene row names and cell column names. If given as a list (--matrixPath input1 --matrixPath input2 etc.) then will join all matrices together. Assumes the same number and order of genes in each matrix, so only cells are added."
               , projectionFile :: Maybe String <?> "([Nothing] | FILE) The input file containing positions of each cell for plotting. Format is \"barcode,x,y\" and matches column order in the matrix file. Useful for 10x where a TNSE projection is generated in \"projection.csv\". If not supplied, the resulting plot will use the first two features."
               , cellWhitelistFile :: Maybe String <?> "([Nothing] | FILE) The input file containing the cells to include. No header, line separated list of barcodes."
               , labelsFile :: Maybe String <?> "([Nothing] | FILE) The input file containing the label for each cell barcode, with \"item,label\" header."
               , delimiter :: Maybe Char <?> "([,] | CHAR) The delimiter for the csv file if using a normal csv rather than cellranger output."
               , normalization :: Maybe String <?> "([B1Norm] | [None] | WishboneNorm) Type of normalization before clustering. Default is B1Norm for clustering and None for differential (edgeR). Cannot use B1Norm for any other process as None will become the default."
               , minSize :: Maybe Int <?> "([1] | INT) The minimum size of a cluster. Defaults to 1."
               , maxStep :: Maybe Int <?> "([Nothing] | INT) Only keep clusters that are INT steps from the root. Defaults to all steps."
               , drawLeaf :: Maybe String <?> "([DrawText] | DrawItem DrawItemType) How to draw leaves in the dendrogram. DrawText is the number of cells in that leaf. DrawItem is the collection of cells represented by circles, consisting of: DrawItem DrawLabel, where each cell is colored by its label, DrawItem (DrawContinuous GENE), where each cell is colored by the expression of GENE (corresponding to a gene name in the input matrix), DrawItem (DrawThresholdContinuous [(GENE, DOUBLE)], where each cell is colored by the binary high / low expression of GENE based on DOUBLE and multiple GENEs can be used to combinatorically label cells (GENE1 high / GENE2 low, etc.), and DrawItem DrawSumContinuous, where each cell is colored by the sum of the post-normalized columns (use --normalization NoneNorm for UMI counts, default). The default is DrawText, unless --labels-file is provided, in which DrawItem DrawLabel is the default."
               , drawPie :: Maybe String <?> "([PieRing] | PieChart | PieNone) How to draw cell leaves in the dendrogram. PieRing draws a pie chart ring around the cells. PieChart only draws a pie chart instead of cells. PieNone only draws cells, no pie rings or charts."
               , drawMark :: Maybe String <?> "([MarkNone] | MarkModularity) How to draw annotations around each inner node in the tree. MarkNone draws nothing and MarkModularity draws a black circle representing the modularity at that node, darker black means higher modularity for that next split."
               ,
                 -- Disable for now. , drawDendrogram :: Bool <?> "Draw a dendrogram instead of a graph."
                 drawNodeNumber :: Bool <?> "Draw the node numbers on top of each node in the graph."
               , drawMaxNodeSize :: Maybe Double <?> "([72] | DOUBLE) The max node size when drawing the graph. 36 is the theoretical default, but here 72 makes for thicker branches."
               , drawNoScaleNodes :: Bool <?> "Do not scale inner node size when drawing the graph. Instead, uses draw-max-node-size as the size of each node and is highly recommended to change as the default may be too large for this option."
               , drawColors :: Maybe String <?> "([Nothing] | COLORS) Custom colors for the labels. Will repeat if more labels than provided colors. For instance: --draw-colors \"[\\\"#e41a1c\\\", \\\"#377eb8\\\"]\""
               , pca :: Maybe Double <?> "([Nothing] | DOUBLE) The percent variance to retain for PCA dimensionality reduction before clustering. Default is no PCA at all in order to keep all information."
               , prior :: Maybe String <?> "([Nothing] | STRING) The input folder containing the output from a previous run. If specified, skips clustering by using the previous clustering files."
               , order :: Maybe Double <?> "([1] | DOUBLE) The order of diversity."
               , clumpinessMethod :: Maybe String <?> "([Majority] | Exclusive | AllExclusive) The method used when calculating clumpiness: Majority labels leaves according to the most abundant label, Exclusive only looks at leaves consisting of cells solely from one label, and AllExclusive treats the leaf as containing both labels."
               , output :: Maybe String <?> "([out] | STRING) The folder containing output."}
    | Interactive { matrixPath :: [String] <?> "(PATH) The path to the input directory containing the matrix output of cellranger (matrix.mtx, genes.tsv, and barcodes.tsv) or, if genes-file and cells-file are not specified, or an input csv file containing gene row names and cell column names. If given as a list (--matrixPath input1 --matrixPath input2 etc.) then will join all matrices together. Assumes the same number and order of genes in each matrix, so only cells are added."
                  , projectionFile :: Maybe String <?> "([Nothing] | FILE) The input file containing positions of each cell for plotting. Format is \"barcode,x,y\" and matches column order in the matrix file. Useful for 10x where a TNSE projection is generated in \"projection.csv\". If not supplied, the resulting plot will use the first two features."
                  , cellWhitelistFile :: Maybe String <?> "([Nothing] | FILE) The input file containing the cells to include. No header, line separated list of barcodes."
                  , labelsFile :: Maybe String <?> "([Nothing] | FILE) The input file containing the label for each cell barcode, with \"item,label\" header."
                  , delimiter :: Maybe Char <?> "([,] | CHAR) The delimiter for the csv file if using a normal csv rather than cellranger output."
                  , normalization :: Maybe String <?> "([B1Norm] | [None] | WishboneNorm) Type of normalization before clustering. Default is B1Norm for clustering and None for differential (edgeR). Cannot use B1Norm for any other process as None will become the default."
                  , pca :: Maybe Double <?> "([Nothing] | DOUBLE) The percent variance to retain for PCA dimensionality reduction before clustering. Default is no PCA at all in order to keep all information."
                  , prior :: Maybe String <?> "([Nothing] | STRING) The input folder containing the output from a previous run. If specified, skips clustering by using the previous clustering files."}
    | Differential { matrixPath :: [String] <?> "(PATH) The path to the input directory containing the matrix output of cellranger (matrix.mtx, genes.tsv, and barcodes.tsv) or, if genes-file and cells-file are not specified, or an input csv file containing gene row names and cell column names. If given as a list (--matrixPath input1 --matrixPath input2 etc.) then will join all matrices together. Assumes the same number and order of genes in each matrix, so only cells are added."
                   , projectionFile :: Maybe String <?> "([Nothing] | FILE) The input file containing positions of each cell for plotting. Format is \"barcode,x,y\" and matches column order in the matrix file. Useful for 10x where a TNSE projection is generated in \"projection.csv\". If not supplied, the resulting plot will use the first two features."
                   , cellWhitelistFile :: Maybe String <?> "([Nothing] | FILE) The input file containing the cells to include. No header, line separated list of barcodes."
                   , delimiter :: Maybe Char <?> "([,] | CHAR) The delimiter for the csv file if using a normal csv rather than cellranger output."
                   , normalization :: Maybe String <?> "([B1Norm] | [None] | WishboneNorm) Type of normalization before clustering. Default is B1Norm for clustering and None for differential (edgeR). Cannot use B1Norm for any other process as None will become the default."
                   , prior :: Maybe String <?> "([Nothing] | STRING) The input folder containing the output from a previous run. If specified, skips clustering by using the previous clustering files."
                   , nodes :: String <?> "([NODE], [NODE]) Find the differential expression between cells belonging downstream of a list of nodes versus another list of nodes."
                   , topN :: Maybe Int <?> "([100] | INT ) The top INT differentially expressed genes."}
    | Diversity { priors :: [String] <?> "(PATH) Either input folders containing the output from a run of too-many-cells or a csv files containing the clusters for each cell in the format \"cell,cluster\". Advanced features not available in the latter case."
                , start :: Maybe Integer <?> "([0] | INT) For the rarefaction curve, start the curve at this subsampling."
                , interval :: Maybe Integer <?> "([1] | INT) For the rarefaction curve, the amount to increase each subsampling. For instance, starting at 0 with an interval of 4, we would sampling 0, 4, 8, 12, ..."
                , end :: Maybe Integer <?> "([N] | INT) For the rarefaction curve, which subsample to stop at. By default, the curve stops at the observed number of species for each population."
                , order :: Maybe Double <?> "([1] | DOUBLE) The order of diversity."
                , output :: Maybe String <?> "([out] | STRING) The folder containing output."}
    deriving ((Generic))

modifiers :: Modifiers
modifiers = lispCaseModifiers { shortNameModifier = short }
  where
    short "minSize"              = Just 'M'
    short "projectionFile"       = Just 'j'
    short "priors"               = Just 'P'
    short "clusterNormalization" = Just 'C'
    short "normalization"        = Just 'z'
    short "drawLeaf"             = Just 'L'
    -- short "drawDendrogram"       = Just 'D'
    short "drawNodeNumber"       = Just 'N'
    short "order"                = Just 'O'
    short "pca"                  = Just 'a'
    short "clumpinessMethod"     = Just 'u'
    short "drawColors"           = Just 'R'
    short x                      = firstLetter x

instance ParseRecord Options where
    parseRecord = parseRecordWithModifiers modifiers

-- | Notify user of limitations and error out for incompatabilities. Empty for
-- now.
limitationWarningsErrors :: Options -> IO ()
limitationWarningsErrors opts = do
    return ()

-- | Load the single cell matrix.
loadSSM :: Options -> FilePath -> IO SingleCells
loadSSM opts matrixPath' = do
    fileExist      <- FP.doesFileExist matrixPath'
    directoryExist <- FP.doesDirectoryExist matrixPath'

    let matrixFile' =
            case (fileExist, directoryExist) of
                (False, False) -> error "Matrix path does not exist."
                (True, False)  -> Left $ MatrixFile matrixPath'
                (False, True)  ->
                    Right . MatrixFile $ matrixPath' FP.</> "matrix.mtx"
        genesFile'  = GeneFile $ matrixPath' FP.</> "genes.tsv"
        cellsFile'  = CellFile $ matrixPath' FP.</> "barcodes.tsv"
        projectionFile' =
            fmap ProjectionFile . unHelpful . projectionFile $ opts
        delimiter'      =
            Delimiter . fromMaybe ',' . unHelpful . delimiter $ opts
        unFilteredSc   =
            case matrixFile' of
                (Left file) -> loadSparseMatrixDataStream
                                delimiter'
                                projectionFile'
                                file
                (Right file) -> loadCellrangerData
                                    projectionFile'
                                    genesFile'
                                    cellsFile'
                                    file
    unFilteredSc

-- | Load all single cell matrices.
loadAllSSM :: Options -> IO SingleCells
loadAllSSM opts = do
    let matrixPaths'       =
            (\xs -> bool (error "Need a matrix path.") xs . not . null $ xs)
                . unHelpful
                . matrixPath
                $ opts
        cellWhitelistFile' =
            fmap CellWhitelistFile . unHelpful . cellWhitelistFile $ opts
        normalization'     =
            maybe B1Norm read . unHelpful . normalization $ opts
        pca'               = fmap PCAVar . unHelpful . pca $ opts

    cellWhitelist <- sequence $ fmap getCellWhitelist cellWhitelistFile'

    mats <- mapM (loadSSM opts) matrixPaths'

    let whiteListFilter Nothing = id
        whiteListFilter (Just wl) = filterWhitelistSparseMat wl
        unFilteredSc = mconcat mats
        sc           = filterNumSparseMat
                     . whiteListFilter cellWhitelist
                     $ unFilteredSc
        normMat NoneNorm     = id
        normMat B1Norm       = id -- Normalize during clustering.
        normMat WishboneNorm = scaleSparseMat
        processMat  = (\m -> maybe m (flip pcaDenseMat m) pca')
                    . normMat normalization'
                    . matrix
        processedSc = sc { matrix = processMat sc }

    return processedSc

makeTreeMain :: Options -> IO ()
makeTreeMain opts = H.withEmbeddedR defaultConfig $ do
    let labelsFile'       =
            fmap LabelFile . unHelpful . labelsFile $ opts
        prior'            =
            fmap PriorPath . unHelpful . prior $ opts
        delimiter'        =
            Delimiter . fromMaybe ',' . unHelpful . delimiter $ opts
        normalization' =
            maybe B1Norm read . unHelpful . normalization $ opts
        minSize'          = fmap MinClusterSize . unHelpful . minSize $ opts
        maxStep'          = fmap MaxStep . unHelpful . maxStep $ opts
        drawLeaf'         =
            maybe (maybe DrawText (const (DrawItem DrawLabel)) labelsFile') read
                . unHelpful
                . drawLeaf
                $ opts
        drawPie'          = maybe PieRing read . unHelpful . drawPie $ opts
        drawMark'         = maybe MarkNone read . unHelpful . drawMark $ opts
        -- drawDendrogram'   = unHelpful . drawDendrogram $ opts
        drawNodeNumber'   = DrawNodeNumber . unHelpful . drawNodeNumber $ opts
        drawMaxNodeSize'  =
            DrawMaxNodeSize . fromMaybe 72 . unHelpful . drawMaxNodeSize $ opts
        drawNoScaleNodes' =
            DrawNoScaleNodesFlag . unHelpful . drawNoScaleNodes $ opts
        drawColors'       = fmap ( CustomColors
                                 . fmap sRGB24read
                                 . (\x -> read x :: [String])
                                 )
                          . unHelpful
                          . drawColors
                          $ opts
        order'            = Order . fromMaybe 1 . unHelpful . order $ opts
        clumpinessMethod' =
            maybe Clump.Majority read . unHelpful . clumpinessMethod $ opts
        output'           =
            OutputDirectory . fromMaybe "out" . unHelpful . output $ opts

        drawConfig        = DrawConfig
                                drawLeaf'
                                drawPie'
                                drawNodeNumber'
                                drawMaxNodeSize'
                                drawNoScaleNodes'

        processedSc       = loadAllSSM opts

    -- Notify user of limitations.
    limitationWarningsErrors opts

    -- Where to place output files.
    FP.createDirectoryIfMissing True . unOutputDirectory $ output'

    -- Get the label map from either a file or from expression thresholds.
    labelMap <- case drawLeaf' of
                    (DrawItem (DrawThresholdContinuous gs)) ->
                        fmap
                            ( Just
                            . getLabelMapThresholdContinuous
                                (fmap (L.over L._1 Feature) gs)
                            )
                            processedSc
                    _ -> sequence . fmap (loadLabelData delimiter') $ labelsFile'

    --R.withEmbeddedR R.defaultConfig $ R.runRegion $ do
        -- For r clustering.
        -- mat         <- scToRMat processedSc
        -- clusterRes  <- hdbscan mat
        -- clusterList <- clustersToClusterList sc clusterRes

        -- For agglomerative clustering.
        --let clusterResults = fmap hClust processedSc

    -- Load previous results or calculate results if first run.
    (originalClusterResults, bMat) <- case prior' of
        Nothing -> do
            (fullCr, b, _) <- fmap (hSpecClust normalization') processedSc

            return (fullCr, return b) :: IO (ClusterResults, IO B)
        (Just x) -> do
            let crInput = (FP.</> "cluster_results.json") . unPriorPath $ x
                bInput  = (FP.</> "b.mtx") . unPriorPath $ x

            -- Strict loading in order to avoid locked file.
            !fullCr <- fmap (either error id . A.eitherDecode)
                     . B.readFile
                     $ crInput

            let b :: IO B
                b  = fmap (B . matToSpMat)
                    . readMatrix
                    $ bInput
            return (fullCr, b)

    birchMat <- case unHelpful . matrixPath $ opts of
                    [] -> return Nothing
                    _  -> fmap Just processedSc

    let config :: BirchBeer.Types.Config CellInfo SingleCells
        config = BirchBeer.Types.Config
                    {_birchLabelMap = labelMap
                    , _birchMinStep = minSize'
                    , _birchMaxStep = maxStep'
                    , _birchDrawLeaf = drawLeaf'
                    , _birchDrawPie = drawPie'
                    , _birchDrawMark = drawMark'
                    , _birchDrawNodeNumber = drawNodeNumber'
                    , _birchDrawMaxNodeSize = drawMaxNodeSize'
                    , _birchDrawNoScaleNodes = drawNoScaleNodes'
                    , _birchDrawColors = drawColors'
                    , _birchDend = _clusterDend originalClusterResults
                    , _birchMat = birchMat
                    }

    (plot, labelColorMap, itemColorMap, markColorMap, dend', gr') <- mainDiagram config

    -- Write results.
    clusterResults <- case prior' of
        Nothing -> do
            let clusterList' = dendrogramToClusterList dend'
                cr' = ClusterResults clusterList' dend'

            b <- bMat

            writeMatrix (unOutputDirectory output' FP.</> "b.mtx")
                . spMatToMat
                . unB
                $ b
            B.writeFile
                (unOutputDirectory output' FP.</> "cluster_results.json")
                . A.encode
                $ cr'
            T.writeFile
                (unOutputDirectory output' FP.</> "graph.dot")
                . G.printDotGraph
                . G.graphToDot G.nonClusteredParams
                . unClusterGraph
                $ gr'
            B.writeFile
                (unOutputDirectory output' FP.</> "cluster_info.csv")
                . printClusterInfo
                $ gr'
            case labelMap of
                Nothing   -> return ()
                (Just lm) ->
                    B.writeFile
                        (unOutputDirectory output' FP.</> "cluster_diversity.csv")
                        . printClusterDiversity order' lm
                        $ cr'

            return cr'

        (Just x) -> do
            let crInput = (FP.</> "cluster_results.json") . unPriorPath $ x
                ciInput = (FP.</> "cluster_info.csv") . unPriorPath $ x
                cdInput = (FP.</> "cluster_diversity.csv") . unPriorPath $ x
                bInput  = (FP.</> "b.mtx") . unPriorPath $ x
                grInput  = (FP.</> "graph.dot") . unPriorPath $ x

            let clusterList' = dendrogramToClusterList dend'
                cr' = ClusterResults clusterList' dend'

            -- Write results to files.
            FP.copyFile bInput
                . (FP.</> "b.mtx")
                . unOutputDirectory
                $ output'

            case (minSize', maxStep') of
                (Nothing, Nothing) -> do
                    FP.copyFile crInput
                        . (FP.</> "cluster_results.json")
                        . unOutputDirectory
                        $ output'
                    FP.copyFile grInput
                        . (FP.</> "graph.dot")
                        . unOutputDirectory
                        $ output'
                    FP.copyFile ciInput
                        . (FP.</> "cluster_info.csv")
                        . unOutputDirectory
                        $ output'
                _ -> do
                    B.writeFile
                        (unOutputDirectory output' FP.</> "cluster_results.json")
                        . A.encode
                        $ cr'
                    T.writeFile
                        (unOutputDirectory output' FP.</> "graph.dot")
                        . G.printDotGraph
                        . G.graphToDot G.nonClusteredParams
                        . unClusterGraph
                        $ gr'
                    B.writeFile
                        (unOutputDirectory output' FP.</> "cluster_info.csv")
                        . printClusterInfo
                        $ gr'

            case labelMap of
                Nothing   -> return ()
                (Just lm) ->
                    B.writeFile
                        (unOutputDirectory output' FP.</> "cluster_diversity.csv")
                        . printClusterDiversity order' lm
                        $ cr'

            return cr'

    -- Header
    B.putStrLn $ "cell,cluster,path"

    -- Body
    B.putStrLn
        . CSV.encode
        . fmap (\ (!ci, !(c:cs))
                -> ( unCell . barcode $ ci
                , showt $ unCluster c
                , T.intercalate "/" . fmap (showt . unCluster) $ c:cs
                )
                )
        . _clusterList
        $ clusterResults

    -- Plot only if needed and ignore non-tree analyses if dendrogram is
    -- supplied.
    H.runRegion $ do
        -- Calculations with the label map (clumpiness and cluster diversity).
        case labelMap of
            Nothing ->
                H.io $ hPutStrLn stderr "Clumpiness requires labels for cells, skipping..."
            (Just lm) -> do
                -- Get clumpiness.
                let clumpList = dendToClumpList clumpinessMethod' lm
                              . _clusterDend
                              $ clusterResults

                -- Plot clumpiness.
                plotClumpinessHeatmapR
                    (unOutputDirectory output' FP.</> "clumpiness.pdf")
                    clumpList

                -- Save clumpiness to a file.
                H.io
                    . B.writeFile (unOutputDirectory output' FP.</> "clumpiness.csv")
                    . clumpToCsv
                    $ clumpList

                H.io
                    . B.writeFile (unOutputDirectory output' FP.</> "cluster_diversity.csv")
                    . printClusterDiversity order' lm
                    $ clusterResults

        -- Plot.
        H.io $ do
            -- cr <- clusterResults
            -- gr <- graph
            -- cm <- itemColorMap

            -- plot <- if drawDendrogram'
            --         then return . plotDendrogram legend drawLeaf' cm . _clusterDend $ cr
            --         else do
            --             plotGraph legend drawConfig cm markColorMap gr

            D.renderCairo
                    (unOutputDirectory output' FP.</> "dendrogram.pdf")
                    (D.mkHeight 1000)
                    plot

        -- Plot clustering.
        plotClustersR (unOutputDirectory output' FP.</> "projection.pdf")
            . _clusterList
            $ clusterResults
            -- >>= D.renderCairo (x <> ".pdf") (D.mkWidth 1000)
            -- . D.renderAxis
            -- . plotClusters

        return ()

-- | Interactive tree interface.
interactiveMain :: Options -> IO ()
interactiveMain opts = H.withEmbeddedR defaultConfig $ do
    let labelsFile'    =
            fmap LabelFile . unHelpful . labelsFile $ opts
        prior'         = maybe (error "Requires --prior") PriorPath
                       . unHelpful
                       . prior
                       $ opts
        delimiter'     =
            Delimiter . fromMaybe ',' . unHelpful . delimiter $ opts
        normalization' =
            maybe B1Norm read . unHelpful . normalization $ opts

        processedSc = loadAllSSM opts

    labelMap <- sequence . fmap (loadLabelData delimiter') $ labelsFile'

    let crInput = (FP.</> "cluster_results.json") . unPriorPath $ prior'

    fullCr <- fmap (either error id . A.eitherDecode) . B.readFile $ crInput

    let dend = _clusterDend fullCr

    mat <- processedSc

    interactiveDiagram dend labelMap $ Just mat

    return ()

-- | Differential path.
differentialMain :: Options -> IO ()
differentialMain opts = do
    let nodes'    = DiffNodes . read . unHelpful . nodes $ opts
        prior'    = PriorPath
                  . fromMaybe (error "Requires a previous run to get the graph.")
                  . unHelpful
                  . prior
                  $ opts
        topN'     = TopN . fromMaybe 100 . unHelpful . topN $ opts

    processedSc <- loadAllSSM opts

    let crInput = (FP.</> "cluster_results.json") . unPriorPath $ prior'
        cr :: IO ClusterResults
        cr = fmap (either error id . A.eitherDecode)
            . B.readFile
            $ crInput

    gr <- fmap (dendrogramToGraph . _clusterDend) cr

    H.withEmbeddedR defaultConfig $ H.runRegion $ do
        res <- getDEGraph
                topN'
                processedSc
                (fst . unDiffNodes $ nodes')
                (snd . unDiffNodes $ nodes')
                gr

        H.io . putStrLn . getDEString $ res

-- | Diversity path.
diversityMain :: Options -> IO ()
diversityMain opts = do
    let priors'         =
            fmap PriorPath . unHelpful . priors $ opts
        output'         =
            OutputDirectory . fromMaybe "out" . unHelpful . output $ opts
        order'       = Order . fromMaybe 1 . unHelpful . order $ opts
        start'       = Start . fromMaybe 0 . unHelpful . start $ opts
        interval'    = Interval . fromMaybe 1 . unHelpful . interval $ opts
        endMay'      = fmap End . unHelpful . end $ opts

    -- Where to place output files.
    FP.createDirectoryIfMissing True . unOutputDirectory $ output'

    pops <- sequence
          . fmap (\x -> do
                            pop <- fmap (L.view L._1) . loadPopulation $ x
                            return (Label . T.pack . unPriorPath $ x , pop)
                 )
          $ priors'

    popDiversities <-
        mapM
            (\ (l, pop) -> getPopulationDiversity
                                l
                                order'
                                start'
                                interval'
                                endMay'
                                pop
            )
            pops

    D.renderCairo (unOutputDirectory output' FP.</> "diversity.pdf") D.absolute
        . plotDiversity
        $ popDiversities

    D.renderCairo (unOutputDirectory output' FP.</> "chao1.pdf") D.absolute
        . plotChao1
        $ popDiversities

    D.renderCairo (unOutputDirectory output' FP.</> "rarefaction.pdf") D.absolute
        . plotRarefaction
        $ popDiversities

    P.file (unOutputDirectory output' FP.</> "diversity_py.pdf")
        . plotDiversityPy
        $ popDiversities

    P.file (unOutputDirectory output' FP.</> "chao1_py.pdf")
        . plotChao1Py
        $ popDiversities

    P.file (unOutputDirectory output' FP.</> "rarefaction_py.pdf")
        . plotRarefactionPy
        $ popDiversities

    H.withEmbeddedR defaultConfig $ H.runRegion $ do
        let divFile = unOutputDirectory output' FP.</> "diversity_r.pdf"
        divPlot <- plotDiversityR popDiversities
        [r| ggsave(divPlot_hs, file = divFile_hs) |]

        let chao1File = unOutputDirectory output' FP.</> "chao_r.pdf"
        chao1Plot <- plotChao1R popDiversities
        [r| ggsave(chao1Plot_hs, file = chao1File_hs) |]

        let rarefactionFile = unOutputDirectory output' FP.</> "rarefaction_r.pdf"
        rarefactionPlot <- plotRarefactionR popDiversities
        [r| ggsave(rarefactionPlot_hs, file = rarefactionFile_hs) |]

        return ()

    return ()

main :: IO ()
main = do
    opts <- getRecord "too-many-cells, Gregory W. Schwartz.\
                      \ Clusters and analyzes single cell data."

    case opts of
        (MakeTree _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _) -> makeTreeMain opts
        (Interactive _ _ _ _ _ _ _ _)                      -> interactiveMain opts
        (Differential _ _ _ _ _ _ _ _)                     -> differentialMain opts
        (Main.Diversity _ _ _ _ _ _)                       -> diversityMain opts
