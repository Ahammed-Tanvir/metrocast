# =============================================================================
# Settings for the weekly MetroCast pipeline. Edit these once.
# Any of them can also be overridden on the command line, e.g. --team DMAPRIME --threads 6
# =============================================================================
CONFIG <- list(
  # hub repository clone (cloned automatically on the first --update)
  hub = "flu-metrocast",
  # folder for downloaded NSSP data, plots and diagnostics
  data = "data",
  # weekly-updated health-system files (South Carolina)
  prisma = "/Users/tanvirahammed/Library/CloudStorage/Box-Box/BoxPHI-PHMR Projects/Data/Prisma Health/Infectious Disease EHR/Weekly Data/Latest Weekly Data/Prisma_Health_Weekly_Influenza_State_dx_cond_lab_Incident.csv",
  musc = "/Users/tanvirahammed/Library/CloudStorage/Box-Box/BoxPHI-PHMR Projects/Data/MUSC/Infectious Disease EHR/Weekly Data/Latest Weekly Data/MUSC_Weekly_Influenza_State_dx_cond_lab_Incident.csv",
  # hub model id = team-model (letters, digits, _ and + only in each part)
  team = "DMAPRIME",
  model = "QR_E",
  # CPU threads for LightGBM and ranger
  threads = 4L
)
