## Make predictive grid for sdmTMB models
# 1) Prep bathymetric data based on chinTagging/R/prep_bathymetry 
# (ignore American data for now); use UTM to ensure equal spacing in grid with
# a resolution of 4 km (~ median tow length)
# 2) Back-convert to lat/lon to use coastdistance function
# 3) Combine and export
# Updated May 17, 2022
# Updated March 2, 2022


library(sf)
library(raster)
# library(rgdal)
library(tidyverse)
library(ncdf4)
# library(maptools)
library(rmapshaper)
library(mapdata)
library(rnaturalearth)
library(rnaturalearthdata)


# chinook dataset
dat_trim <- readRDS(here::here("data", "catch_survey_sbc.rds"))

# shapefiles for IPES survey grid and combined WCVI/IPES grid
ipes_grid_raw <- raster::shapefile(
  here::here("data", "spatial", "ipes_shapefiles", "IPES_Grid_UTM9.shp"))
ipes_wcvi_grid_raw <- raster::shapefile(
  here::here("data", "spatial", "wcvi_ipes_shapefiles", 
             "IPES_WCVI_boundary_UTM9.shp"))


# parallelize based on operating system (should speed up some of the spatial
# processing calculations)
library("parallel")
ncores <- detectCores() - 2
if (Sys.info()['sysname'] == "Windows") {
  library("doParallel")
  cl <- makeCluster(ncores)
  registerDoParallel(cl)
  big_bathy_path <- "C:/Users/FRESHWATERC/Documents/drive docs/spatial/BC NetCDF"
  creel_path <- "C:/Users/FRESHWATERC/Documents/drive docs/spatial/creel_areas/"
} else {
  doMC::registerDoMC(ncores)
  big_bathy_path <- "/Users/cam/Google Drive/spatial/BC NetCDF"
  creel_path <- "/Users/cam/Google Drive/spatial/creel_areas/"
}



## GENERATE BATHYMETRY RASTER _-------------------------------------------------

## import depth data from netcdf file for BC and US PNW
## UPDATE: switch to single integrated lower res file
# ncin <- nc_open(
#   paste(big_bathy_path, "british_columbia_3_msl_2013.nc", sep = "/"))
# ncin_us <- nc_open(
#   paste(big_bathy_path, "usgsCeCrm8_703b_754f_94dc.nc", sep = "/"))
ncin <- nc_open(
  paste(
    big_bathy_path, "gebco_2022_n58.9197_s47.033_w-137.9622_e-121.9747_ipes.nc",
    sep = "/"
  )
)

#specify lat/long
dep_list <- list(
  lon = ncvar_get(ncin, "lon"),
  lat = ncvar_get(ncin, "lat"),
  dep = ncvar_get(ncin, "elevation")
)

# function create dataframe
dep_dat_f <- function(x) {
  expand.grid(lon = x$lon, lat = x$lat) %>%
    as.matrix(.) %>%
    cbind(., depth = as.vector(x$dep)) %>%
    data.frame()
}

dep_dat_full <- dep_dat_f(dep_list) %>% 
  mutate(depth = -1 * depth) %>% 
  # remove land data
  filter(depth > 0)


# convert each to raster, downscale, and add terrain data to both
# then convert back to dataframes
bc_raster <- rasterFromXYZ(dep_dat_full, 
                           crs = sp::CRS("+proj=longlat +datum=WGS84"))
bc_raster_utm <- projectRaster(bc_raster,
                               crs = sp::CRS("+proj=utm +zone=9 +units=m"),
                               # convert to 1000 m resolution
                               res = 1000)
# bc_raster_utm2 <- projectRaster(bc_raster,
#                                crs = sp::CRS("+proj=utm +zone=9 +units=m"),
#                                # convert to 1000 m resolution
#                                res = 500)


# save RDS for manuscript figs
saveRDS(bc_raster, 
        here::here("data", "spatial", "full_coast_raster_latlon_1000m.RDS"))


plot(bc_raster_utm)
# plot(ipes_grid_raw, 
#      add = T,
#      border = "blue")
plot(ipes_wcvi_grid_raw, 
     add = T,
     border = "blue")


# crop to survey grid
dum <- crop(bc_raster_utm, extent(ipes_grid_raw))
ipes_raster_utm <- mask(dum, ipes_grid_raw)
wcvi_ipes_raster_utm <- mask(dum, ipes_wcvi_grid_raw)



# # merge and add aspect/slope
wcvi_ipes_raster_slope <- terrain(
  wcvi_ipes_raster_utm, opt = 'slope', unit = 'degrees',
  neighbors = 8
)
wcvi_ipes_raster_aspect <- terrain(
  wcvi_ipes_raster_utm, opt = 'aspect', unit = 'degrees',
  neighbors = 8
)
wcvi_ipes_raster_list <- list(
  depth = wcvi_ipes_raster_utm,
  slope = wcvi_ipes_raster_slope,
  aspect = wcvi_ipes_raster_aspect
)

ipes_raster_list <- purrr::map(wcvi_ipes_raster_list, function (x) {
  dum <- crop(x, extent(ipes_grid_raw))
  mask(dum, x)
})

saveRDS(bc_raster_utm,
        here::here("data", "spatial", "coast_raster_utm_1000m.RDS"))
saveRDS(ipes_raster_list,
        here::here("data", "spatial", "ipes_raster_utm_1000m.RDS"))



## GENERATE GRID ---------------------------------------------------------------

# import high res raster generated above
ipes_raster_list <- readRDS(
  here::here("data", "spatial", "ipes_raster_utm_1000m.RDS"))

ipes_sf_list <- purrr::map(
  ipes_raster_list,
  function (x) {
    # leave at 1km x 1km res for inlets
    # aggregate(x, fact = 2) %>% 
      as(x, 'SpatialPixelsDataFrame') %>%
      as.data.frame() %>%
      st_as_sf(., coords = c("x", "y"),
               crs = sp::CRS("+proj=utm +zone=9 +units=m"))
  }
)


# join depth and slope data
ipes_sf <- st_join(ipes_sf_list$depth, ipes_sf_list$slope) 

# coast sf for plotting and calculating distance to coastline 
# (has to be lat/lon for dist2Line)
coast <- rbind(rnaturalearth::ne_states( "United States of America", 
                                         returnclass = "sf"), 
               rnaturalearth::ne_states( "Canada", returnclass = "sf")) %>% 
  sf::st_crop(., 
              xmin = min(dat_trim$lon), ymin = 48, 
              xmax = max(dat_trim$lon), ymax = max(dat_trim$lat)) 

## convert to lat/lon for coast distance function 
ipes_sf_deg <- ipes_sf %>%
  st_transform(., crs = st_crs(coast))


# calculate distance to coastline
coast_dist <- geosphere::dist2Line(p = sf::st_coordinates(ipes_sf_deg),
                                   line = as(coast, 'Spatial'))

coast_utm <- coast %>% 
  sf::st_transform(., crs = sp::CRS("+proj=utm +zone=9 +units=m"))


# combine all data
ipes_grid <- data.frame(
  st_coordinates(ipes_sf[ , 1]),
  depth = ipes_sf$depth,
  slope = ipes_sf$slope,
  shore_dist = coast_dist[, "distance"]
)
# ipes_grid_trim <- ipes_grid %>% filter(!depth > 500)

# interpolate missing data 
ipes_grid_interp <- VIM::kNN(ipes_grid, k = 5)


ggplot() + 
  geom_sf(data = coast_utm) +
  geom_raster(data = ipes_grid, aes(x = X, y = Y, fill = depth)) +
  scale_fill_viridis_c() +
  # geom_point(data = dat_trim, aes(x = utm_x, y = utm_y),
  #            fill = "white",
  #            shape = 21) +
  ggsidekick::theme_sleek()


# subset WCVI predictive grid to make IPES only
ipes_grid_raw_sf <- st_read(
  here::here("data", "spatial", "ipes_shapefiles", "IPES_Grid_UTM9.shp"))

ipes_wcvi_sf <- st_as_sf(ipes_grid_interp %>% 
                           select(-ends_with("imp")),
                         coords = c("X", "Y"),
                         crs = st_crs(ipes_grid_raw_sf))

dd <- st_intersection(ipes_grid_raw_sf, ipes_wcvi_sf)

ipes_grid_only <- data.frame(
  st_coordinates(dd[ , 1]),
  depth = dd$depth,
  slope = dd$slope,
  shore_dist = dd$shore_dist
)

grid_list <- list(
  ipes_grid = ipes_grid_only,
  wcvi_grid = ipes_grid_interp %>% 
    select(-ends_with("imp"))
)


# export grid
saveRDS(grid_list,
        here::here("data", "spatial", "pred_ipes_grid.RDS"))
saveRDS(coast_utm, here::here("data", "spatial", "coast_trim_utm.RDS"))


