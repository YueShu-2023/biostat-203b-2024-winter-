library(shiny)
library(ggplot2)
library(DBI)
library(bigrquery)

mimic_icu_cohort <- readRDS("mimic_icu_cohort.rds")

ui <- navbarPage(
  "",
  tabPanel(
    "Paitients Characteristics",
    selectInput("characteristic", "Variable of interest",
      choices = c(
        "First care unit" = "first_careunit",
        "Last care unit" = "last_careunit",
        "Gender" = "gender",
        "Age intime" = "age_intime",
        "Admission Type" = "admission_type",
        "Admission Location" = "admission_location",
        "Discharge Location" = "discharge_location",
        "Insurance" = "insurance",
        "Language" = "language",
        "Marital status" = "marital_status",
        "Race" = "race",
        "Lab Events",
        "Vitals",
        "Hospital Expire" = "hospital_expire_flag"
      )
    ),
    checkboxInput("outliers", "Remove Outliers in IQR method for
                         measurements?", value = FALSE),
    plotOutput("plot1")
  ),
  tabPanel(
    "Paient's ADT and ICU stay Information",
    tags$div(
      style = "color: gray; margin-bottom: 10px;",
      "Please select a patient ID"
    ),
    selectInput("patient", "Patient ID",
      choices = c(
        10000032, 10000980,
        10001217, 10001725, 10001884
      )
    ),
    plotOutput("plot2")
  )
)


server <- function(input, output) {
  satoken <- "biostat-203b-2024-winter-313290ce47a6.json"
  bq_auth(path = satoken)

  con_bq <- dbConnect(
    bigrquery::bigquery(),
    project = "biostat-203b-2024-winter",
    dataset = "mimic4_v2_2",
    billing = "biostat-203b-2024-winter"
  )

  output$plot1 <- renderPlot({
    if (input$characteristic == "Lab Events") {
      selected_columns <- c(
        "Creatinine", "Potassium", "Sodium",
        "Chloride", "Bicarbonate", "Hematocrit",
        "White Blood Cells", "Glucose"
      )

      if (input$outliers) {
        data <- mimic_icu_cohort[selected_columns] %>%
          gather(key = "Lab_Event", value = "Value") %>%
          filter(!is.na(Value)) %>%
          filter(Value >=
            quantile(Value, 0.25, na.rm = TRUE) - 1.5 * IQR(Value) &
            Value <= quantile(Value, 0.75, na.rm = TRUE) + 1.5 * IQR(Value))
      } else {
        data <- mimic_icu_cohort[selected_columns] %>%
          gather(key = "Lab_Event", value = "Value")
      }

      ggplot(data, aes(x = Value, y = Lab_Event)) +
        geom_boxplot() +
        labs(x = "value", y = "variable") +
        theme_minimal()
    } else if (input$characteristic == "Vitals") {
      selected_columns <- c(
        "Heart Rate", "Respiratory Rate","Non Invasive Blood Pressure systolic",
        "Non Invasive Blood Pressure diastolic", "Temperature Fahrenheit"
      )

      if (input$outliers) {
        data <- mimic_icu_cohort[selected_columns] %>%
          gather(key = "Vitals", value = "Value") %>%
          filter(!is.na(Value)) %>%
          filter(Value >= quantile(Value, 0.25, na.rm = TRUE) 
                 - 1.5 * IQR(Value) & 
                   Value <=quantile(Value, 0.75,na.rm = TRUE) 
                 + 1.5 * IQR(Value))
      } else {
        data <- mimic_icu_cohort[selected_columns] %>%
          gather(key = "Vitals", value = "Value")
      }

      ggplot(data, aes(x = Value, y = Vitals)) +
        geom_boxplot() +
        labs(x = "value", y = "variable") +
        theme_minimal()
    } else {
      characteristic_data <- table(mimic_icu_cohort[[input$characteristic]])
      par(mar = c(5, 30, 4, 2) + 0.1)
      barplot(characteristic_data,
        horiz = TRUE,
        main = "Patient count by stay or patient variable group",
        ylab = input$characteristic,
        xlab = "Count",
        las = 2
      )
    }
  })

  output$plot2 <- renderPlot({
    id <- as.numeric(input$patient)

    transfers <- tbl(con_bq, "transfers") |>
      filter(subject_id == id) |>
      mutate(intime = as.POSIXct(intime), outtime = as.POSIXct(outtime)) |>
      filter(eventtype != "discharge") |>
      collect()

    patients <- tbl(con_bq, "patients") |>
      filter(subject_id == id) |>
      collect()

    admissions <- tbl(con_bq, "admissions") |>
      filter(subject_id == id) |>
      mutate(
        admittime = as.POSIXct(admittime),
        dischtime = as.POSIXct(dischtime)
      ) |>
      collect()

    labevents <- tbl(con_bq, "labevents") |>
      filter(subject_id == id) |>
      mutate(charttime = as.POSIXct(charttime)) |>
      collect()

    procedures_icd <- tbl(con_bq, "procedures_icd") %>%
      filter(subject_id == id) %>%
      mutate(chartdate = as.POSIXct(chartdate)) %>%
      left_join(
        tbl(con_bq, "d_icd_procedures", show_col_types = FALSE) |>
          select(icd_code, long_title),
        by = "icd_code"
      ) |>
      collect()

    diagnoses_icd <- tbl(con_bq, "diagnoses_icd") %>%
      left_join(
        tbl(con_bq, "d_icd_diagnoses", show_col_types = FALSE) |>
          select(icd_code, long_title),
        by = "icd_code"
      ) |>
      filter(subject_id == id) |>
      collect()

    top_diagnoses <- diagnoses_icd |>
      arrange(seq_num) |>
      distinct(long_title, .keep_all = TRUE) |>
      slice_head(n = 3) |>
      pull(long_title) |>
      paste(collapse = "\n")

    patient_title <- paste("Patient ", id,
      ", ", dplyr::pull(patients, gender),
      ", ", dplyr::pull(patients, anchor_age),
      " years old, ",
      tolower(dplyr::pull(admissions, race)),
      sep = ""
    )

    is_ICU_CCU <- str_detect(transfers$careunit, "ICU|CCU")

    ggplot() +
      geom_segment(data = transfers |> collect(), aes(
        x = intime, xend = outtime,
        y = "ADT", yend = "ADT",
        color = careunit,
        linewidth = is_ICU_CCU
      )) +
      geom_point(data = procedures_icd |> collect(), 
                 aes(x = chartdate,y = "Procedure", shape = long_title)) +
      geom_point(
        data = labevents |> collect(), aes(x = charttime, y = "Lab"),
        shape = 3
      ) +
      theme_bw(base_size = 7) +
      theme(legend.position = "bottom", legend.box = "vertical") +
      scale_y_discrete(limits = c("Procedure", "Lab", "ADT")) +
      labs(
        title = patient_title, subtitle = top_diagnoses,
        x = "Calendar", y = "Event Type", color = "Care Unit",
        shape = "Procedure"
      ) +
      guides(linewidth = FALSE) +
      scale_x_datetime(date_labels = "%b %d") +
      geom_point(
        data = procedures_icd |> collect(),
        aes(x = chartdate, y = "Procedure", shape = long_title)
      ) +
      scale_shape_manual(values = c(1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12))
  })
}

# Run the application
shinyApp(ui = ui, server = server)
