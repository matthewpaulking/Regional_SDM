# File: 1_pointsInPolys_cleanBkgPts.r
# Purpose: 
# 1. Sampling of EDM polygons to create random points within the polygons.
#  these are the random presence points being created here, from polygon presence data.
# 2. Removing any points from the background points dataset that overlap or are near
#  the input presence polygon dataset.
library(RSQLite)
library(sf)
library(dplyr)

####
# Assumptions
# - the shapefile is named with the species code that is used in the lookup table
#   e.g. glypmuhl.shp
# - There is lookup data in the sqlite database to link to other element information (full name, common name, etc.)
# - the polygon shapefile has at least these fields EO_ID_ST, SNAME, SCOMNAME, RA

####
#### load input polys ----

setwd(loc_model)

# set up folder system for inputs
dir.create(paste0(model_species,"/inputs/presence"), recursive = T, showWarnings = F)
dir.create(paste0(model_species,"/inputs/model_input"), showWarnings = F)

# setwd(paste0(loc_model,"/",model_species,"/inputs/presence"))
# changing to this WD temporarily allows for presence file to be either in presence folder or specified with full path name

# load data, QC ----
presPolys <- st_zm(st_read(nm_presFile, quiet = T))

#check for proper column names. If no error from next code block, then good to go
#presPolys$RA <- presPolys$SFRACalc
shpColNms <- names(presPolys)
desiredCols <- c("UID", "GROUP_ID", "SPECIES_CD", "RA", "OBSDATE")
if("FALSE" %in% c(desiredCols %in% shpColNms)) {
	  stop(paste0("Column(s) are missing or incorrectly named: ", paste(desiredCols[!desiredCols %in% shpColNms], collapse = ", ")))
  } else {
    print("Required columns are present")
  }

if(any(is.na(presPolys[,c("UID", "GROUP_ID", "SPECIES_CD", "RA")]))) {
  stop("The columns 'UID','GROUP_ID','SPECIES_CD', and 'RA' (SFRACalc) cannot have NA values.")
}

#pare down columns
presPolys <- presPolys[,desiredCols]

# set date/year column to [nearest] year, rounding when day is given
presPolys$OBSDATE <- as.character(presPolys$OBSDATE)
presPolys$date <- NA
for (d in 1:length(presPolys$OBSDATE)) {
  dt <- NA
  do <- presPolys$OBSDATE[d]
  if (grepl("^[0-9]{4}.{0,3}$", do)) {
    # year only formats
    dt <- as.numeric(substring(do,1,4))
  } else {
    if (grepl("^[0-9]{4}[-|/][0-9]{1,2}[-|/][0-9]{1,2}", do)) {
      # ymd formats
      try(dt <- as.Date(do), silent = TRUE)
    } else if (grepl("^[0-9]{1,2}[-|/][0-9]{1,2}[-|/][0-9]{4}", do)) {
      # mdy formats
      try(dt <- as.Date(do, format = "%m/%d/%Y"), silent = TRUE)
    }
    # if still no match, or if failed
    if (is.na(dt)) {
      if (grepl("[0-9]{4}", do)) {
        # use first 4-digit sequence as year
        dt <- regmatches(do, regexpr("[0-9]{4}", do))
        if (as.integer(dt) < 1900 | as.integer(dt) > format(Sys.Date(), "%Y")) {
          # years before 1900 and after current year get discarded
          dt <- Sys.Date()
        } else {
          dt <- as.Date(paste0(dt,"-01-01"))
        }
      }
      # put additional date formats here
    }
    # give up and assign current date
    if (is.na(dt)) {
      dt <- Sys.Date()
    }
    dt <- round(as.numeric(format(dt, "%Y")) + (as.numeric(format(dt,"%j"))/365.25))
  }
  presPolys$date[d] <- dt
}
desiredCols <- c(desiredCols, "date")

# explode multi-part polys ----
suppressWarnings(shp_expl <- st_cast(presPolys, "POLYGON"))

#add some columns (explode id and area)
shp_expl <- cbind(shp_expl, 
                       EXPL_ID = 1:length(shp_expl$geometry), 
                       AREAM2 = st_area(shp_expl))
names(shp_expl$geometry) <- NULL # temp fix until sf patches error

#write out the exploded polygon set

nm.PyFile <- paste(loc_model, model_species,"inputs/presence",paste0(baseName, "_expl.shp"), sep = "/")
st_write(shp_expl, nm.PyFile, driver="ESRI Shapefile", delete_layer = TRUE)

####
####  Placing random points within each sample unit (polygon/EO) ----
####

# just in case convert to lower
names(shp_expl) <- tolower(names(shp_expl))

#calculate Number of points for each poly, stick into new field
shp_expl$PolySampNum <- round(400*((2/(1+exp(-(as.numeric(shp_expl$aream2)/900+1)*0.004)))-1))
#make a new field for the design, providing a stratum name
shp_expl <- cbind(shp_expl, "stratum" = paste("poly_",shp_expl$expl_id, sep=""))

# sample must be equal or larger than the RA sample size in the random forest model
shp_expl$ra <- factor(tolower(as.character(shp_expl$ra)))

# QC step: are any records attributed with values other than these?
raLevels <- c("very high", "high", "medium", "low", "very low")
if("FALSE" %in% c(shp_expl$ra %in% raLevels)) {
  stop("at least one record is not attributed with RA appropriately")
} else {
  print("RA levels attributed correctly")
}


#EObyRA <- unique(shp_expl[,c("expl_id", "group_id","ra")])
shp_expl$minSamps[shp_expl$ra == "very high"] <- 5
shp_expl$minSamps[shp_expl$ra == "high"] <- 4
shp_expl$minSamps[shp_expl$ra == "medium"] <- 3
shp_expl$minSamps[shp_expl$ra == "low"] <- 2
shp_expl$minSamps[shp_expl$ra == "very low"] <- 1

shp_expl$finalSampNum <- ifelse(shp_expl$PolySampNum < shp_expl$minSamps, 
                                shp_expl$minSamps, 
                                shp_expl$PolySampNum)

ranPts <- st_sample(shp_expl, size = shp_expl$finalSampNum * 2)
ranPts.sf <- st_sf(ranPts)
names(ranPts.sf) <- "geometry"
st_geometry(ranPts.sf) <- "geometry"

ranPts.joined <- st_join(ranPts.sf, shp_expl)

# check for polys that didn't get any points
polysWithNoPoints <- shp_expl[!shp_expl$expl_id %in% ranPts.joined$expl_id,]
if(nrow(polysWithNoPoints) > 0){
  stop("One or more polygons didn't get any points placed in them.")
}

#  remove extras using straight table work

# this randomly assigns digits to each point by group (stratum) then next row only takes 
# members in group that are less than target number of points
rndid <- with(ranPts.joined, ave(expl_id, stratum, FUN=function(x) {sample.int(length(x))}))
ranPts.joined2 <- ranPts.joined[rndid <= ranPts.joined$finalSampNum,]

# get actual finalSampNum
#ranPts.joined2 <- ranPts.joined[0,]
# #### this is slow! ####
# for (ex in 1:length(shp_expl$geometry)) {
#   s1 <- shp_expl[ex,]
#   samps <- row.names(ranPts.joined[ranPts.joined$expl_id==s1$expl_id,])
#   if (length(samps) > s1$finalSampNum) samps <- sample(samps, size = s1$finalSampNum) # samples to remove
#   ranPts.joined2 <- rbind(ranPts.joined2, ranPts.joined[samps,])
# }
ranPts.joined <- ranPts.joined2
#rm(ex, s1, samps, ranPts.joined2)
rm(rndid, ranPts.joined2)

#check for cases where sample smaller than requested
# how many points actually generated?
ptCount <- table(ranPts.joined$expl_id)
targCount <- shp_expl[order(shp_expl$expl_id),"finalSampNum"]
overUnderSampled <- ptCount - targCount$finalSampNum

#positive vals are oversamples, negative vals are undersamples
print(table(overUnderSampled))
# If you get large negative values then there are many undersamples and 
# exploration might be worthwhile

names(ranPts.joined) <- tolower(names(ranPts.joined))

colsToKeep <- c("stratum", tolower(desiredCols))
ranPts.joined <- ranPts.joined[,colsToKeep]

# name of random points output shapefile
nm.RanPtFile <- paste(loc_model, model_species,"inputs/presence",paste(baseName, "_RanPts.shp", sep = ""), sep = "/")
# write it out
st_write(ranPts.joined, nm.RanPtFile, driver="ESRI Shapefile", delete_layer = TRUE)

###
### remove Coincident Background points ----
###

# get range info from the DB (as a list of HUCs)
db <- dbConnect(SQLite(),dbname=nm_db_file)
SQLquery <- paste0("SELECT huc10_id from lkpRange
                   inner join lkpSpecies on lkpRange.EGT_ID = lkpSpecies.EGT_ID
                   where lkpSpecies.sp_code = '", model_species, "';")
hucList <- dbGetQuery(db, statement = SQLquery)$huc10_id
dbDisconnect(db)
rm(db)

op <- options()
options(useFancyQuotes = FALSE) #need straight quotes for query
# get the background data from the DB
db <- dbConnect(SQLite(), nm_bkgPts[1])
qry <- paste0("SELECT * from ", nm_bkgPts[2], " where substr(huc12,1,10) IN (", paste(sQuote(hucList), collapse = ", ", sep = "")," );")
bkgd <- dbGetQuery(db, qry)
tcrs <- dbGetQuery(db, paste0("SELECT proj4string p from lkpCRS where table_name = '", nm_bkgPts[2], "';"))$p
samps <- st_sf(bkgd, geometry = st_as_sfc(bkgd$wkt, crs = tcrs))
options(op)
rm(op)

# reduce the number of bkg points if huge
# use the greater of 20 * pres points or 50,000
bkgTarg <- max(nrow(ranPts.joined) * 20, 50000)
if(nrow(samps) > bkgTarg){
  samps <- samps[sample(nrow(samps), bkgTarg),]
}

# find coincident points ----
polybuff <- st_transform(shp_expl, st_crs(samps))
polybuff <- st_buffer(polybuff, dist = 30)

coincidentPts <- unlist(st_contains(polybuff, samps, sparse = TRUE))

# remove them (if any)
if (length(coincidentPts) > 0) backgSubset <- samps[-coincidentPts,] else backgSubset <- samps

#write it up and do join in sqlite (faster than downloading entire att set)
st_geometry(backgSubset) <- NULL
tmpTableName <- paste0(nm_bkgPts[2], "_", baseName)
dbWriteTable(db, tmpTableName, backgSubset, overwrite = TRUE)

# do the join, get all the data back down
qry <- paste0("SELECT * from ", tmpTableName, " INNER JOIN ", nm_bkgPts[2], "_att on ",
              tmpTableName,".fid = ", nm_bkgPts[2], "_att.fid;")
bgSubsAtt <- dbGetQuery(db, qry)
# delete the table on the db
dbRemoveTable(db, tmpTableName)
dbDisconnect(db)

# # remove NAs #### convert this to removing columns instead?
# bgSubsAtt$bulkDens <- as.numeric(bgSubsAtt$bulkDens)
# bgSubsAtt$clay <- as.numeric(bgSubsAtt$clay) 
# bgSubsAtt$soil_pH <- as.numeric(bgSubsAtt$soil_pH) 
# bgSubsAtt$flowacc <- as.numeric(bgSubsAtt$flowacc) 
# 
# bgSubsAtt <- bgSubsAtt[complete.cases(bgSubsAtt),]
# nrow(bgSubsAtt)

dbName <- paste0(loc_model, "/", model_species, "/inputs/model_input/", baseName, "_att.sqlite")
db <- dbConnect(SQLite(), dbName)
dbWriteTable(db, paste0(nm_bkgPts[2], "_clean"), bgSubsAtt, overwrite = TRUE)

dbDisconnect(db)

rm(db, do, dt, qry, tmpTableName)
