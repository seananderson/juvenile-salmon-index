### Can fit parameters be recovered?
## Use simulated data generated by model in all_species_fit_season_mvrw to
## determine whether parameters can be recovered.
## Sep 27, 2023

# setup ---------------------------------------------------------------

# full run:
MCMC_ITER <- 110L
MCMC_WARMUP <- 100L
MCMC_CHAINS <- 25L
THIN <- 5L
CORES <- 25L
NSIM <- 100L

# testing:
# MCMC_ITER <- 10L
# MCMC_WARMUP <- 9L
# MCMC_CHAINS <- 1L
# THIN <- 1L
# CORES <- 1L
# NSIM <- 1L

RUN_MCMC <- FALSE
INDEX_CORES <- 20L

# end setup -----------------------------------------------------------

# remotes::install_github("https://github.com/pbs-assess/sdmTMB",
#   ref = "mvrfrw")

library(tidyverse)
library(sdmTMB)
library(ggplot2)
library(sdmTMBextra)

ncores <- parallel::detectCores()
future::plan(future::multisession, workers = 5L)

# make subdirectories for storage
dir.create("data/fits", recursive = TRUE, showWarnings = FALSE)


# downscale data and predictive grid
dat_in <- readRDS(here::here("data", "catch_survey_sbc.rds"))


# make year key representing pink/sockeye cycle lines
yr_key <- data.frame(
  year = unique(dat_in$year)
) %>%
  arrange(year) %>%
  mutate(
    sox_cycle = rep(1:4, length.out = 25L) %>%
      as.factor(),
    pink_cycle = rep(1:2, length.out = 25L) %>%
      as.factor()
  )

# downscale data and predictive grid
dat <- dat_in %>%
  mutate(
    year_f = as.factor(year),
    yday = lubridate::yday(date),
    utm_x_1000 = utm_x / 1000,
    utm_y_1000 = utm_y / 1000,
    effort = log(volume_km3 * 500),
    scale_dist = scale(as.numeric(dist_to_coast_km))[ , 1],
    scale_depth = scale(as.numeric(target_depth))[ , 1],
    day_night = as.factor(day_night)) %>%
  filter(!species == "steelhead") %>%
  droplevels() %>%
  left_join(., yr_key, by = "year")


## mesh shared among species
dat_coords <- dat %>%
  filter(species == "chinook") %>%
  select(utm_x_1000, utm_y_1000) %>%
  as.matrix()
inla_mesh_raw <- INLA::inla.mesh.2d(
  loc = dat_coords,
  max.edge = c(2, 10) * 500,
  cutoff = 30,
  offset = c(10, 50)
)
spde <- make_mesh(
  dat %>%
    filter(species == "chinook"),
  c("utm_x_1000", "utm_y_1000"),
  mesh = inla_mesh_raw
)


dat_tbl <- dat %>%
  group_by(species) %>%
  group_nest()


index_grid_hss <- readRDS(here::here("data", "index_hss_grid.rds")) %>%
  mutate(day_night = as.factor(day_night),
         trim = ifelse(
           season_f == "wi" & utm_y_1000 < 5551, "yes", "no"
         )) %>%
  #subset to northern domain
  filter(trim == "no") %>%
  left_join(., yr_key, by = "year")

sp_scalar <- 1 * (13 / 1000) * 500

# fitted model from all_species_fit.R
all_fit_tbl <- readRDS(
  here::here("data", "fits", "all_spatial_varying_nb2_mvrfrw_final.rds")
)


## FIT MODEL TO EACH SPECIES ---------------------------------------------------

dat_tbl$fit <- furrr::future_map2(
  dat_tbl$data, dat_tbl$species,
  function(dat_in, sp) {
    if (sp == "pink") {
      sdmTMB(
        n_juv ~ 0 + season_f + day_night + survey_f + scale_dist +
          scale_depth + pink_cycle,
        offset = dat_in$effort,
        data = dat_in,
        mesh = spde,
        family = sdmTMB::nbinom2(),
        spatial = "off",
        spatial_varying = ~ 0 + season_f,
        time = "year",
        spatiotemporal = "rw",
        anisotropy = TRUE,
        groups = "season_f",
        control = sdmTMBcontrol(
          map = list(
            ln_tau_Z = factor(
              rep(1, times = length(unique(dat$season_f)))
            )
          )
        ),
        silent = FALSE
      )
    } else if (sp == "sockeye") {
      sdmTMB(
        n_juv ~ 0 + season_f + day_night + survey_f + scale_dist +
          scale_depth + sox_cycle,
        offset = dat_in$effort,
        data = dat_in,
        mesh = spde,
        family = sdmTMB::nbinom2(),
        spatial = "off",
        spatial_varying = ~ 0 + season_f,
        time = "year",
        spatiotemporal = "rw",
        anisotropy = TRUE,
        groups = "season_f",
        control = sdmTMBcontrol(
          map = list(
            ln_tau_Z = factor(
              rep(1, times = length(unique(dat$season_f)))
            )
          )
        ),
        silent = FALSE
      )
    } else {
      sdmTMB(
        n_juv ~ 0 + season_f + day_night + survey_f + scale_dist +
          scale_depth,
        offset = dat_in$effort,
        data = dat_in,
        mesh = spde,
        family = sdmTMB::nbinom2(),
        spatial = "off",
        spatial_varying = ~ 0 + season_f,
        time = "year",
        spatiotemporal = "rw",
        anisotropy = TRUE,
        groups = "season_f",
        control = sdmTMBcontrol(
          map = list(
            ln_tau_Z = factor(
              rep(1, times = length(unique(dat$season_f)))
            )
          )
        ),
        silent = FALSE
      )
    }
  }
)


## UPDATE MCMC DRAWS -----------------------------------------------------------

if (RUN_MCMC) {
  set.seed(456)
  purrr::map2(
    dat_tbl$fit, dat_tbl$species, function (x, y) {
      object <- x
      samp <- sample_mle_mcmc(
        object, mcmc_iter = MCMC_ITER, mcmc_warmup = MCMC_WARMUP, mcmc_chains = MCMC_CHAINS,
        stan_args = list(thin = THIN, cores = CORES)
      )
      obj <- object$tmb_obj
      random <- unique(names(obj$env$par[obj$env$random]))
      pl <- as.list(object$sd_report, "Estimate")
      fixed <- !(names(pl) %in% random)
      map <- lapply(pl[fixed], function(x) factor(rep(NA, length(x))))
      obj <- TMB::MakeADFun(obj$env$data, pl, map = map, DLL = "sdmTMB")
      obj_mle <- object
      obj_mle$tmb_obj <- obj
      obj_mle$tmb_map <- map
      sim_out <- simulate(
        obj_mle, mcmc_samples = sdmTMBextra::extract_mcmc(samp), nsim = NSIM
      )
      saveRDS(
        sim_out,
        here::here("data", "fits",
          paste(y, "_mcmc_draws_nb2_mvrfrw.rds", sep = ""))
      )
    }
  )
}

dat_tbl$sims <- purrr::map(
  dat_tbl$species,
  ~ readRDS(
    here::here("data", "fits",
               paste(.x, "_mcmc_draws_nb2_mvrfrw.rds", sep = ""))
  )
)


# make a tibble for each species simulations
sim_tbl <- purrr::pmap(
  list(dat_tbl$species, dat_tbl$fit, dat_tbl$sims),
  function (sp, fits, x) {
    tibble(
      species = sp,
      iter = seq(1, ncol(x), by = 1),
      sim_dat = lapply(seq_len(ncol(x)), function(i) {
        # use fits instead of data in tibble because mismatched from extra_time
        fits$data %>%
          mutate(sim_catch = x[ , i])
      })
    )
  }
) %>%
  bind_rows() %>%
  left_join(.,
            dat_tbl %>% select(species, fit),
            by = c("species"))


## FIT SIMS  -------------------------------------------------------------------

gc()
dir.create(here::here("data", "fits", "sim_fit"), showWarnings = FALSE)
# fit model to species

sp_vec <- unique(sim_tbl$species)

future::plan(future::multisession, workers = INDEX_CORES)
# if (FALSE) {
for (i in seq_along(sp_vec)) {
  sim_tbl_sub <- sim_tbl %>% filter(species == sp_vec[i])
  furrr::future_pmap(
    # purrr::pmap(
    list(sim_tbl_sub$sim_dat, sim_tbl_sub$fit, sim_tbl_sub$iter),
    function (x, fit, iter) {

      file_name <- paste(sp_vec[i], "_", iter, "_pars.rds", sep = "")
      file_name2 <- paste(sp_vec[i], "_", iter, "_index.rds", sep = "")

      if (!file.exists(file_name) || !file.exists(file_name2)) {
        if (sp_vec[i] %in% c("chinook", "coho", "chum")) {
          sim_fit <- sdmTMB(
            sim_catch ~ 0 + season_f + day_night + survey_f + scale_dist +
              scale_depth,
            offset = x$effort,
            data = x,
            mesh =  fit$spde,
            family = sdmTMB::nbinom2(),
            spatial = "off",
            spatial_varying = ~ 0 + season_f,
            time = "year",
            spatiotemporal = "rw",
            anisotropy = TRUE,
            groups = "season_f",
            control = sdmTMBcontrol(
              map = list(
                ln_tau_Z = factor(
                  rep(1, times = length(unique(x$season_f)))
                )
              )
            ),
            silent = FALSE
          )
        } else if (sp_vec[i] == "pink") {
          sim_fit <- sdmTMB(
            sim_catch ~ 0 + season_f + day_night + survey_f + scale_dist +
              scale_depth + pink_cycle,
            offset = x$effort,
            data = x,
            mesh = spde,
            family = sdmTMB::nbinom2(),
            spatial = "off",
            spatial_varying = ~ 0 + season_f,
            time = "year",
            spatiotemporal = "rw",
            anisotropy = TRUE,
            groups = "season_f",
            control = sdmTMBcontrol(
              map = list(
                ln_tau_Z = factor(
                  rep(1, times = length(unique(x$season_f)))
                )
              )
            ),
            silent = FALSE
          )
        } else if (sp_vec[i] == "sockeye") {
          sim_fit <- sdmTMB(
            sim_catch ~ 0 + season_f + day_night + survey_f + scale_dist +
              scale_depth + sox_cycle,
            offset = x$effort,
            data = x,
            mesh = spde,
            family = sdmTMB::nbinom2(),
            spatial = "off",
            spatial_varying = ~ 0 + season_f,
            time = "year",
            spatiotemporal = "rw",
            anisotropy = TRUE,
            groups = "season_f",
            control = sdmTMBcontrol(
              map = list(
                ln_tau_Z = factor(
                  rep(1, times = length(unique(x$season_f)))
                )
              )
            ),
            silent = FALSE
          )
        }
      }

      # recover pars
      fix <- tidy(sim_fit, effects = "fixed")
      ran <- tidy(sim_fit, effects = "ran_pars")

      # pull upsilon estimate separately (not currently generated by predict)
      est <- as.list(sim_fit$sd_report, "Estimate", report = TRUE)
      se <- as.list(sim_fit$sd_report, "Std. Error", report = TRUE)
      upsilon <- data.frame(
        term = "sigma_U",
        log_est = est$log_sigma_U,
        log_se = se$log_sigma_U
      ) %>%
        mutate(
          estimate = exp(log_est),
          std.error = exp(log_se)
        ) %>%
        select(term, estimate, std.error)

      pars <- rbind(fix, ran, upsilon) %>%
        # add unique identifier for second range term
        group_by(term) %>%
        mutate(
          iter = iter,
          par_id = row_number(),
          term = ifelse(par_id > 1, paste(term, par_id, sep = "_"), term)
        ) %>%
        ungroup()

      saveRDS(pars, here::here("data", "fits", "sim_fit", file_name))

      su_preds <- predict(
        sim_fit,
        newdata = index_grid_hss %>%
          filter(season_f == "su"),
        se_fit = FALSE, re_form = NULL, return_tmb_object = TRUE)
      su_index <- get_index(su_preds, area = sp_scalar, bias_correct = TRUE) %>%
        mutate(season_f = "su",
          species = sp_vec[i],
          iter = iter)
      fall_preds <- predict(
        sim_fit,
        newdata = index_grid_hss %>%
          filter(season_f == "wi"),
        se_fit = FALSE, re_form = NULL, return_tmb_object = TRUE
      )
      fall_index <- get_index(fall_preds, area = sp_scalar, bias_correct = TRUE) %>%
        mutate(season_f = "wi",
          species = sp_vec[i],
          iter = iter)

      saveRDS(rbind(su_index, fall_index),
        here::here("data", "fits", "sim_fit", file_name2))
    }
  )
}


## COMPARE PARAMETERS ----------------------------------------------------------


# parameters from original fit
fit_pars <- purrr::map2(
  all_fit_tbl$fit, all_fit_tbl$species, function (x, sp) {
    fix <- tidy(x, effects = "fixed")
    ran <- tidy(x, effects = "ran_pars")
    
    # pull upsilon estimate separately (not currently generated by predict)
    est <- as.list(x$sd_report, "Estimate", report = TRUE)
    se <- as.list(x$sd_report, "Std. Error", report = TRUE)
    upsilon <- data.frame(
      term = "sigma_U",
      log_est = est$log_sigma_U,
      log_se = se$log_sigma_U
    ) %>% 
      mutate(
        estimate = exp(log_est),
        std.error = exp(log_se) 
      ) %>% 
      select(term, estimate, std.error)
    
    rbind(fix, ran, upsilon) %>% 
      mutate(species = abbreviate(sp, minlength = 3)) %>% 
      # add unique identifier for second range term
      group_by(term) %>% 
      mutate(
        par_id = row_number(),
        term = ifelse(par_id > 1, paste(term, par_id, sep = "_"), term)
      ) %>% 
      ungroup()
  }
) %>% 
  bind_rows() %>% 
  mutate(
    species = abbreviate(species, minlength = 3),
    term = fct_recode(
      as.factor(term), 
      "diel" = "day_nightNIGHT", "depth" = "scale_depth",
      "dist" = "scale_dist",
      "spring_int" = "season_fsp", 
      "summer_int" = "season_fsu", "fall_int" = "season_fwi", 
      "survey_design" = "survey_fipes", "sigma_epsilon" = "sigma_U", 
      "sigma_omega" = "sigma_Z"
    ),
    term = fct_relevel(
      term, "diel", "depth", "dist", "survey_design", "spring_int", "summer_int",
      "fall_int", "pink_cycle2", "sox_cycle2", "sox_cycle3", "sox_cycle4", 
      "phi", "range", "sigma_omega", "sigma_epsilon"
    )
  )

sp_vec <- unique(all_fit_tbl$species)

sim_tbl <- expand.grid(
  species = sp_vec,
  sim = seq(1, 100, by = 1)
)


## import simulated pars
sim_par_list <- purrr::map2(
  sim_tbl$species, sim_tbl$sim, 
  function(x, y) {
    file_name <- paste(x, "_", y, "_pars.rds", sep = "")
    readRDS(here::here("data", "fits", "sim_fit", file_name)) %>% 
      mutate(species = x)
  }
)

sim_par_dat <- sim_par_list %>% 
  bind_rows() %>% 
  mutate(
    species = abbreviate(species, minlength = 3),
    term = fct_recode(
      as.factor(term), 
      "diel" = "day_nightNIGHT", "depth" = "scale_depth",
      "dist" = "scale_dist",
      "spring_int" = "season_fsp", 
      "summer_int" = "season_fsu", "fall_int" = "season_fwi", 
      "survey_design" = "survey_fipes", "sigma_epsilon" = "sigma_U", 
      "sigma_omega" = "sigma_Z"
    ),
    term = fct_relevel(
      term, "diel", "depth", "dist", "survey_design", "spring_int", "summer_int",
      "fall_int", "pink_cycle2", "sox_cycle2", "sox_cycle3", "sox_cycle4", 
      "phi", "range", "sigma_omega", "sigma_epsilon"
    )
  )


png(here::here("figs", "ms_figs_season_mvrw", "par_recovery_sim_box_mcmc.png"), 
    height = 8, width = 8, units = "in", res = 200)
ggplot() +
  geom_boxplot(data = sim_par_dat, 
               aes(x = species, y = estimate)) +
  geom_point(data = fit_pars, 
             aes(x = species, y = estimate),
             colour = "red") +
  facet_wrap(~ term, scales = "free_y") +
  labs(y = "Parameter Estimate", x =  "Species") +
  ggsidekick::theme_sleek()
dev.off()


## COMPARE INDICES -------------------------------------------------------------

# calculate sampling intensity in each survey-season combo
library(raster)

## create raster for each season's sampling grid
winter_grid <- index_grid_hss %>% 
  filter(year == "1998", season_f == "wi")  %>% 
  dplyr::select(X, Y) %>% 
  SpatialPoints(
    ., 
    proj4string = sp::CRS("+proj=utm +zone=9 +units=m")
  )
winter_raster <- rasterize(winter_grid, raster(extent(winter_grid), 
                                               res = c(5000, 5000)))

summer_grid <- index_grid_hss %>% 
  filter(year == "1998", season_f == "su")  %>% 
  dplyr::select(X, Y) %>% 
  SpatialPoints(
    ., 
    proj4string = sp::CRS("+proj=utm +zone=9 +units=m")
  )
summer_raster <- rasterize(summer_grid, raster(extent(summer_grid), 
                                               res = c(5000, 5000)))

# for each season-year combination identify proportion of cells sampled
# only need to do one species because set locations are identical
ys_key <- expand.grid(
  year = seq(min(all_fit_tbl$data[[1]]$year), max(all_fit_tbl$data[[1]]$year),
             by = 1),
  season_f = c("su", "wi")
) %>% 
  mutate(
    year_season_f = paste(year, season_f, sep = "_")
  )

ppn_coverage <- purrr::map(ys_key$year_season_f, function (x) {
  dd <- all_fit_tbl$data[[1]] %>% 
    mutate(
      year_season_f = paste(year, season_f, sep = "_")
    ) %>% 
    filter(year_season_f == x)
  raster_with_border <- if(grepl("su", x)) summer_raster else winter_raster
  if (nrow(dd) == 0) {
    raster_values <- 0
  } else {
    points <- dd %>% 
      dplyr::select(utm_x, utm_y)
    sp_points <- SpatialPointsDataFrame(
      points, proj4string = sp::CRS("+proj=utm +zone=9 +units=m"), dd
    )  
    raster_values <- extract(raster_with_border, sp_points)
  }
  length(na.omit(raster_values)) / ncell(raster_with_border)
}) %>% 
  unlist()

n_tows <- all_fit_tbl$data[[1]] %>%
  group_by(year, season_f) %>% 
  summarise(n_tows = length(unique(unique_event)))

ys_key2 <- ys_key %>% 
  mutate(
    ppn_coverage = ppn_coverage,
    year_f = as.factor(year)
  ) %>% 
  group_by(season_f) %>% 
  mutate(
    scale_coverage = ppn_coverage / max(ppn_coverage)
  ) %>% 
  ungroup() %>% 
  left_join(., n_tows, by = c("year", "season_f"))


# import saved indices from all_species_fit_season.R
true_index_list <- readRDS(
  here::here("data", "season_index_list_mvrfrw.rds")
)

true_ind_dat <- true_index_list %>%
  bind_rows() %>%
  mutate(
    log_lwr = log_est - (1.96 * se),
    log_upr = log_est + (1.96 * se),
    year_f = as.factor(year)
  )


sp_vec <- unique(all_fit_tbl$species)
sim_tbl <- expand.grid(
  species = sp_vec,
  sim = seq(1, 100, by = 1)
)


## import simulated pars
sim_index_list <- purrr::map2(
  sim_tbl$species, sim_tbl$sim, 
  function(x, y) {
    file_name2 <- paste(x, "_", y, "_index.rds", sep = "")
    readRDS(here::here("data", "fits", "sim_fit", file_name2)) %>% 
      mutate(species = x)
  }
)

sim_ind_dat <- sim_index_list %>%
  bind_rows() %>% 
  left_join(
    ., 
    true_ind_dat %>% 
      dplyr::select(species, year, year_f, season_f, true_log_est = log_est),
    by = c("species", "year", "season_f")) %>% 
  mutate(
    season = fct_recode(season_f, "summer" = "su", "fall" = "wi"),
    resid_est = true_log_est - log_est
    # TODO: CALC spatial coverage as number of tows
  ) %>% 
  left_join(
    ., 
    ys_key2 %>% dplyr::select(-year),
    by = c("season_f", "year_f")) 

n_iter <- length(unique(sim_ind_dat$iter)) #how many sims per species?


png(here::here("figs", "ms_figs_season_mvrw", "sim_index.png"), 
    height = 8, width = 8, units = "in", res = 200)
ggplot() +
  geom_boxplot(data = sim_ind_dat,
               aes(x = year_f, y = log_est, fill = scale_coverage)) +
  geom_point(data = true_ind_dat %>% filter(species %in% sp_vec),
             aes(x = year_f, y = log_est), colour = "red") +
  facet_grid(species~season, scales = "free_y") +
  ggsidekick::theme_sleek() +
  theme(legend.position = "top") +
  scale_x_discrete(breaks = seq(2000, 2020, by = 5)) +
  labs(y = "Log Estimated Abundance") +
  theme(axis.title.x = element_blank()) +
  scale_fill_gradient2(name = "Relative Spatial\nCoverage")
dev.off()


png(here::here("figs", "ms_figs_season_mvrw", "resid_index.png"), 
    height = 8, width = 8, units = "in", res = 200)
ggplot() +
  geom_boxplot(data = sim_ind_dat,
               aes(x = year_f, y = resid_est, fill = scale_coverage)) +
  geom_hline(yintercept = 0, lty = 2, colour = "red") +
  facet_grid(species~season, scales = "free_y") +
  ggsidekick::theme_sleek() +
  theme(legend.position = "top") +
  scale_x_discrete(breaks = seq(2000, 2020, by = 5)) +
  labs(y = "Index Residuals") +
  theme(axis.title.x = element_blank())  +
  scale_fill_gradient2(name = "Relative Spatial\nCoverage")
dev.off()


mae_dat <- sim_ind_dat %>% 
  #remove one iteration with error
  filter(!is.na(resid_est)) %>% 
  group_by(year_f, season, species, scale_coverage, n_tows) %>% 
  summarize(
    mae = sum(abs(resid_est) / n_iter)
  ) 
mae_fit <- lme4::lmer(log(mae) ~ scale_coverage + (1 | species), data = mae_dat)
mae_fit2 <- lme4::lmer(log(mae) ~ n_tows + (1 | species), data = mae_dat)


png(here::here("figs", "ms_figs_season_mvrw", "mae_coverage.png"), 
    height = 4, width = 6, units = "in", res = 200)
ggplot(mae_dat) +
  geom_point(aes(x = scale_coverage, y = mae, fill = season), shape = 21) +
  scale_fill_discrete(name = "Season") +
  facet_wrap(~species) +
  ggsidekick::theme_sleek() +
  labs(y = "Mean Absolute Error", x = "Relative Proportion of Grid Sampled")
dev.off()
  
