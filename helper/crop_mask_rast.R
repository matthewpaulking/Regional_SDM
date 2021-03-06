library(sf)
library(raster)
library(snow)
library(smoothr) 
#library(fasterize) # if using raster method for cropping instead of calling gdalwarp

# needs raster list (fullL), loc_envVars, model_species

# has the range already been created? If so, don't waste time re-creating
allRanges_fn <- paste0(loc_scripts, "/_data/other_spatial/feature/","Ranges_dissolved.gdb")
if(file.exists(allRanges_fn)) {
  allRanges <- st_read(allRanges_fn)
  targRange <- allRanges[allRanges$EGT_ID == ElementNames$EGT_ID,]
  #make sure a range actually got extracted above
  if(!is.na(st_dimension(targRange))){
    # rangeClipped <- targRange
    # fill holes/slivers
    rangeClipped <- fill_holes(targRange, threshold = units::set_units(10, km^2))
  }
}

# get the range the long way if rangeClipped didn't get created, above
if(!exists("rangeClipped")){
  # get range info from the DB (as a list of HUCs)
  db <- dbConnect(SQLite(),dbname=nm_db_file)
  SQLquery <- paste0("SELECT huc10_id from lkpRange
                     inner join lkpSpecies on lkpRange.EGT_ID = lkpSpecies.EGT_ID
                     where lkpSpecies.sp_code = '", model_species, "';")
  hucList <- dbGetQuery(db, statement = SQLquery)$huc10_id
  dbDisconnect(db)
  rm(db)
  
  # now get that info spatially
  nm_range <- nm_HUC_file
  qry <- paste("SELECT * from HUC10 where HUC10 IN ('", paste(hucList, collapse = "', '"), "')", sep = "")
  hucRange <- st_zm(st_read(nm_range, query = qry))
  
  # dissolve it
  rangeDissolved <- st_union(hucRange)
  # fill holes/slivers
  rangeDissHolesFilled <- fill_holes(rangeDissolved, threshold = units::set_units(10, km^2))
  # crop to CONUS boundary
  # use the dissolved version
  conus <- st_read(paste0(strsplit(nm_refBoundaries, "[.]")[[1]][[1]], "_dissolve.shp"))
  #conus <- st_read(nm_refBoundaries)
  rangeClipped <- st_intersection(rangeDissHolesFilled, conus)
  #dissolve again (if not using the dissolved version)
  #rangeDissolved_2 <- st_union(rangeClipped)
  # write out a dissolved version of hucRange for 'study area'

  rm(hucRange, rangeDissolved, rangeDissHolesFilled, conus)
}

#check if shape is valid
if(!st_is_valid(rangeClipped)){
  # st_make_valid not available to this install
  rangeClipped <- st_buffer(rangeClipped, 0)
}

st_write(rangeClipped, delete_dsn = TRUE,
         here("_data","species",model_species,"inputs","model_input",paste0(model_run_name, "_studyArea.gpkg")))

  
########################################
# hucRange <- st_zm(st_read(nm_studyAreaExtent,quiet = T)) #DNB TESTING ONLY

# crop/mask rasters to a temp directory 

# delete temp rasts folder, create new
temp <- paste0(options("rasterTmpDir")[1], "/", modelrun_meta_data$model_run_name)
if (dir.exists(temp)) {
  unlink(x = temp, recursive = TRUE, force = TRUE)
}
dir.create(temp, showWarnings = FALSE)

# get proj info from 1 raster
rtemp <- raster(paste0(loc_envVars,"/",fullL[[1]]))

# if debugging with already clipped rasters, paste the tmp path in
#newL <- lapply(fullL, FUN = function(x) paste0(temp,"/",x))

# clipping/masking boundary
rng <- st_transform(rangeClipped, crs = as.character(rtemp@crs))
#rm(rtemp)
rng <- st_sf(geometry = st_cast(st_union(rng), "POLYGON"))
rng$id <- 1:length(rng$geometry)
ext <- st_bbox(rng)

# write shapes
clipshp <- paste0(temp, "/", "clipshp.shp")
st_write(rng, dsn = temp, layer = "clipshp.shp", driver="ESRI Shapefile", delete_layer = TRUE, quiet = TRUE)

# if using raster crop methods, not gdalwarp ...
# convert clipping shape to raster for faster cropping
#rasExtent <- raster::crop(rtemp, extent(as(rng, "Spatial")))
#cropRas <- fasterize(rng, rasExtent)

# # cluster process rasters
cl <- snow::makeCluster(parallel::detectCores() - 3, type = "SOCK")
#snow::clusterExport(cl, list("temp", "cropRas"), envir = environment())
snow::clusterExport(cl, list("temp", "ext", "clipshp"), envir = environment())
snow::clusterExport(cl, list("loc_envVars"), envir = environment())

message("Creating raster subsets for species for ", length(fullL) , " environmental variables...")
newL <- snow::parLapply(cl, x = fullL, fun = function(path) {
  subnm <- gsub(paste0(loc_envVars,"/"), "", path)
  if (grepl("/",subnm)) {
    folderDepth <- length(gregexpr("/", subnm)[[1]])
    subdir <- paste(strsplit(subnm, "/", fixed = T)[[1]][1:folderDepth],collapse = "/")
    dir.create(paste0(temp, "/", subdir), showWarnings = FALSE, recursive = TRUE)
  }
  nnm <- paste0(temp, "/", subnm)
  #ras <- raster::raster(path) # read the raster
  #rasAtExtent <- raster::crop(ras, raster::extent(cropRas)) # crop extent to same as mask ras
  #outRas <- raster::mask(rasAtExtent, cropRas, filename = nnm) # mask it
  # crop w/clip using gdalwarp
  call <- paste0("gdalwarp -te ", paste(ext, collapse = " "), " -cutline ", clipshp, " ", path, " ", nnm, " -overwrite -q")
  system(call)
  return(nnm)
})
stopCluster(cl)
rm(cl)
closeAllConnections()

