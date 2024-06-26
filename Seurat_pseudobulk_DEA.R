#' Function to separate single-cell data by a factor of interest and create 
#'  pseudo-bulk datasets by combining matrices for each factor
#' followed by DEA with DESeq2   
#'
#' currently supports only single-factor designs
#' @param object
#' @param design
#' @param splitCells
#' @param skip
#' @param cellFactor
#' @param organism
#' @param geneVar
#' @param outDir
#' @param outPrefix
#' @param sortDirection
#' @param minCells
#' @param cores
#' @param fit_type
#' @param genomePrefix
#' @param cell_mappings
#' @return 
#' @import Seurat
#' @import DESeq2
#' @import biomaRt
#' @import future
#' @import BiocParallel
#' @export 
  
bulkDEA = function(object, #seurat object
                   metaData, #metadata mapping samples to factors. Rownames are sample names.
                   design, #design string for DESeq
                   splitCells = T, #whether or not to split by cell type (or whatever)
                   skip = NA, #if splitting cells, which factors should be skipped? Defaults to none.
                   cellFactor = NULL, #name of the cell-type column
                   organism, #in ensembl format, e.g. mmusculus
                   geneVar, #type of gene ID used, in biomart format e.g. ensembl_gene_id
                   outDir, #directory to output results
                   outPrefix, #file prefix for results files
                   sortDirection = c("descending", "ascending"), #direction to sort comparisons: alphabetical "ascending" or reverse "descending"
                   minCells = 50, #whether or not to override the minimum number of cells/samples
                   cores = 1, #cores to run in parallel
                   fit_type = "parametric", #to control dispersion fitting
                   genomePrefix = NA, # regular expression of genome prefixe(s) on gene names for removal and better binding downstream
                   cell_mappings = NULL) #optional data frame to redefine samples from individual cell IDs rather than just prefix. Rownames are cell IDs.
{
   register(BPPARAM = MulticoreParam(cores))
   dateString = format(Sys.Date(), "%y%m%d")
   if(!dir.exists(outDir))
      dir.create(outDir)
   setwd(outDir)
   
   compFactor = colnames(metaData)[1] # the factor we will be comparing by
   sortDirection = match.arg(sortDirection)
   shouldDecrease = (sortDirection == "descending")
   
   #make mart for conversion
   mart = useMart("ensembl", paste0(organism, "_gene_ensembl"))
   conv = getBM(attributes = c("ensembl_gene_id", "entrezgene_id", "external_gene_name"), mart = mart)
   
   # keep track of number of samples per condition
   completeMetadata = metaData
   
   #handle sample IDs
   if(is.null(cell_mappings))
   {
     allSamples = sort(unique(substr(rownames(object@meta.data), 1, (regexpr("\\_+[ATCG]", rownames(object@meta.data)) - 1))))
   } else
   {
     allSamples = unique(cell_mappings[, 1])
   }
   sampleData = matrix(nrow = 0, ncol = (length(allSamples) + 1)) # keeps track of number of cells per condition
   sampleDataCols = c("cellType", paste0("Ncells_", allSamples))
   colnames(sampleData) = sampleDataCols
   sampleData = as.data.frame(sampleData)
   
   bulkSampleData = matrix(nrow = 0, ncol = (length(unique(metaData[ , 1])) + 1)) #keep track of number of biological replicates per condition
   bulkSampleDataCols = c("cellType", paste0("Nsamples_", sort(unique(as.character(metaData[ , 1])))))
   colnames(bulkSampleData) = bulkSampleDataCols
   bulkSampleData = as.data.frame(bulkSampleData)
   
   
   cellTypes = c(levels(factor(object@meta.data[ , cellFactor])))
   cellTypes = setdiff(cellTypes, skip)
   for(cell in cellTypes)
   {
      message(cell)
      metaData = completeMetadata #reset for each round
      
      cell_sub = object
      if(cell != "all_cells" && splitCells) #for all cells, keep whole dataset
         cell_sub = cell_sub[ , cell_sub@meta.data[ , cellFactor] == cell]
      
      #now get joined counts matrices
      counts = round(as.matrix(cell_sub@assays$RNA@counts)) # raw counts
      sd = cell
      for(sample in allSamples) #get number of cells for each (zero therefore means not present)
      {
        if(is.null(cell_mappings))
        {
          sd = c(sd, sum(grepl(sample, colnames(cell_sub))))
        } else
        {
          sd = c(sd, sum(cell_sub@meta.data[, colnames(cell_mappings)[1]] == sample))
        }
      }
      samples = allSamples[as.numeric(sd[2:length(sd)]) >= minCells] # need at least 50 cells to get a real picture
      sampleData$cellType = as.character(sampleData$cellType)
      sampleData = rbind(sampleData, sd)
      colnames(sampleData) = sampleDataCols #necessary on first pass (but harmless afterward)
      
      # make sure comparison is even worth it
      metaData = subset(metaData, rownames(metaData) %in% samples)
      if(length(unique(metaData[, 1])) < 2) # skip if we can't make any comparisons
      {
         warning("Skipped -- not enough samples")
         next
      }      
      #remove factors with fewer than 2 samples
      bulkN = table(metaData[, 1])
      bulkN = data.frame(sample = names(bulkN), N = as.numeric(bulkN))
      bulkN = bulkN[order(bulkN$sample), ]
      keep = bulkN[bulkN$N >= 2, ]$sample
      if(length(keep) > 1)
      {
         cell_sub = cell_sub[ , cell_sub@meta.data[ , compFactor] %in% keep]
      } else
      {
         warning("Skipped -- not enough samples")
         next #no need to continue with analysis in this case
      }
      
      #update sample Ns
      bulkN$N[bulkN$N < 2] = NA
      bulkSampleData$cellType = as.character(bulkSampleData$cellType) #necessary on first pass (but harmless afterward)
      bulkSampleData = rbind(bulkSampleData, c(cell, bulkN$N))
      colnames(bulkSampleData) = bulkSampleDataCols #necessary on first pass (but harmless afterward)
      
      joinedMat = matrix(data = NA, nrow = nrow(counts), ncol = length(samples))
      rownames(joinedMat) = rownames(counts)
      colnames(joinedMat) = samples
      for(sample in samples)
      {
        if(is.null(cell_mappings))
        {
          sampleMat = counts[ , grepl(sample, colnames(counts))]
        } else
        {
          sampleCells = colnames(cell_sub)[cell_sub@meta.data[, colnames(cell_mappings)[1]] == sample]
          sampleMat = counts[, sampleCells]
        }
         sampleCounts = rowSums(sampleMat)
         joinedMat[, sample] = sampleCounts
      }
      
      #now for DEA
      stopifnot(class(design) == "formula") #calling formula in function causes massive problems. Avoid by doing externally!
      joinedMat = joinedMat[, match(rownames(metaData), colnames(joinedMat))]
      des = DESeqDataSetFromMatrix(countData = joinedMat, colData = metaData, design = design)
      #safe for symbols
      outPath = paste(dateString, outPrefix, gsub("\\W", replacement = "-", cell), "subset", "des.rds", sep = "_")
      saveRDS(des, outPath)
      
      #if there is a zero in every gene, data become unreliable. Discard.
      if(all(rowSums(counts(des, normalized = F) == 0) > 0))
      {
        warning("Skipped -- Every gene contains at least one zero, cannot compute log geometric means")
        next
      }  
      
      dge = DESeq(des, parallel = T, fitType = fit_type)
      
      allFactors = sort(unique(as.character(metaData[, 1])), decreasing = shouldDecrease)
      allComps = combn(x = allFactors, m = 2, simplify = F) # every possible combination of ages; list of older, younger for each comp
      allComps = lapply(allComps, as.character) #otherwise we get factor levels!
      for(comp in allComps)
      {
         res = as.data.frame(results(dge, contrast = c(colnames(metaData)[1], comp[1], comp[2]), alpha = 0.05, parallel = T))
         res = rownames_to_column(res, var = geneVar)
         if(!is.null(genomePrefix) && geneVar == "external_gene_name")
         {
           res[, geneVar] = gsub(genomePrefix, "", res[, geneVar])
         }
         if(geneVar == "ensembl_gene_id")
         {
            res$ensembl_gene_id = ifelse(grepl("\\.", res$ensembl_gene_id),
                                         yes = substr(res$ensembl_gene_id, 1, (regexpr("\\.", res$ensembl_gene_id) - 1)),
                                         no = res$ensembl_gene_id) #remove version numbers
         }
         res = merge(res, conv, all.x = T)
         
         compName = paste(comp[1], "vs", comp[2], sep = "_")
         write.csv(res, paste(dateString, outPrefix, gsub("\\W", replacement = "-", cell), "subset", compName, "dge.csv", sep = "_"))
      }
   }
   
   #output sample statistics
   write.csv(sampleData, paste(dateString, outPrefix, "sampleData.csv", sep = "_"))
   write.csv(bulkSampleData, paste(dateString, outPrefix, "bulkSampleData.csv", sep = "_"))
}
      
         
         