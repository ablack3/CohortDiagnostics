# Copyright 2022 Observational Health Data Sciences and Informatics
#
# This file is part of CohortDiagnostics
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.


getInclusionStatisticsFromFiles <- function(cohortIds = NULL,
                                            folder,
                                            cohortInclusionFile = file.path(
                                              folder,
                                              "cohortInclusion.csv"
                                            ),
                                            cohortInclusionResultFile = file.path(
                                              folder,
                                              "cohortIncResult.csv"
                                            ),
                                            cohortInclusionStatsFile = file.path(
                                              folder,
                                              "cohortIncStats.csv"
                                            ),
                                            cohortSummaryStatsFile = file.path(
                                              folder,
                                              "cohortSummaryStats.csv"
                                            ),
                                            simplify = TRUE) {
  start <- Sys.time()

  if (!file.exists(cohortInclusionFile)) {
    return(NULL)
  }

  fetchStats <- function(file) {
    ParallelLogger::logDebug("- Fetching data from ", file)
    stats <- readr::read_csv(file,
      col_types = readr::cols(),
      guess_max = min(1e7)
    )
    if (!is.null(cohortIds)) {
      stats <- stats %>%
        dplyr::filter(.data$cohortDefinitionId %in% cohortIds)
    }
    return(stats)
  }

  inclusion <- fetchStats(cohortInclusionFile)
  if ("description" %in% names(inclusion)) {
    inclusion$description <- as.character(inclusion$description)
    inclusion$description[is.na(inclusion$description)] <- ""
  } else {
    inclusion$description <- ""
  }

  summaryStats <- fetchStats(cohortSummaryStatsFile)
  inclusionStats <- fetchStats(cohortInclusionStatsFile)
  inclusionResults <- fetchStats(cohortInclusionResultFile)
  result <- dplyr::tibble()
  for (cohortId in unique(inclusion$cohortDefinitionId)) {
    cohortResult <-
      processInclusionStats(
        inclusion = filter(inclusion, .data$cohortDefinitionId == cohortId),
        inclusionResults = filter(inclusionResults, .data$cohortDefinitionId == cohortId),
        inclusionStats = filter(inclusionStats, .data$cohortDefinitionId == cohortId),
        summaryStats = filter(summaryStats, .data$cohortDefinitionId == cohortId),
        simplify = simplify
      )
    if (!is.null(cohortResult)) {
      cohortResult$cohortDefinitionId <- cohortId
      result <- dplyr::bind_rows(result, cohortResult)
    }
  }
  delta <- Sys.time() - start
  writeLines(paste(
    "Fetching inclusion statistics took",
    signif(delta, 3),
    attr(delta, "units")
  ))
  if (nrow(result) > 0) {
    return(result)
  } else {
    return(NULL)
  }
}

processInclusionStats <- function(inclusion,
                                  inclusionResults,
                                  simplify,
                                  inclusionStats,
                                  summaryStats) {
  if (simplify) {
    if (nrow(inclusion) == 0 || nrow(inclusionStats) == 0) {
      return(NULL)
    }

    result <- inclusion %>%
      dplyr::select(.data$ruleSequence, .data$name) %>%
      dplyr::distinct() %>%
      dplyr::inner_join(
        inclusionStats %>%
          dplyr::filter(.data$modeId == 0) %>%
          dplyr::select(
            .data$ruleSequence,
            .data$personCount,
            .data$gainCount,
            .data$personTotal
          ),
        by = "ruleSequence"
      ) %>%
      dplyr::mutate(remain = 0)

    inclusionResults <- inclusionResults %>%
      dplyr::filter(.data$modeId == 0)
    mask <- 0
    for (ruleId in 0:(nrow(result) - 1)) {
      mask <- bitwOr(mask, 2^ruleId)
      idx <-
        bitwAnd(inclusionResults$inclusionRuleMask, mask) == mask
      result$remain[result$ruleSequence == ruleId] <-
        sum(inclusionResults$personCount[idx])
    }
    colnames(result) <- c(
      "ruleSequenceId",
      "ruleName",
      "meetSubjects",
      "gainSubjects",
      "totalSubjects",
      "remainSubjects"
    )
  } else {
    if (nrow(inclusion) == 0) {
      return(list())
    }
    result <- list(
      inclusion = inclusion,
      inclusionResults = inclusionResults,
      inclusionStats = inclusionStats,
      summaryStats = summaryStats
    )
  }
  return(result)
}

getInclusionStats <- function(connection,
                              exportFolder,
                              databaseId,
                              cohortDefinitionSet,
                              cohortDatabaseSchema,
                              cohortTableNames,
                              incremental,
                              instantiatedCohorts,
                              minCellCount,
                              recordKeepingFile) {
  ParallelLogger::logInfo("Fetching inclusion statistics from files")
  subset <- subsetToRequiredCohorts(
    cohorts = cohortDefinitionSet %>%
      dplyr::filter(.data$cohortId %in% instantiatedCohorts),
    task = "runInclusionStatistics",
    incremental = incremental,
    recordKeepingFile = recordKeepingFile
  )

  if (incremental &&
    (length(instantiatedCohorts) - nrow(subset)) > 0) {
    ParallelLogger::logInfo(sprintf(
      "Skipping %s cohorts in incremental mode.",
      length(instantiatedCohorts) - nrow(subset)
    ))
  }
  if (nrow(subset) > 0) {
    ParallelLogger::logInfo("Exporting inclusion rules with CohortGenerator")
    CohortGenerator::insertInclusionRuleNames(
      connection = connection,
      cohortDefinitionSet = subset,
      cohortDatabaseSchema = cohortDatabaseSchema,
      cohortInclusionTable = cohortTableNames$cohortInclusionTable
    )
    # This part will change in future version, with a patch to CohortGenerator that
    # supports the usage of exporting tables without writing to disk
    inclusionStatisticsFolder <- tempfile("CdCohortStatisticsFolder")
    on.exit(unlink(inclusionStatisticsFolder), add = TRUE)
    CohortGenerator::exportCohortStatsTables(
      connection = connection,
      cohortDatabaseSchema = cohortDatabaseSchema,
      cohortTableNames = cohortTableNames,
      cohortStatisticsFolder = inclusionStatisticsFolder,
      incremental = FALSE
    ) # Note use of FALSE to always genrate stats here
    stats <-
      getInclusionStatisticsFromFiles(
        cohortIds = subset$cohortId,
        folder = inclusionStatisticsFolder,
        simplify = TRUE
      )

    if (!is.null(stats)) {
      if ("cohortDefinitionId" %in% (colnames(stats))) {
        stats <- stats %>%
          dplyr::rename(cohortId = .data$cohortDefinitionId)
      }

      stats <- makeDataExportable(
        x = stats,
        tableName = "inclusion_rule_stats",
        databaseId = databaseId,
        minCellCount = minCellCount
      )

      writeToCsv(
        data = stats,
        fileName = file.path(exportFolder, "inclusion_rule_stats.csv"),
        incremental = incremental,
        cohortId = subset$cohortId
      )

      recordTasksDone(
        cohortId = subset$cohortId,
        task = "runInclusionStatistics",
        checksum = subset$checksum,
        recordKeepingFile = recordKeepingFile,
        incremental = incremental
      )
    }
  }
}