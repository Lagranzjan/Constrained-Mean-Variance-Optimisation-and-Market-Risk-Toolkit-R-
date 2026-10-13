# =============================================================================
#  OPTYMALNY PORTFEL MARKOWITZA
#  Wybierasz spółki – skrypt dobiera proporcje i rysuje wszystkie wykresy.
# =============================================================================
#  Co robi skrypt:
#   1. pobiera notowania (Yahoo Finance / własny plik CSV / dane demo),
#   2. liczy oczekiwane zwroty i macierz kowariancji
#      (opcjonalnie z kurczeniem Ledoit-Wolfa – stabilniejsze wagi),
#   3. wyznacza portfel o maksymalnym wskaźniku Sharpe'a, portfel o minimalnej
#      wariancji oraz całą granicę efektywną – z ograniczeniami na wagi
#      (domyślnie: bez krótkiej sprzedaży, maks. 40% w jednej spółce),
#   4. (opcjonalnie) sprawdza strategię w backteście out-of-sample,
#   5. (opcjonalnie) moduł RYZYKA dla wybranego portfela, na danych dziennych:
#        - VaR i Expected Shortfall: historyczny, normalny, Cornish-Fisher, EWMA,
#        - backtest VaR: test Kupca (POF), test Christoffersena (niezależność
#          wyjątków), strefy Bazylei (traffic light),
#        - stress testy: scenariusze historyczne (2008, COVID, 2022, IV kw. 2018)
#          i hipotetyczne (szok rynkowy, szok jednej spółki, korelacje -> 1),
#   6. zapisuje wykresy (PNG) i tabele (CSV) do folderu `output/`.
#
#  Uruchomienie:
#     Rscript markowitz_portfolio.R
#     Rscript markowitz_portfolio.R DATA_SOURCE=demo
#     Rscript markowitz_portfolio.R TICKERS=KO,PEP,MCD,NVDA MAX_WEIGHT=0.5
#  W RStudio: otwórz plik i kliknij „Source" (wykresy pojawią się w panelu Plots).
#  Wymagany R >= 4.1.
# =============================================================================


# ----------------------------- 1. USTAWIENIA ---------------------------------
# >>> Tu wybierasz spółki i parametry. Wszystko inne możesz zostawić. <<<

TICKERS <- c("ORCL", "JPM", "MELI", "FIS", "NFLX")
#   Symbole jak na Yahoo Finance. Spółki z GPW mają końcówkę .WA,
#   np. "PKO.WA", "PKN.WA", "PZU.WA", "CDR.WA" (sprawdź symbol na finance.yahoo.com).
#   Min. 2 spółki; kolorowo rozróżnianych jest do 8 (więcej działa, ale wykresy
#   zbiorcze zgrupują spółki od 8. w górę w pozycję „Inne").

DATA_SOURCE <- "yahoo"   # "yahoo" = pobranie z internetu | "csv" = własny plik | "demo" = dane SYMULOWANE
CSV_PATH    <- "prices.csv"   # tylko dla "csv": 1. kolumna = Date (RRRR-MM-DD), dalej po 1 kolumnie cen na spółkę

START_DATE  <- as.character(Sys.Date() - round(365.25 * 12))   # domyślnie 12 lat wstecz
END_DATE    <- as.character(Sys.Date())
FREQUENCY   <- "monthly" # częstotliwość zwrotów: "daily" | "weekly" | "monthly"

RISK_FREE_RATE <- 0.04   # roczna stopa wolna od ryzyka (wpisz aktualną, w walucie spółek!)

MIN_WEIGHT  <- 0.00      # minimalna waga spółki (0 = brak krótkiej sprzedaży; ujemna = dozwolony short)
MAX_WEIGHT  <- 0.40      # maksymalna waga jednej spółki (1 = bez limitu)

COV_METHOD  <- "shrinkage"   # "shrinkage" (Ledoit-Wolf, zalecane) | "sample" (zwykła kowariancja)
EXPECTED_RETURNS <- NULL     # NULL = średnia historyczna; albo własne roczne zwroty,
                             # np. c(AAPL = 0.12, MSFT = 0.10, ...) – nazwy = TICKERS

N_FRONTIER  <- 100       # liczba punktów granicy efektywnej
N_RANDOM    <- 4000      # liczba losowych portfeli na tle granicy (tylko wykres)

RUN_BACKTEST     <- TRUE # test na danych „z przyszłości" (rolling window)
LOOKBACK_YEARS   <- 5    # ile lat historii widzi optymalizator przy każdej decyzji
REBALANCE_MONTHS <- 12   # co ile miesięcy portfel jest przeliczany
TRANSACTION_COST <- 0.001 # koszt transakcji jako ułamek obrotu (0.001 = 10 pb)

# --- Moduł ryzyka (VaR / ES / backtest VaR / stress testy) ---
RUN_RISK        <- TRUE
RISK_PORTFOLIO  <- "Max Sharpe"  # którego portfela dotyczy: "Max Sharpe" | "Min wariancja" | "Równe wagi"
RISK_START_DATE <- "2007-01-01"  # początek historii DZIENNEJ dla ryzyka (żeby objąć kryzys 2008;
                                 # wspólna próba i tak zaczyna się od debiutu najmłodszej spółki)
VAR_LEVELS      <- c(0.95, 0.99) # poziomy ufności (musi zawierać 0.99 – na nim opiera się test Bazylei)
VAR_WINDOW      <- 500           # długość okna estymacji w rolling backteście VaR (sesje; 500 ~ 2 lata)
EWMA_LAMBDA     <- 0.94          # współczynnik zapominania RiskMetrics dla zmienności EWMA
STRESS_MARKET_SHOCK <- -0.20     # hipotetyczny szok rynkowy (przenoszony na spółki przez ich beta)
STRESS_NAME_SHOCK   <- -0.40     # hipotetyczny spadek największej pozycji portfela
STRESS_VOL_MULT     <- 1.5       # mnożnik zmienności w stresowym VaR (korelacje = 1)

OUTPUT_DIR  <- "output"
SEED        <- 7     # ziarno losowania (dane demo + losowe portfele na wykresie)

# (opcjonalne) nadpisanie ustawień z linii poleceń: NAZWA=wartość, listy po przecinku
for (arg in commandArgs(trailingOnly = TRUE)) {
  kv <- strsplit(arg, "=", fixed = TRUE)[[1]]
  if (length(kv) == 2 && exists(kv[1], inherits = FALSE)) {
    val <- if (grepl(",", kv[2], fixed = TRUE)) strsplit(kv[2], ",", fixed = TRUE)[[1]]
           else utils::type.convert(kv[2], as.is = TRUE)
    assign(kv[1], val)
  }
}
VAR_LEVELS <- as.numeric(VAR_LEVELS)   # z linii poleceń listy przychodzą jako tekst


# ------------------------- 2. PAKIETY I WALIDACJA ----------------------------
stopifnot(
  DATA_SOURCE %in% c("yahoo", "csv", "demo"),
  FREQUENCY   %in% c("daily", "weekly", "monthly"),
  COV_METHOD  %in% c("shrinkage", "sample")
)
if (length(TICKERS) < 2)    stop("Wybierz co najmniej 2 spółki w TICKERS.")
if (anyDuplicated(TICKERS)) stop("TICKERS zawiera duplikaty.")
if (RUN_RISK) {
  if (!RISK_PORTFOLIO %in% c("Max Sharpe", "Min wariancja", "Równe wagi"))
    stop("RISK_PORTFOLIO musi być jednym z: \"Max Sharpe\", \"Min wariancja\", \"Równe wagi\".")
  if (!any(abs(VAR_LEVELS - 0.99) < 1e-9)) stop("VAR_LEVELS musi zawierać 0.99.")
  if (any(VAR_LEVELS <= 0.5 | VAR_LEVELS >= 1)) stop("VAR_LEVELS: poziomy ufności muszą być w przedziale (0,5; 1).")
}

pkgs <- c("quadprog", "ggplot2", "dplyr", "tidyr", "scales", "ggrepel")   # ggrepel: czytelne etykiety (opcjonalny)
if (DATA_SOURCE == "yahoo") pkgs <- c(pkgs, "quantmod")
missing_pkgs <- pkgs[!vapply(pkgs, requireNamespace, logical(1), quietly = TRUE)]
if (length(missing_pkgs)) {
  message("Instaluję brakujące pakiety: ", paste(missing_pkgs, collapse = ", "))
  install.packages(missing_pkgs, repos = "https://cloud.r-project.org")
}
suppressPackageStartupMessages({
  library(ggplot2)
  library(dplyr)
  library(tidyr)
})

PPY     <- c(daily = 252, weekly = 52, monthly = 12)[[FREQUENCY]]   # okresów w roku
IS_DEMO <- DATA_SOURCE == "demo"
dir.create(OUTPUT_DIR, showWarnings = FALSE, recursive = TRUE)


# --------------------------- 3. FORMATOWANIE I KOLORY ------------------------
pct <- function(x, digits = 1) scales::percent(x, accuracy = 10^(-digits), decimal.mark = ",", big.mark = " ")
num <- function(x, digits = 2) formatC(x, format = "f", digits = digits, decimal.mark = ",", big.mark = " ")

# Paleta: 8 kolorów kategorii w stałej kolejności (zwalidowana pod kątem
# daltonizmu), neutralne kolory tekstu/siatki, powierzchnia wykresu.
COL <- list(surface = "#fcfcfb", ink = "#0b0b0b", secondary = "#52514e",
            muted = "#898781", grid = "#e1e0d9", axis = "#c3c2b7", neutral = "#f0efec")
SLOTS <- c("#2a78d6", "#eb6834", "#1baf7a", "#eda100", "#e87ba4", "#008300", "#6250d6", "#e34948")

# Portfele mają stałe kolory na wszystkich wykresach; benchmark = szary.
PORT_COL <- c("Max Sharpe" = SLOTS[1], "Min wariancja" = SLOTS[2], "Równe wagi" = COL$muted)

# Kolor podąża za spółką (kolejność z TICKERS), nie za jej wagą.
# Przy > 8 spółkach pozycje od 8. w górę trafiają do szarej grupy „Inne".
asset_levels <- function(tickers) if (length(tickers) <= 8) tickers else c(tickers[1:7], "Inne")
asset_fill_values <- function(tickers) {
  lv <- asset_levels(tickers)
  cols <- SLOTS[seq_along(lv)]
  if (length(tickers) > 8) cols[8] <- COL$muted
  setNames(cols, lv)
}
asset_palette <- function(tickers) {
  n <- length(tickers)
  setNames(ifelse(n <= 8 | seq_len(n) <= 7, SLOTS[pmin(seq_len(n), 8)], COL$muted), tickers)
}
fold_assets <- function(df, tickers, by) {   # df: kolumny `by`, asset, weight
  if (length(tickers) <= 8) return(df)
  df$asset <- ifelse(df$asset %in% tickers[1:7], as.character(df$asset), "Inne")
  df |>
    group_by(across(all_of(c(by, "asset")))) |>
    summarise(weight = sum(weight), .groups = "drop")
}

theme_viz <- function(base_size = 11) {
  theme_minimal(base_size = base_size) +
    theme(
      plot.background   = element_rect(fill = COL$surface, color = NA),
      panel.background  = element_rect(fill = COL$surface, color = NA),
      panel.grid.major  = element_line(color = COL$grid, linewidth = 0.3),
      panel.grid.minor  = element_blank(),
      axis.line.x       = element_line(color = COL$axis, linewidth = 0.4),
      axis.ticks        = element_blank(),
      axis.text         = element_text(color = COL$muted),
      axis.title        = element_text(color = COL$secondary),
      plot.title        = element_text(face = "bold", color = COL$ink, size = base_size + 4,
                                       hjust = 0, margin = margin(b = 4)),
      plot.subtitle     = element_text(color = COL$secondary, hjust = 0, margin = margin(b = 10)),
      plot.caption      = element_text(color = COL$muted, hjust = 0, size = base_size - 2,
                                       margin = margin(t = 10)),
      plot.title.position   = "plot",
      plot.caption.position = "plot",
      legend.position   = "bottom",
      legend.title      = element_text(color = COL$secondary),
      legend.text       = element_text(color = COL$secondary),
      strip.text        = element_text(color = COL$ink, face = "bold", hjust = 0),
      plot.margin       = margin(14, 16, 12, 14)
    )
}

DATA_NOTE <- if (IS_DEMO) {
  "DANE SYMULOWANE (tryb demo) – wyniki nie opisują prawdziwych spółek"
} else {
  sprintf("Źródło: %s | okres: %s – %s | zwroty: %s | stopa wolna od ryzyka: %s",
          DATA_SOURCE, START_DATE, END_DATE,
          c(daily = "dzienne", weekly = "tygodniowe", monthly = "miesięczne")[[FREQUENCY]],
          pct(RISK_FREE_RATE, 1))
}

save_plot <- function(p, file, width = 10, height = 6.2) {
  ggsave(file.path(OUTPUT_DIR, file), p, width = width, height = height, dpi = 150, bg = COL$surface)
  if (interactive()) print(p)
  invisible(file)
}

write_csv_pl <- function(df, file) {   # średnik + przecinek dziesiętny + BOM: otwiera się poprawnie w polskim Excelu
  con <- file(file.path(OUTPUT_DIR, file), open = "wb")
  on.exit(close(con))
  writeBin(as.raw(c(0xEF, 0xBB, 0xBF)), con)
  utils::write.table(df, con, sep = ";", dec = ",", row.names = FALSE, quote = TRUE)
}


# ------------------------------ 4. DANE --------------------------------------
load_yahoo <- function(tickers, from, to) {
  errs <- character(0)
  px <- lapply(tickers, function(tk) {
    x <- tryCatch(
      suppressWarnings(quantmod::getSymbols(tk, src = "yahoo", from = from, to = to,
                                            auto.assign = FALSE, warnings = FALSE)),
      error = function(e) { errs[tk] <<- conditionMessage(e); NULL })
    Sys.sleep(0.3)
    if (is.null(x)) NULL else quantmod::Ad(x)
  })
  bad <- vapply(px, is.null, logical(1))
  if (any(bad)) {
    stop("Nie udało się pobrać: ", paste(tickers[bad], collapse = ", "),
         ".\nSprawdź symbole (GPW: końcówka .WA) i połączenie z internetem albo użyj ",
         "DATA_SOURCE = \"csv\" (własny plik) / \"demo\" (dane symulowane).",
         if (length(errs)) paste0("\nSzczegóły (pierwszy błąd): ", substr(errs[[1]], 1, 300)),
         call. = FALSE)
  }
  px <- do.call(merge, unname(px))
  data.frame(Date = zoo::index(px), setNames(as.data.frame(zoo::coredata(px)), tickers),
             check.names = FALSE)
}

load_csv <- function(path, tickers, from, to) {
  if (!file.exists(path)) stop("Nie znaleziono pliku CSV: ", path, call. = FALSE)
  d <- utils::read.csv(path, check.names = FALSE, stringsAsFactors = FALSE)
  names(d)[1] <- "Date"
  d$Date <- as.Date(d$Date)
  miss <- setdiff(tickers, names(d))
  if (length(miss)) stop("W pliku CSV brakuje kolumn: ", paste(miss, collapse = ", "), call. = FALSE)
  d <- d[d$Date >= as.Date(from) & d$Date <= as.Date(to), c("Date", tickers)]
  d
}

simulate_prices <- function(tickers, from, to, seed) {   # symulacja z jednoczynnikowym modelem korelacji
  set.seed(seed)
  n <- length(tickers)
  dates <- seq(as.Date(from), as.Date(to), by = "day")
  dates <- dates[!format(dates, "%u") %in% c("6", "7")]
  mu_a  <- runif(n, 0.05, 0.18)
  sig_a <- runif(n, 0.15, 0.38)
  b     <- runif(n, 0.35, 0.75)
  C <- outer(b, b); diag(C) <- 1
  S <- C * outer(sig_a, sig_a) / 252
  Z <- matrix(rnorm(length(dates) * n), ncol = n) %*% chol(S)
  drift <- mu_a / 252 - 0.5 * diag(S)
  P <- 100 * exp(apply(sweep(Z, 2, drift, "+"), 2, cumsum))
  data.frame(Date = dates, setNames(as.data.frame(P), tickers), check.names = FALSE)
}

prepare_returns <- function(price_df, frequency) {
  dates <- as.Date(price_df$Date)
  P <- as.matrix(price_df[, -1, drop = FALSE])
  o <- order(dates); P <- P[o, , drop = FALSE]; dates <- dates[o]
  ok <- stats::complete.cases(P); P <- P[ok, , drop = FALSE]; dates <- dates[ok]
  key <- switch(frequency,
                daily   = format(dates),
                weekly  = format(dates, "%G-%V"),
                monthly = format(dates, "%Y-%m"))
  last <- !duplicated(key, fromLast = TRUE)          # ostatnia sesja każdego okresu
  P <- P[last, , drop = FALSE]; dates <- dates[last]
  rownames(P) <- as.character(dates)
  R <- P[-1, , drop = FALSE] / P[-nrow(P), , drop = FALSE] - 1
  list(prices = P, returns = R)
}


# ------------------------ 5. ESTYMACJA PARAMETRÓW ----------------------------
# Kurczenie Ledoit-Wolfa do skalowanej macierzy jednostkowej (Ledoit & Wolf, 2004).
ledoit_wolf <- function(R) {
  X <- scale(R, center = TRUE, scale = FALSE)
  n <- nrow(X); p <- ncol(X)
  S <- crossprod(X) / n
  m <- sum(diag(S)) / p
  d2 <- sum((S - m * diag(p))^2) / p
  b2 <- (sum(rowSums(X^2)^2) - n * sum(S^2)) / (n^2 * p)
  shrink <- min(b2, d2) / d2
  list(cov = shrink * m * diag(p) + (1 - shrink) * S, shrinkage = shrink)
}

estimate_inputs <- function(R, ppy, cov_method, mu_override = NULL) {
  mu <- colMeans(R) * ppy
  if (cov_method == "shrinkage") {
    lw <- ledoit_wolf(R); S <- lw$cov; shrink <- lw$shrinkage
  } else {
    S <- stats::cov(R); shrink <- 0
  }
  Sigma <- S * ppy
  dimnames(Sigma) <- list(colnames(R), colnames(R))
  if (!is.null(mu_override)) {
    if (is.null(names(mu_override)) || !all(colnames(R) %in% names(mu_override))) {
      stop("EXPECTED_RETURNS musi być nazwanym wektorem ze wszystkimi spółkami, ",
           "np. c(AAPL = 0.12, MSFT = 0.10, ...).", call. = FALSE)
    }
    mu <- setNames(as.numeric(mu_override[colnames(R)]), colnames(R))
  }
  list(mu = mu, Sigma = Sigma, shrinkage = shrink)
}


# ------------------------ 6. OPTYMALIZACJA (QP) ------------------------------
# min  w' Σ w   przy:  suma wag = 1,  [zwrot = cel],  lo <= w <= hi
solve_portfolio_qp <- function(Sigma, lo, hi, mu = NULL, target = NULL) {
  n <- ncol(Sigma)
  Sigma <- (Sigma + t(Sigma)) / 2
  A <- matrix(1, n, 1); b <- 1
  if (!is.null(target)) { A <- cbind(A, mu); b <- c(b, target) }
  meq <- ncol(A)
  A <- cbind(A, diag(n), -diag(n)); b <- c(b, lo, -hi)
  res <- NULL
  for (rg in c(1e-8, 1e-6, 1e-4)) {   # minimalna regularyzacja, gdyby Σ była osobliwa
    res <- tryCatch(quadprog::solve.QP(Sigma + diag(rg * mean(diag(Sigma)), n), rep(0, n), A, b, meq = meq),
                    error = function(e) e)
    if (!inherits(res, "error")) break
  }
  if (inherits(res, "error")) stop(res)
  w <- res$solution
  w[abs(w) < 1e-8] <- 0
  setNames(w, colnames(Sigma))
}

# Maksymalny/minimalny osiągalny zwrot przy ograniczeniach (dokładne rozwiązanie zachłanne).
extreme_return_weights <- function(mu, lo, hi, maximize = TRUE) {
  w <- lo; rest <- 1 - sum(lo)
  for (i in order(mu, decreasing = maximize)) {
    add <- min(hi[i] - lo[i], rest)
    w[i] <- w[i] + add; rest <- rest - add
    if (rest <= 1e-12) break
  }
  setNames(w, names(mu))
}

port_stats <- function(w, mu, Sigma, rf) {
  ret <- sum(w * mu); vol <- sqrt(drop(t(w) %*% Sigma %*% w))
  c(ret = ret, vol = vol, sharpe = (ret - rf) / vol)
}

efficient_frontier <- function(mu, Sigma, lo, hi, n_points = 100) {
  w_min <- solve_portfolio_qp(Sigma, lo, hi)
  w_max <- extreme_return_weights(mu, lo, hi, TRUE)
  r_min <- sum(w_min * mu); r_max <- sum(w_max * mu)
  if (r_max - r_min < 1e-10) {
    W <- rbind(w_min)
  } else {
    targets <- seq(r_min, r_max, length.out = n_points)
    mid <- lapply(targets[-c(1, n_points)], function(tr)
      tryCatch(solve_portfolio_qp(Sigma, lo, hi, mu, tr), error = function(e) NULL))
    W <- do.call(rbind, c(list(w_min), Filter(Negate(is.null), mid), list(w_max)))
  }
  colnames(W) <- colnames(Sigma)
  list(W = W, ret = drop(W %*% mu), vol = sqrt(rowSums((W %*% Sigma) * W)))
}

# Portfel stycznej: maksimum Sharpe'a na granicy efektywnej (siatka + dokładne dopracowanie).
max_sharpe_weights <- function(mu, Sigma, rf, lo, hi, n_grid = 300) {
  w_min <- solve_portfolio_qp(Sigma, lo, hi)
  w_max <- extreme_return_weights(mu, lo, hi, TRUE)
  r_min <- sum(w_min * mu); r_max <- sum(w_max * mu)
  if (r_max - r_min < 1e-10) return(w_min)
  sharpe_w <- function(w) (sum(w * mu) - rf) / sqrt(drop(t(w) %*% Sigma %*% w))
  qp_at <- function(tr) tryCatch(solve_portfolio_qp(Sigma, lo, hi, mu, tr), error = function(e) NULL)
  grid <- seq(r_min, r_max, length.out = n_grid)
  s <- rep(-Inf, n_grid)
  s[1] <- sharpe_w(w_min); s[n_grid] <- sharpe_w(w_max)
  for (k in 2:(n_grid - 1)) { w <- qp_at(grid[k]); if (!is.null(w)) s[k] <- sharpe_w(w) }
  i <- which.max(s)
  if (i == 1) return(w_min)
  if (i == n_grid) return(w_max)
  opt <- stats::optimize(function(tr) { w <- qp_at(tr); if (is.null(w)) -Inf else sharpe_w(w) },
                         c(grid[i - 1], grid[i + 1]), maximum = TRUE)
  w_best <- qp_at(opt$maximum)
  if (!is.null(w_best) && sharpe_w(w_best) >= s[i]) w_best else qp_at(grid[i])
}

risk_contributions <- function(w, Sigma) { m <- drop(Sigma %*% w); w * m / drop(w %*% m) }

random_portfolios <- function(n_target, lo, hi, mu, Sigma, rf, max_batches = 40) {
  n <- length(lo); room <- 1 - sum(lo)
  out <- matrix(numeric(0), 0, n)
  for (b in seq_len(max_batches)) {
    G <- matrix(stats::rgamma(20000 * n, shape = 1), ncol = n)
    W <- sweep((G / rowSums(G)) * room, 2, lo, "+")
    ok <- rowSums(sweep(W, 2, hi, ">")) == 0
    out <- rbind(out, W[ok, , drop = FALSE])
    if (nrow(out) >= n_target) break
  }
  if (nrow(out) == 0) return(NULL)
  out <- out[seq_len(min(n_target, nrow(out))), , drop = FALSE]
  ret <- drop(out %*% mu); vol <- sqrt(rowSums((out %*% Sigma) * out))
  data.frame(ret = ret, vol = vol, sharpe = (ret - rf) / vol)
}


# ------------------------------ 7. BACKTEST ----------------------------------
run_backtest <- function(R, ppy, lookback, rebalance_every, rf, lo, hi, cov_method, cost) {
  Tn <- nrow(R); n <- ncol(R)
  if (Tn < lookback + rebalance_every) {
    stop("Za mało danych na backtest: potrzeba min. ", lookback + rebalance_every,
         " okresów, jest ", Tn, ". Skróć LOOKBACK_YEARS lub wydłuż okres danych.", call. = FALSE)
  }
  strategies <- names(PORT_COL)
  starts <- seq(lookback + 1, Tn, by = rebalance_every)
  port_ret <- matrix(NA_real_, Tn, 3, dimnames = list(rownames(R), strategies))
  w_cur <- vector("list", 3); hist <- list()
  for (s in starts) {
    e <- min(s + rebalance_every - 1, Tn)
    est <- estimate_inputs(R[(s - lookback):(s - 1), , drop = FALSE], ppy, cov_method)
    targets <- list(
      max_sharpe_weights(est$mu, est$Sigma, rf, lo, hi),
      solve_portfolio_qp(est$Sigma, lo, hi),
      setNames(rep(1 / n, n), colnames(R))
    )
    for (j in 1:3) {
      w <- targets[[j]]
      turnover <- if (is.null(w_cur[[j]])) 0 else sum(abs(w - w_cur[[j]]))
      for (t in s:e) {
        rp <- sum(w * R[t, ])
        port_ret[t, j] <- rp - if (t == s) cost * turnover else 0
        w <- w * (1 + R[t, ]) / (1 + rp)          # dryf wag między przeliczeniami
      }
      w_cur[[j]] <- w
      hist[[length(hist) + 1]] <- data.frame(date = rownames(R)[s], strategy = strategies[j],
                                             asset = colnames(R), weight = as.numeric(targets[[j]]))
    }
  }
  list(returns = port_ret[starts[1]:Tn, , drop = FALSE],
       start_date = as.Date(rownames(R)[starts[1] - 1]),
       weights = bind_rows(hist))
}

backtest_stats <- function(ret_mat, ppy, rf) {
  do.call(rbind, lapply(colnames(ret_mat), function(nm) {
    r <- ret_mat[, nm]; wealth <- cumprod(1 + r); years <- length(r) / ppy
    data.frame(Strategia = nm,
               `Zwrot roczny (CAGR)` = wealth[length(wealth)]^(1 / years) - 1,
               `Ryzyko roczne` = stats::sd(r) * sqrt(ppy),
               `Sharpe` = (mean(r) * ppy - rf) / (stats::sd(r) * sqrt(ppy)),
               `Maks. obsunięcie` = min(wealth / cummax(wealth) - 1),
               `Wartość końcowa (start = 100)` = 100 * wealth[length(wealth)],
               check.names = FALSE)
  }))
}


# ------------------------------ 7b. MODUŁ RYZYKA -----------------------------
# VaR i ES liczone są na DZIENNYCH zwrotach portfela o stałych wagach (codzienne
# przeliczanie), niezależnie od FREQUENCY – backtest VaR potrzebuje długiej próby.
# VaR i ES to dodatnie straty, jako ułamek wartości portfela (0,02 = strata 2%).
RISK_METHODS <- c("Historyczna", "Normalna", "Cornish-Fisher", "EWMA")
METHOD_COL   <- setNames(SLOTS[1:4], RISK_METHODS)

# Okna scenariuszy historycznych (wg szczytów i dołków S&P 500). Strata liczona od
# zamknięcia sesji poprzedzającej `from` do zamknięcia sesji `to`.
HIST_SCENARIOS <- data.frame(
  name = c("Kryzys finansowy 2008 (upadek Lehman -> dołek)", "Krach COVID-19 (luty-marzec 2020)",
           "Bessa 2022 (podwyżki stóp)", "Wyprzedaż IV kwartału 2018"),
  from = as.Date(c("2008-09-15", "2020-02-20", "2022-01-03", "2018-09-21")),
  to   = as.Date(c("2009-03-09", "2020-03-23", "2022-10-12", "2018-12-24")),
  stringsAsFactors = FALSE)

xlogy <- function(x, y) ifelse(x == 0, 0, x * log(y))   # konwencja 0 * log(0) = 0

# Momenty rozkładu: średnia, odchylenie, skośność, kurtoza nadwyżkowa.
moments_of <- function(x) {
  m <- mean(x); s <- stats::sd(x); z <- (x - m) / s
  list(m = m, s = s, sk = mean(z^3), ku = mean(z^4) - 3)
}

# Kwantyl Cornish-Fishera: normalny kwantyl poprawiony o skośność i kurtozę.
# Uwaga: dla bardzo dużej skośności/kurtozy rozwinięcie przestaje być monotoniczne.
cf_quantile <- function(zq, sk, ku) {
  zq + (zq^2 - 1) * sk / 6 + (zq^3 - 3 * zq) * ku / 24 - (2 * zq^3 - 5 * zq) * sk^2 / 36
}

# Wariancja EWMA (RiskMetrics): s2[t] = prognoza na dzień t, używa danych do t-1.
ewma_sigma2 <- function(r, lambda, init) {
  s2 <- numeric(length(r)); s2[1] <- init
  for (t in 2:length(r)) s2[t] <- lambda * s2[t - 1] + (1 - lambda) * r[t - 1]^2
  s2
}

# VaR i ES na pełnej próbie (jedna liczba na metodę i poziom) – "stan na dziś".
static_risk <- function(rp, levels, lambda, window) {
  mo <- moments_of(rp); zq <- stats::qnorm(1 - levels)
  q  <- stats::quantile(rp, 1 - levels, type = 7, names = FALSE)
  s2 <- ewma_sigma2(rp, lambda, stats::var(rp[seq_len(min(window, length(rp)))]))
  sg <- sqrt(lambda * s2[length(rp)] + (1 - lambda) * rp[length(rp)]^2)   # prognoza na następną sesję
  rbind(
    data.frame(Metoda = "Historyczna", Poziom = levels, VaR = -q,
               ES = -vapply(q, function(qq) mean(rp[rp <= qq]), numeric(1))),
    data.frame(Metoda = "Normalna", Poziom = levels, VaR = -(mo$m + zq * mo$s),
               ES = -mo$m + mo$s * stats::dnorm(zq) / (1 - levels)),
    data.frame(Metoda = "Cornish-Fisher", Poziom = levels,
               VaR = -(mo$m + cf_quantile(zq, mo$sk, mo$ku) * mo$s), ES = NA_real_),
    data.frame(Metoda = "EWMA", Poziom = levels, VaR = -zq * sg, ES = sg * stats::dnorm(zq) / (1 - levels))
  )
}

# Stresowy VaR: zmienność spółek razy `mult`, korelacje = 1 dla wszystkich par
# (najgorszy przypadek: wszystkie pozycje tracą jednocześnie, więc liczą się |wagi|).
stressed_var <- function(w, Rd, levels, mult) {
  s_p <- mult * sum(abs(w) * apply(Rd, 2, stats::sd)); zq <- stats::qnorm(1 - levels)
  data.frame(Metoda = sprintf("Stres (zmienność x%s, korelacje = 1)", num(mult, 1)), Poziom = levels,
             VaR = -zq * s_p, ES = s_p * stats::dnorm(zq) / (1 - levels))
}

# Rolling prognozy VaR/ES: na dzień t tylko dane z okna [t-window, t-1].
var_forecasts <- function(r, window, levels, lambda) {
  Tn <- length(r); idx <- (window + 1):Tn; nl <- length(levels)
  zq <- stats::qnorm(1 - levels); k_es <- stats::dnorm(zq) / (1 - levels)
  mk <- function() lapply(setNames(RISK_METHODS, RISK_METHODS), function(m)
    matrix(NA_real_, length(idx), nl, dimnames = list(NULL, as.character(levels))))
  V <- mk(); E <- mk()
  s2 <- ewma_sigma2(r, lambda, stats::var(r[1:window]))
  for (k in seq_along(idx)) {
    t <- idx[k]; x <- r[(t - window):(t - 1)]
    mo <- moments_of(x)
    q <- stats::quantile(x, 1 - levels, type = 7, names = FALSE)
    V[["Historyczna"]][k, ]     <- -q
    E[["Historyczna"]][k, ]     <- -vapply(q, function(qq) mean(x[x <= qq]), numeric(1))
    V[["Normalna"]][k, ]        <- -(mo$m + zq * mo$s)
    E[["Normalna"]][k, ]        <- -mo$m + mo$s * k_es
    V[["Cornish-Fisher"]][k, ]  <- -(mo$m + cf_quantile(zq, mo$sk, mo$ku) * mo$s)
    sg <- sqrt(s2[t])
    V[["EWMA"]][k, ] <- -zq * sg
    E[["EWMA"]][k, ] <- sg * k_es
  }
  list(idx = idx, VaR = V, ES = E)
}

# Test Kupca (POF): czy częstość wyjątków x/N zgadza się z oczekiwaną p = 1 - poziom.
kupiec_pof <- function(x, N, p) {
  ph <- x / N
  ll0 <- (N - x) * log(1 - p) + x * log(p)
  ll1 <- xlogy(N - x, 1 - ph) + xlogy(x, ph)
  lr <- max(0, -2 * (ll0 - ll1))
  c(lr = lr, p = stats::pchisq(lr, 1, lower.tail = FALSE))
}

# Test Christoffersena: czy wyjątki są niezależne w czasie (czy nie grupują się w klastry).
christoffersen_ind <- function(e) {
  e <- as.integer(e); a <- e[-length(e)]; b <- e[-1]
  n00 <- sum(a == 0 & b == 0); n01 <- sum(a == 0 & b == 1)
  n10 <- sum(a == 1 & b == 0); n11 <- sum(a == 1 & b == 1)
  p01 <- if (n00 + n01 > 0) n01 / (n00 + n01) else 0
  p11 <- if (n10 + n11 > 0) n11 / (n10 + n11) else 0
  p1  <- (n01 + n11) / (n00 + n01 + n10 + n11)
  ll0 <- xlogy(n00 + n10, 1 - p1) + xlogy(n01 + n11, p1)
  ll1 <- xlogy(n00, 1 - p01) + xlogy(n01, p01) + xlogy(n10, 1 - p11) + xlogy(n11, p11)
  lr <- max(0, -2 * (ll0 - ll1))
  c(lr = lr, p = stats::pchisq(lr, 1, lower.tail = FALSE))
}

# Strefy Bazylei (traffic light) dla VaR 99% na ostatnich 250 sesjach.
basel_zone <- function(x) {
  plus <- c(0, 0, 0, 0, 0, 0.40, 0.50, 0.65, 0.75, 0.85, 1.00)[min(x, 10) + 1]
  list(zone = if (x <= 4) "zielona" else if (x <= 9) "żółta" else "czerwona", plus = plus)
}

# Backtest: wyjątki, testy Kupca/Christoffersena, jakość ES i strefy Bazylei.
evaluate_var <- function(r, fc, levels) {
  loss <- -r[fc$idx]; rows <- list(); exc <- list(); zones <- list()
  for (m in names(fc$VaR)) for (j in seq_along(levels)) {
    e <- loss > fc$VaR[[m]][, j]; N <- length(e); x <- sum(e); p <- 1 - levels[j]
    ku <- kupiec_pof(x, N, p); ch <- christoffersen_ind(e)
    es <- fc$ES[[m]][, j]
    es_ratio <- if (x > 0 && !anyNA(es)) mean(loss[e]) / mean(es[e]) else NA_real_   # ~1 = ES dobrze skalibrowany
    rows[[length(rows) + 1]] <- data.frame(
      Metoda = m, Poziom = levels[j], N = N, `Oczekiwane wyjątki` = N * p, `Wyjątki` = x, `Odsetek wyjątków` = x / N,
      `Kupiec LR` = ku[["lr"]], `Kupiec p` = ku[["p"]], `Christoffersen LR` = ch[["lr"]], `Christoffersen p` = ch[["p"]],
      `Łączny LR (CC)` = ku[["lr"]] + ch[["lr"]], `Łączny p (CC)` = stats::pchisq(ku[["lr"]] + ch[["lr"]], 2, lower.tail = FALSE),
      `ES: strata realna / prognoza` = es_ratio, check.names = FALSE)
    exc[[paste(m, levels[j])]] <- e
    if (abs(levels[j] - 0.99) < 1e-9) {
      x250 <- sum(utils::tail(e, 250)); bz <- basel_zone(x250)
      zones[[length(zones) + 1]] <- data.frame(Metoda = m, `Wyjątki (ost. 250 sesji)` = x250, Strefa = bz$zone,
                                               `Dodatek do mnożnika` = bz$plus, check.names = FALSE)
    }
  }
  list(table = do.call(rbind, rows), exc = exc, zones = do.call(rbind, zones))
}

# Wiersz tabeli stress testów: zwroty portfeli (kolumny W) i spółek przy danym scenariuszu.
stress_row <- function(typ, name, period, ra, W) {
  v <- c(setNames(drop(crossprod(W, ra)), colnames(W)), ra)
  cbind(data.frame(Typ = typ, Scenariusz = name, Okres = period, stringsAsFactors = FALSE),
        as.data.frame(as.list(v), check.names = FALSE))
}

# Scenariusze historyczne: stałe wagi z początku okna przyłożone do realnych zwrotów spółek.
# Scenariusz jest pomijany, jeśli dane nie obejmują całego okna.
historical_stress <- function(Pd, sc, W) {
  dates <- as.Date(rownames(Pd)); out <- list(); skipped <- character(0)
  for (i in seq_len(nrow(sc))) {
    b <- which(dates < sc$from[i]); e <- which(dates <= sc$to[i])
    ok <- length(b) > 0 && length(e) > 0 && max(e) > max(b) &&
      as.numeric(sc$from[i] - dates[max(b)]) <= 7 && as.numeric(sc$to[i] - dates[max(e)]) <= 7
    if (!ok) { skipped <- c(skipped, sc$name[i]); next }
    ra <- Pd[max(e), ] / Pd[max(b), ] - 1
    out[[length(out) + 1]] <- stress_row("Historyczny", sc$name[i],
                                         sprintf("%s – %s", format(sc$from[i]), format(sc$to[i])), ra, W)
  }
  list(rows = if (length(out)) do.call(rbind, out) else NULL, skipped = skipped)
}

# Scenariusze hipotetyczne: szok rynkowy (przez beta względem portfela równych wag)
# i spadek pojedynczej, największej pozycji wybranego portfela (pierwsza kolumna W).
hypothetical_stress <- function(Rd, W, market_shock, name_shock) {
  r_eq <- rowMeans(Rd)
  beta <- apply(Rd, 2, function(x) stats::cov(x, r_eq) / stats::var(r_eq))
  k <- which.max(abs(W[, 1]))
  ra_name <- setNames(rep(0, ncol(Rd)), colnames(Rd)); ra_name[k] <- name_shock
  rbind(
    stress_row("Hipotetyczny", sprintf("Szok rynkowy %s (przez beta względem portfela równych wag)", pct(market_shock, 0)),
               "–", beta * market_shock, W),
    stress_row("Hipotetyczny", sprintf("%s: %s (ryzyko jednej spółki)", colnames(Rd)[k], pct(name_shock, 0)),
               "–", ra_name, W))
}


# ------------------------------ 8. WYKRESY -----------------------------------
have_repel <- requireNamespace("ggrepel", quietly = TRUE)

plot_prices <- function(prices, tickers) {
  P100 <- sweep(prices, 2, prices[1, ], "/") * 100
  df <- data.frame(date = as.Date(rownames(P100)), P100, check.names = FALSE) |>
    pivot_longer(-date, names_to = "asset", values_to = "value")
  df$asset <- factor(df$asset, levels = tickers)
  ggplot(df, aes(date, value, color = asset)) +
    geom_hline(yintercept = 100, color = COL$axis, linewidth = 0.4) +
    geom_line(linewidth = 0.8, lineend = "round", linejoin = "round") +
    facet_wrap(~asset, ncol = min(4, length(tickers))) +
    scale_color_manual(values = asset_palette(tickers), guide = "none") +
    scale_y_log10(labels = function(x) format(x, big.mark = " ", scientific = FALSE, trim = TRUE)) +
    scale_x_date(date_labels = "%Y", breaks = scales::breaks_pretty(n = 4)) +
    labs(title = "Notowania spółek (start = 100)",
         subtitle = "Skala logarytmiczna – ten sam odstęp pionowy oznacza tę samą zmianę procentową",
         x = NULL, y = NULL, caption = DATA_NOTE) +
    theme_viz()
}

plot_corr <- function(R, tickers) {
  df <- as.data.frame(as.table(stats::cor(R)), stringsAsFactors = FALSE)
  names(df) <- c("x", "y", "r")
  df$x <- factor(df$x, levels = tickers); df$y <- factor(df$y, levels = rev(tickers))
  p <- ggplot(df, aes(x, y, fill = r)) +
    geom_tile(color = COL$surface, linewidth = 1) +
    scale_fill_gradient2(low = SLOTS[8], mid = COL$neutral, high = SLOTS[1], midpoint = 0,
                         limits = c(-1, 1), name = "Korelacja zwrotów",
                         labels = function(x) num(x, 1)) +
    coord_fixed() +
    labs(title = "Korelacje między spółkami",
         subtitle = "Im niższa korelacja, tym większa korzyść z dywersyfikacji",
         x = NULL, y = NULL, caption = DATA_NOTE) +
    theme_viz() +
    theme(panel.grid.major = element_blank(), axis.line.x = element_blank(),
          legend.title = element_text(color = COL$secondary, margin = margin(r = 16)),
          legend.key.width = grid::unit(2.4, "cm"), legend.key.height = grid::unit(0.35, "cm"))
  if (length(tickers) <= 10) p <- p + geom_text(aes(label = num(r, 2)), color = COL$ink, size = 3.4)
  p
}

plot_frontier <- function(ef, cloud, assets, special, rf) {
  special$portfolio <- factor(special$portfolio, levels = names(PORT_COL))
  ms <- special[special$portfolio == "Max Sharpe", ]
  sh <- (ms$ret - rf) / ms$vol
  xmax <- max(c(ef$vol, assets$vol, cloud$vol)) * 1.06
  yr <- range(c(ef$ret, assets$ret, cloud$ret, rf)); pad <- 0.06 * diff(yr)
  ylim <- c(yr[1] - pad, yr[2] + pad)
  ef_df <- data.frame(vol = ef$vol, ret = ef$ret)

  p <- ggplot()
  if (!is.null(cloud)) {
    p <- p + geom_point(data = cloud, aes(vol, ret, color = sharpe), size = 0.9, alpha = 0.55) +
      scale_color_gradient(low = "#86b6ef", high = "#0d366b", name = "Sharpe portfeli losowych",
                           labels = function(x) num(x, 1))
  }
  if (sh > 0) {
    p <- p + geom_segment(aes(x = 0, y = rf, xend = xmax, yend = rf + sh * xmax),
                          color = COL$muted, linewidth = 0.5)
    x_lab <- 0.12 * xmax   # etykieta CML blisko osi Y, z dala od spółek
    p <- p + annotate("text", x = x_lab, y = rf + sh * x_lab, label = "CML", color = COL$secondary,
                      size = 3.3, hjust = 0, vjust = -0.8)
  }
  k <- max(1, round(0.3 * nrow(ef_df)))
  ef_lab <- data.frame(vol = ef_df$vol[k], ret = ef_df$ret[k], label = "Granica efektywna")
  p <- p +
    geom_line(data = ef_df, aes(vol, ret), color = COL$ink, linewidth = 0.9, lineend = "round") +
    geom_point(data = assets, aes(vol, ret), shape = 21, size = 3.2, fill = COL$secondary,
               color = COL$surface, stroke = 0.9) +
    geom_point(data = special, aes(vol, ret, fill = portfolio, shape = portfolio), size = 4.6,
               color = COL$surface, stroke = 1) +
    scale_fill_manual(values = PORT_COL, name = "Portfel") +
    scale_shape_manual(values = c("Max Sharpe" = 23, "Min wariancja" = 22, "Równe wagi" = 24),
                       name = "Portfel")
  lab_special <- transform(special, label = as.character(portfolio))
  lab_assets  <- transform(assets, label = asset)
  if (have_repel) {   # etykiety z obwódką w kolorze tła – czytelne także na tle chmury punktów
    p <- p +
      ggrepel::geom_text_repel(data = lab_assets, aes(vol, ret, label = label), color = COL$secondary,
                               size = 3.2, seed = 1, box.padding = 0.35, min.segment.length = 0.3,
                               segment.color = COL$axis, bg.color = COL$surface, bg.r = 0.15,
                               max.overlaps = Inf) +
      ggrepel::geom_text_repel(data = rbind(lab_special[, c("vol", "ret", "label")], ef_lab),
                               aes(vol, ret, label = label), color = COL$ink, fontface = "bold",
                               size = 3.4, seed = 2, box.padding = 0.9, point.padding = 0.5,
                               min.segment.length = 0, segment.color = COL$muted,
                               bg.color = COL$surface, bg.r = 0.15, max.overlaps = Inf)
  } else {
    p <- p +
      geom_text(data = lab_assets, aes(vol, ret, label = label), color = COL$secondary, size = 3.2, vjust = -1.1) +
      geom_text(data = lab_special, aes(vol, ret, label = label), color = COL$ink, fontface = "bold",
                size = 3.4, vjust = 2.1) +
      annotate("text", x = ef_lab$vol, y = ef_lab$ret, label = ef_lab$label, color = COL$ink,
               fontface = "bold", size = 3.4, hjust = 1.08)
  }
  p +
    scale_x_continuous(labels = function(x) pct(x, 0)) +
    scale_y_continuous(labels = function(x) pct(x, 0)) +
    coord_cartesian(xlim = c(0, xmax), ylim = ylim, expand = FALSE) +
    labs(title = "Granica efektywna Markowitza",
         subtitle = sprintf("Szare punkty – pojedyncze spółki · niebieskie punkty – losowe portfele (ciemniejszy = wyższy Sharpe)\nSzara linia – CML: prosta od stopy wolnej od ryzyka (%s) do portfela Max Sharpe", pct(rf, 1)),
         x = "Ryzyko (roczne odchylenie standardowe)", y = "Oczekiwany zwrot roczny",
         caption = DATA_NOTE) +
    theme_viz()
}

plot_transition <- function(ef, tickers, vol_ms, vol_mv, shorts) {
  Wdf <- as.data.frame(ef$W, check.names = FALSE); Wdf$vol <- ef$vol
  long <- pivot_longer(Wdf, -vol, names_to = "asset", values_to = "weight")
  long <- fold_assets(long, tickers, by = "vol")
  long$asset <- factor(long$asset, levels = asset_levels(tickers))
  p <- ggplot(long, aes(vol, weight))
  p <- if (!shorts) {
    p + geom_area(aes(fill = asset), color = COL$surface, linewidth = 0.25)
  } else {
    p + geom_hline(yintercept = 0, color = COL$axis, linewidth = 0.4) +
      geom_line(aes(color = asset), linewidth = 0.9, lineend = "round") +
      scale_color_manual(values = asset_fill_values(tickers), name = NULL)
  }
  # Etykiety pionowych linii: po stronie, gdzie jest miejsce (nie wychodzą poza panel);
  # gdy linie są blisko siebie i po tej samej stronie – jedna etykieta wyżej.
  xr <- range(ef$vol)
  hj <- function(v) if (v > mean(xr)) 1.08 else -0.08
  stagger <- (vol_mv > mean(xr)) == (vol_ms > mean(xr)) && abs(vol_ms - vol_mv) < 0.3 * diff(xr)
  y_mv <- 1.03; y_ms <- if (stagger) 1.10 else 1.03
  p <- p +
    geom_vline(xintercept = vol_mv, color = COL$ink, linewidth = 0.4) +
    geom_vline(xintercept = vol_ms, color = COL$ink, linewidth = 0.4) +
    annotate("text", x = vol_mv, y = if (shorts) Inf else y_mv, label = "Min wariancja", hjust = hj(vol_mv),
             vjust = if (shorts) -0.4 else 0, color = COL$secondary, size = 3.4) +
    annotate("text", x = vol_ms, y = if (shorts) Inf else y_ms, label = "Max Sharpe", hjust = hj(vol_ms),
             vjust = if (shorts) (if (stagger) -1.9 else -0.4) else 0, color = COL$secondary, size = 3.4) +
    scale_fill_manual(values = asset_fill_values(tickers), name = NULL) +
    scale_x_continuous(labels = function(x) pct(x, if (diff(xr) < 0.08) 1 else 0), expand = c(0, 0)) +
    scale_y_continuous(labels = function(x) pct(x, 0), expand = if (shorts) expansion(mult = 0.05) else c(0, 0))
  p <- if (shorts) p + coord_cartesian(clip = "off") else p + coord_cartesian(ylim = c(0, 1), expand = FALSE, clip = "off")
  p +
    labs(title = "Jak zmieniają się wagi wzdłuż granicy efektywnej",
         subtitle = "Od lewej: najmniejsze ryzyko → ... → największy zwrot (i ryzyko)",
         x = "Ryzyko portfela (roczne odch. standardowe)", y = "Waga w portfelu", caption = DATA_NOTE) +
    theme_viz() +
    theme(plot.subtitle = element_text(margin = margin(b = if (stagger) 46 else 30)))
}

plot_weights <- function(portfolios, stats, tickers) {
  strip <- setNames(sprintf("%s\nzwrot %s · ryzyko %s · Sharpe %s", rownames(stats),
                            pct(stats[, "ret"], 1), pct(stats[, "vol"], 1), num(stats[, "sharpe"], 2)),
                    rownames(stats))
  ord <- order(-portfolios[["Max Sharpe"]], seq_along(tickers))
  df <- do.call(rbind, lapply(names(portfolios), function(nm)
    data.frame(portfolio = nm, asset = tickers, weight = as.numeric(portfolios[[nm]]))))
  df$asset <- factor(df$asset, levels = rev(tickers[ord]))
  df$strip <- factor(strip[df$portfolio], levels = strip[names(PORT_COL)])
  df$lab   <- ifelse(abs(df$weight) < 0.0005, "", pct(df$weight, 1))
  ggplot(df, aes(weight, asset, fill = portfolio)) +
    geom_vline(xintercept = 0, color = COL$axis, linewidth = 0.4) +
    geom_col(width = 0.5) +
    geom_text(aes(label = lab, hjust = ifelse(weight >= 0, -0.15, 1.15)), color = COL$secondary, size = 3.2) +
    facet_wrap(~strip, nrow = 1) +
    scale_fill_manual(values = PORT_COL, guide = "none") +
    scale_x_continuous(labels = function(x) pct(x, 0), breaks = scales::breaks_pretty(n = 4),
                       expand = expansion(mult = c(if (any(df$weight < 0)) 0.28 else 0.05, 0.28))) +   # miejsce na etykiety ujemnych wag
    labs(title = "Skład portfeli", subtitle = "Spółki posortowane według wagi w portfelu Max Sharpe",
         x = "Waga", y = NULL, caption = DATA_NOTE) +
    theme_viz() +
    theme(strip.text = element_text(color = COL$ink, face = "plain", hjust = 0, lineheight = 1.2),
          panel.grid.major.y = element_blank(), panel.spacing.x = grid::unit(1.6, "lines"))
}

plot_risk_share <- function(w, Sigma, tickers) {
  rc <- risk_contributions(w, Sigma)
  df <- rbind(data.frame(asset = tickers, share = as.numeric(w),  type = "Udział w kapitale"),
              data.frame(asset = tickers, share = as.numeric(rc), type = "Udział w ryzyku"))
  df$asset <- factor(df$asset, levels = rev(tickers[order(-rc, seq_along(tickers))]))
  df$type  <- factor(df$type, levels = c("Udział w kapitale", "Udział w ryzyku"))
  df$lab   <- ifelse(abs(df$share) < 0.0005, "", pct(df$share, 1))
  dodge <- position_dodge(width = 0.7)
  ggplot(df, aes(share, asset, fill = type)) +
    geom_vline(xintercept = 0, color = COL$axis, linewidth = 0.4) +
    geom_col(position = dodge, width = 0.6) +
    geom_text(aes(label = lab, hjust = ifelse(share >= 0, -0.15, 1.15)), position = dodge,
              color = COL$secondary, size = 3.2) +
    scale_fill_manual(values = c("Udział w kapitale" = COL$muted, "Udział w ryzyku" = PORT_COL[["Max Sharpe"]]),
                      name = NULL) +
    scale_x_continuous(labels = function(x) pct(x, 0),
                       expand = expansion(mult = c(if (any(df$share < 0)) 0.15 else 0.05, 0.15))) +
    guides(fill = guide_legend(reverse = TRUE)) +
    labs(title = "Portfel Max Sharpe: kapitał kontra ryzyko",
         subtitle = "Spółka, której udział w ryzyku przewyższa udział w kapitale, „napędza” zmienność portfela",
         x = NULL, y = NULL, caption = DATA_NOTE) +
    theme_viz() +
    theme(panel.grid.major.y = element_blank())
}

bt_long <- function(ret_mat, start_date, dates, what = c("wealth", "drawdown")) {
  what <- match.arg(what)
  wealth <- rbind(100, apply(1 + ret_mat, 2, cumprod) * 100)
  colnames(wealth) <- colnames(ret_mat)
  val <- if (what == "wealth") wealth else apply(wealth, 2, function(x) x / cummax(x) - 1)
  data.frame(date = c(start_date, dates), val, check.names = FALSE) |>
    pivot_longer(-date, names_to = "strategy", values_to = "value") |>
    mutate(strategy = factor(strategy, levels = names(PORT_COL)))
}

plot_bt_wealth <- function(bt, ppy) {
  dates <- as.Date(rownames(bt$returns))
  df <- bt_long(bt$returns, bt$start_date, dates, "wealth")
  end <- df |> group_by(strategy) |> slice_tail(n = 1) |> ungroup() |>
    mutate(label = sprintf("%s: %s", strategy, num(value, 0)))
  span <- as.numeric(diff(range(df$date)))
  br <- scales::breaks_pretty(n = 6)(range(df$date)); br <- br[br <= max(df$date)]   # bez „przyszłych” lat na osi
  p <- ggplot(df, aes(date, value, color = strategy)) +
    geom_hline(yintercept = 100, color = COL$axis, linewidth = 0.4) +
    geom_line(linewidth = 0.9, lineend = "round", linejoin = "round") +
    geom_point(data = end, aes(date, value, fill = strategy), inherit.aes = FALSE, shape = 21,
               size = 3.4, color = COL$surface, stroke = 1)
  p <- if (have_repel) {
    p + ggrepel::geom_text_repel(data = end, aes(date, value, label = label), inherit.aes = FALSE,
                                 hjust = 0, direction = "y", nudge_x = span * 0.02, seed = 3,
                                 color = COL$secondary, size = 3.4, segment.color = COL$axis,
                                 min.segment.length = 0.3, box.padding = 0.3)
  } else {
    p + geom_text(data = end, aes(date, value, label = label), inherit.aes = FALSE, hjust = 0,
                  nudge_x = span * 0.02, color = COL$secondary, size = 3.4)
  }
  p +
    scale_color_manual(values = PORT_COL, name = NULL) +
    scale_fill_manual(values = PORT_COL, guide = "none") +
    scale_x_date(breaks = br, date_labels = "%Y", expand = expansion(mult = c(0.01, 0.28))) +
    scale_y_continuous(labels = function(x) num(x, 0)) +
    labs(title = "Backtest out-of-sample: wartość portfela",
         subtitle = sprintf("Wagi liczone tylko z danych sprzed decyzji (okno %d lat, przeliczanie co %d mies., koszt %s obrotu)",
                            LOOKBACK_YEARS, REBALANCE_MONTHS, pct(TRANSACTION_COST, 1)),
         x = NULL, y = "Wartość (start = 100)", caption = DATA_NOTE) +
    theme_viz()
}

plot_bt_drawdown <- function(bt) {
  dates <- as.Date(rownames(bt$returns))
  df <- bt_long(bt$returns, bt$start_date, dates, "drawdown")
  ggplot(df, aes(date, value, color = strategy)) +
    geom_hline(yintercept = 0, color = COL$axis, linewidth = 0.4) +
    geom_line(linewidth = 0.9, lineend = "round", linejoin = "round") +
    scale_color_manual(values = PORT_COL, name = NULL) +
    scale_x_date(date_labels = "%Y") +
    scale_y_continuous(labels = function(x) pct(x, 0)) +
    labs(title = "Backtest: obsunięcie kapitału od szczytu",
         subtitle = "Im głębiej linia schodzi poniżej zera, tym większa chwilowa strata względem rekordu",
         x = NULL, y = "Obsunięcie", caption = DATA_NOTE) +
    theme_viz()
}

plot_bt_weights <- function(bt, tickers) {
  w <- bt$weights |> filter(strategy %in% c("Max Sharpe", "Min wariancja"))
  w <- fold_assets(w, tickers, by = c("date", "strategy"))
  w$asset <- factor(w$asset, levels = asset_levels(tickers))
  w$strategy <- factor(w$strategy, levels = c("Max Sharpe", "Min wariancja"))
  ggplot(w, aes(date, weight, fill = asset)) +
    geom_col(width = 0.7, color = COL$surface, linewidth = 0.3) +
    facet_wrap(~strategy, ncol = 1) +
    scale_fill_manual(values = asset_fill_values(tickers), name = NULL) +
    scale_x_discrete(guide = guide_axis(check.overlap = TRUE)) +
    scale_y_continuous(labels = function(x) pct(x, 0)) +
    labs(title = "Backtest: skład portfeli w kolejnych przeliczeniach",
         subtitle = "Wagi docelowe ustalane na początku każdego okresu inwestycji",
         x = "Data przeliczenia", y = "Waga", caption = DATA_NOTE) +
    theme_viz()
}


# --- Wykresy modułu ryzyka ---
pct_na <- function(x, digits = 2) ifelse(is.na(x), "–", pct(x, digits))
risk_pick <- function(sr, m, col, lev = 0.99) sr[[col]][sr$Metoda == m & abs(sr$Poziom - lev) < 1e-9]

plot_ret_dist <- function(rp, sr, pname, note) {
  ln <- data.frame(label = c("VaR 99% (historyczny)", "ES 99% (historyczny)", "VaR 99% (normalny)"),
                   x = -c(risk_pick(sr, "Historyczna", "VaR"), risk_pick(sr, "Historyczna", "ES"),
                          risk_pick(sr, "Normalna", "VaR")))
  ln$label <- factor(ln$label, levels = ln$label)
  xr <- max(abs(stats::quantile(rp, c(0.002, 0.998)))) * 1.15
  cols <- setNames(c(SLOTS[2], SLOTS[8], SLOTS[1]), levels(ln$label))
  lts  <- setNames(c("solid", "solid", "dashed"), levels(ln$label))
  ggplot(data.frame(r = rp), aes(r)) +
    geom_histogram(aes(y = after_stat(density)), binwidth = 2 * xr / 80, boundary = 0,
                   fill = SLOTS[1], alpha = 0.35, color = NA) +
    stat_function(fun = stats::dnorm, args = list(mean = mean(rp), sd = stats::sd(rp)),
                  color = COL$ink, linewidth = 0.7, n = 400) +
    geom_vline(data = ln, aes(xintercept = x, color = label, linetype = label), linewidth = 0.8) +
    scale_color_manual(values = cols, name = NULL) +
    scale_linetype_manual(values = lts, name = NULL) +
    scale_x_continuous(labels = function(x) pct(x, 1)) +
    scale_y_continuous(labels = function(x) num(x, 0)) +
    coord_cartesian(xlim = c(-xr, xr)) +
    labs(title = sprintf("Rozkład dziennych zwrotów portfela %s i miary ryzyka", pname),
         subtitle = "Słupki – rzeczywiste zwroty dzienne · czarna linia – rozkład normalny o tej samej średniej i zmienności",
         x = "Dzienny zwrot portfela", y = "Gęstość", caption = note) +
    theme_viz()
}

plot_qq <- function(rp, pname, note) {
  mo <- moments_of(rp)
  ggplot(data.frame(z = (rp - mo$m) / mo$s), aes(sample = z)) +
    stat_qq(color = SLOTS[1], size = 0.9, alpha = 0.6) +
    stat_qq_line(color = COL$ink, linewidth = 0.6) +
    labs(title = sprintf("Wykres kwantyl-kwantyl: czy zwroty portfela %s są normalne?", pname),
         subtitle = sprintf("Punkty poniżej linii w lewym ogonie = straty częstsze i większe niż w rozkładzie normalnym\nSkośność %s, kurtoza nadwyżkowa %s",
                            num(mo$sk, 2), num(mo$ku, 1)),
         x = "Kwantyle teoretyczne (rozkład normalny)", y = "Kwantyle empiryczne (zwroty standaryzowane)",
         caption = note) +
    theme_viz()
}

plot_var_backtest <- function(dates, r, fc, exc, level, note) {
  j <- which(abs(as.numeric(colnames(fc$VaR[[1]])) - level) < 1e-9)
  df <- do.call(rbind, lapply(RISK_METHODS, function(m) {
    e <- exc[[paste(m, level)]]
    data.frame(date = dates, ret = r, var = -fc$VaR[[m]][, j], exc = e, method = m,
               label = sprintf("%s: %d wyjątków (oczekiwane ok. %.0f)", m, sum(e), length(e) * (1 - level)))
  }))
  df$label <- factor(df$label, levels = unique(df$label))
  ggplot(df, aes(date)) +
    geom_point(aes(y = ret), size = 0.35, color = COL$muted, alpha = 0.5) +
    geom_line(aes(y = var, color = method), linewidth = 0.6) +
    geom_point(data = df[df$exc, ], aes(y = ret), color = SLOTS[8], size = 1.4) +
    facet_wrap(~label, ncol = 2) +
    scale_color_manual(values = METHOD_COL, guide = "none") +
    scale_x_date(date_labels = "%Y", breaks = scales::breaks_pretty(n = 5)) +
    scale_y_continuous(labels = function(x) pct(x, 0)) +
    labs(title = sprintf("Backtest VaR %s: prognozy i wyjątki", pct(level, 0)),
         subtitle = "Szare punkty – dzienne zwroty portfela · kolorowa linia – VaR prognozowany na dany dzień (tylko z danych sprzed tego dnia)\nCzerwone punkty – wyjątki, czyli dni, w których strata była większa niż VaR",
         x = NULL, y = "Dzienny zwrot / -VaR", caption = note) +
    theme_viz()
}

plot_basel <- function(dates, exc, level, note) {
  roll <- do.call(rbind, lapply(RISK_METHODS, function(m) {
    e <- as.numeric(exc[[paste(m, level)]]); N <- length(e); cs <- c(0, cumsum(e))
    data.frame(date = dates[250:N], count = cs[251:(N + 1)] - cs[1:(N - 249)], method = m)
  }))
  roll$method <- factor(roll$method, levels = RISK_METHODS)
  ymax <- max(12, max(roll$count) + 1)
  zl <- c("zielona (0–4)", "żółta (5–9)", "czerwona (10+)")
  bands <- data.frame(zone = factor(zl, levels = zl), ymin = c(0, 4.5, 9.5), ymax = c(4.5, 9.5, ymax),
                      xmin = min(roll$date), xmax = max(roll$date))
  ggplot() +
    geom_rect(data = bands, aes(xmin = xmin, xmax = xmax, ymin = ymin, ymax = ymax, fill = zone), alpha = 0.18) +
    geom_step(data = roll, aes(date, count, color = method), linewidth = 0.8) +
    scale_fill_manual(values = setNames(c(SLOTS[3], SLOTS[4], SLOTS[8]), zl), name = "Strefa Bazylei") +
    scale_color_manual(values = METHOD_COL, name = "Metoda") +
    scale_x_date(date_labels = "%Y", breaks = scales::breaks_pretty(n = 6)) +
    scale_y_continuous(breaks = seq(0, ymax, by = 2)) +
    coord_cartesian(ylim = c(0, ymax), expand = FALSE) +
    labs(title = sprintf("Strefy Bazylei: liczba wyjątków VaR %s w oknie 250 sesji", pct(level, 0)),
         subtitle = "Linia = liczba wyjątków w ostatnich 250 sesjach · tło: strefa zielona 0–4, żółta 5–9 (dodatek do mnożnika kapitałowego),\nczerwona 10+ (model odrzucony przez regulatora)",
         x = NULL, y = "Wyjątki w ostatnich 250 sesjach", caption = note) +
    theme_viz()
}

plot_stress <- function(tbl, port_names, pname, note) {
  df <- tbl |>
    select(Typ, Scenariusz, all_of(port_names)) |>
    pivot_longer(all_of(port_names), names_to = "portfolio", values_to = "value")
  df$Scenariusz <- factor(df$Scenariusz, levels = rev(unique(tbl$Scenariusz)))
  df$portfolio  <- factor(df$portfolio, levels = rev(port_names))   # wybrany portfel na górze w parze słupków
  df$Typ        <- factor(df$Typ, levels = c("Historyczny", "Hipotetyczny"))
  dodge <- position_dodge(width = 0.75)
  ggplot(df, aes(value, Scenariusz, fill = portfolio)) +
    geom_vline(xintercept = 0, color = COL$axis, linewidth = 0.4) +
    geom_col(position = dodge, width = 0.65) +
    geom_text(aes(label = pct(value, 1), hjust = ifelse(value >= 0, -0.15, 1.15)), position = dodge,
              color = COL$secondary, size = 3.2) +
    facet_grid(Typ ~ ., scales = "free_y", space = "free_y") +
    scale_fill_manual(values = PORT_COL[port_names], name = NULL) +
    scale_x_continuous(labels = function(x) pct(x, 0), expand = expansion(mult = c(0.2, 0.2))) +
    scale_y_discrete(labels = scales::label_wrap(34)) +
    guides(fill = guide_legend(reverse = TRUE)) +
    labs(title = sprintf("Stress testy: strata portfela %s w scenariuszach kryzysowych", pname),
         subtitle = "Wagi stałe z początku scenariusza · scenariusze historyczne = realne zwroty spółek w danym okresie · hipotetyczne = założony szok",
         x = "Zwrot portfela w trakcie scenariusza", y = NULL, caption = note) +
    theme_viz() +
    theme(panel.grid.major.y = element_blank(), strip.text.y = element_text(angle = 0, hjust = 0))
}


# ------------------------------ 9. URUCHOMIENIE ------------------------------
cat("\n==================== OPTYMALNY PORTFEL MARKOWITZA ====================\n")
if (IS_DEMO) cat("!!! TRYB DEMO: dane są SYMULOWANE, to nie są prawdziwe notowania !!!\n")

N_STEPS <- 5 + RUN_RISK
cat(sprintf("[1/%d] Dane (%s): %s\n", N_STEPS, DATA_SOURCE, paste(TICKERS, collapse = ", ")))
# Dane dzienne pobieramy raz, od wcześniejszej z dat (START_DATE, RISK_START_DATE) – moduł ryzyka
# potrzebuje dłuższej historii (kryzys 2008), a część Markowitza używa tylko okresu od START_DATE.
DATA_START <- as.character(min(as.Date(START_DATE), if (RUN_RISK) as.Date(RISK_START_DATE) else as.Date(START_DATE)))
price_full <- switch(DATA_SOURCE,
  yahoo = load_yahoo(TICKERS, DATA_START, END_DATE),
  csv   = load_csv(CSV_PATH, TICKERS, DATA_START, END_DATE),
  demo  = simulate_prices(TICKERS, DATA_START, END_DATE, SEED))
price_df <- price_full[as.Date(price_full$Date) >= as.Date(START_DATE), , drop = FALSE]
prep <- prepare_returns(price_df, FREQUENCY)
R <- prep$returns
tickers <- colnames(R)
n <- length(tickers)
if (nrow(R) < 24) stop("Za mało obserwacji (", nrow(R), "). Wydłuż okres lub zwiększ częstotliwość.", call. = FALSE)
cat(sprintf("      wspólny okres: %s – %s, %d obserwacji (%s)\n",
            rownames(R)[1], rownames(R)[nrow(R)], nrow(R), FREQUENCY))

LO <- rep(MIN_WEIGHT, length.out = n); HI <- rep(MAX_WEIGHT, length.out = n)
if (any(LO > HI))        stop("MIN_WEIGHT jest większe od MAX_WEIGHT.", call. = FALSE)
if (sum(HI) < 1 - 1e-9)  stop(sprintf("MAX_WEIGHT = %.2f przy %d spółkach nie pozwala zebrać 100%% portfela. Zwiększ MAX_WEIGHT lub dodaj spółki (min. %d).",
                                      MAX_WEIGHT, n, ceiling(1 / MAX_WEIGHT)), call. = FALSE)
if (sum(LO) > 1 + 1e-9)  stop("MIN_WEIGHT jest zbyt duże – suma minimalnych wag przekracza 100%.", call. = FALSE)
SHORTS <- any(LO < 0)

cat(sprintf("[2/%d] Estymacja zwrotów i kowariancji\n", N_STEPS))
inp <- estimate_inputs(R, PPY, COV_METHOD, EXPECTED_RETURNS)
mu <- inp$mu; Sigma <- inp$Sigma
if (COV_METHOD == "shrinkage") cat(sprintf("      intensywność kurczenia Ledoit-Wolfa: %s\n", pct(inp$shrinkage, 1)))

cat(sprintf("[3/%d] Optymalizacja portfeli i granicy efektywnej\n", N_STEPS))
w_ms <- max_sharpe_weights(mu, Sigma, RISK_FREE_RATE, LO, HI)
w_mv <- solve_portfolio_qp(Sigma, LO, HI)
w_eq <- setNames(rep(1 / n, n), tickers)
portfolios <- list("Max Sharpe" = w_ms, "Min wariancja" = w_mv, "Równe wagi" = w_eq)
stats <- t(vapply(portfolios, port_stats, numeric(3), mu = mu, Sigma = Sigma, rf = RISK_FREE_RATE))
ef <- efficient_frontier(mu, Sigma, LO, HI, N_FRONTIER)
if (max(mu) <= RISK_FREE_RATE)
  warning("Żadna spółka nie ma oczekiwanego zwrotu powyżej stopy wolnej od ryzyka – wskaźnik Sharpe'a jest ujemny.", call. = FALSE)

set.seed(SEED)
cloud <- random_portfolios(N_RANDOM, LO, HI, mu, Sigma, RISK_FREE_RATE)

weights_wide <- data.frame(`Spółka` = tickers, as.data.frame(portfolios, check.names = FALSE),
                           check.names = FALSE, row.names = NULL)
assets_df <- data.frame(asset = tickers, ret = as.numeric(mu), vol = sqrt(diag(Sigma)))
special_df <- data.frame(portfolio = rownames(stats), ret = stats[, "ret"], vol = stats[, "vol"])

cat("\n--- Portfele (wartości roczne) ---\n")
print(data.frame(Portfel = rownames(stats), Zwrot = pct(stats[, "ret"], 2), Ryzyko = pct(stats[, "vol"], 2),
                 Sharpe = num(stats[, "sharpe"], 2)), row.names = FALSE)
cat("\n--- Wagi ---\n")
print(data.frame(`Spółka` = tickers, lapply(weights_wide[-1], function(x) pct(x, 1)), check.names = FALSE),
      row.names = FALSE)
cat("\n")

cat(sprintf("[4/%d] Wykresy\n", N_STEPS))
files <- c(
  save_plot(plot_prices(prep$prices, tickers), "01_notowania.png", 11, 2.2 + 2.1 * ceiling(n / min(4, n))),
  save_plot(plot_corr(R, tickers), "02_korelacje.png", 8, 7.2),
  save_plot(plot_frontier(ef, cloud, assets_df, special_df, RISK_FREE_RATE), "03_granica_efektywna.png", 11, 7),
  save_plot(plot_transition(ef, tickers, stats["Max Sharpe", "vol"], stats["Min wariancja", "vol"], SHORTS),
            "04_mapa_przejsc_wag.png", 10.5, 6.6),
  save_plot(plot_weights(portfolios, stats, tickers), "05_wagi_portfeli.png", 12, 2.6 + 0.42 * n),
  save_plot(plot_risk_share(w_ms, Sigma, tickers), "06_udzial_w_ryzyku.png", 10, 2.4 + 0.55 * n)
)

bt <- NULL
if (RUN_BACKTEST) {
  cat(sprintf("[5/%d] Backtest out-of-sample\n", N_STEPS))
  bt <- tryCatch(
    run_backtest(R, PPY, lookback = round(LOOKBACK_YEARS * PPY),
                 rebalance_every = max(1, round(REBALANCE_MONTHS / 12 * PPY)),
                 rf = RISK_FREE_RATE, lo = LO, hi = HI, cov_method = COV_METHOD, cost = TRANSACTION_COST),
    error = function(e) { message("      Pomijam backtest: ", conditionMessage(e)); NULL })
}
if (!is.null(bt)) {
  bt_tab <- backtest_stats(bt$returns, PPY, RISK_FREE_RATE)
  cat("\n--- Backtest (tylko dane out-of-sample) ---\n")
  print(data.frame(Strategia = bt_tab$Strategia,
                   `Zwrot roczny` = pct(bt_tab[[2]], 1), Ryzyko = pct(bt_tab[[3]], 1),
                   Sharpe = num(bt_tab[[4]], 2), `Maks. obsunięcie` = pct(bt_tab[[5]], 1),
                   `Wartość końcowa` = num(bt_tab[[6]], 0), check.names = FALSE), row.names = FALSE)
  cat("\n")
  files <- c(files,
    save_plot(plot_bt_wealth(bt, PPY), "07_backtest_wartosc.png", 11, 6.2),
    save_plot(plot_bt_drawdown(bt), "08_backtest_obsuniecie.png", 11, 5.4),
    save_plot(plot_bt_weights(bt, tickers), "09_backtest_sklad.png", 11, 7.4))
  write_csv_pl(bt_tab, "backtest_statystyki.csv")
  write_csv_pl(data.frame(Data = rownames(bt$returns), bt$returns, check.names = FALSE), "backtest_zwroty.csv")
}

if (RUN_RISK) {
  cat(sprintf("[6/%d] Moduł ryzyka: VaR, ES, backtest VaR, stress testy\n", N_STEPS))
  op <- options(width = max(getOption("width"), 130))   # szerokie tabele bez zawijania w konsoli
  tryCatch({
    prep_d <- prepare_returns(price_full, "daily")
    Rd <- prep_d$returns; Pd <- prep_d$prices
    dates_d <- as.Date(rownames(Rd)); Nd <- nrow(Rd)
    if (Nd < VAR_WINDOW + 250)
      stop("Za mało danych dziennych na backtest VaR: potrzeba min. ", VAR_WINDOW + 250, " sesji, jest ", Nd,
           ". Zmniejsz VAR_WINDOW albo ustaw wcześniejszy RISK_START_DATE.", call. = FALSE)
    wr <- portfolios[[RISK_PORTFOLIO]][colnames(Rd)]
    rp <- drop(Rd %*% wr)                       # dzienne zwroty portfela: stałe wagi, codzienne przeliczanie
    risk_note <- sprintf("%s | dane dzienne: %s – %s (%d sesji) | portfel %s: stałe wagi z optymalizacji na całej próbie",
                         if (IS_DEMO) "DANE SYMULOWANE (tryb demo)" else paste("Źródło:", DATA_SOURCE),
                         dates_d[1], dates_d[Nd], Nd, RISK_PORTFOLIO)
    cat(sprintf("      dane dzienne: %s – %s, %d sesji; portfel: %s\n", dates_d[1], dates_d[Nd], Nd, RISK_PORTFOLIO))

    # --- a) Rozkład zwrotów i VaR / ES na pełnej próbie ---
    mo <- moments_of(rp)
    jb <- Nd / 6 * (mo$sk^2 + mo$ku^2 / 4); p_jb <- stats::pchisq(jb, 2, lower.tail = FALSE)
    cat(sprintf("\n--- Rozkład dziennych zwrotów portfela %s ---\n", RISK_PORTFOLIO))
    cat(sprintf("średnia %s | zmienność dzienna %s | skośność %s | kurtoza nadwyżkowa %s | test Jarque-Bera: p = %s%s\n",
                pct(mo$m, 3), pct(mo$s, 2), num(mo$sk, 2), num(mo$ku, 1), num(p_jb, 4),
                if (p_jb < 0.05) "  -> rozkład NIE jest normalny (grube ogony)" else ""))
    sr <- rbind(static_risk(rp, VAR_LEVELS, EWMA_LAMBDA, VAR_WINDOW),
                stressed_var(wr, Rd, VAR_LEVELS, STRESS_VOL_MULT))
    cat("\n--- VaR i Expected Shortfall (dzienne, pełna próba) ---\n")
    print(data.frame(Metoda = sr$Metoda, Poziom = pct(sr$Poziom, 0), `VaR 1d` = pct_na(sr$VaR), `ES 1d` = pct_na(sr$ES),
                     `VaR 10d` = pct_na(sr$VaR * sqrt(10)), check.names = FALSE), row.names = FALSE)
    cat("(VaR 10d = VaR 1d * pierwiastek z 10; to przybliżenie, przy grubych ogonach zwykle niedoszacowane)\n")
    risk_all <- do.call(rbind, lapply(names(portfolios), function(nm) {
      rp_i <- drop(Rd %*% portfolios[[nm]][colnames(Rd)])
      cbind(Portfel = nm, static_risk(rp_i, VAR_LEVELS, EWMA_LAMBDA, VAR_WINDOW))
    }))
    risk_all <- rbind(risk_all, cbind(Portfel = RISK_PORTFOLIO, sr[grepl("^Stres", sr$Metoda), ]))
    write_csv_pl(data.frame(Portfel = risk_all$Portfel, Metoda = risk_all$Metoda, Poziom = risk_all$Poziom,
                            `VaR 1d` = risk_all$VaR, `ES 1d` = risk_all$ES, `VaR 10d (pierwiastek z czasu)` = risk_all$VaR * sqrt(10),
                            check.names = FALSE), "ryzyko_var_es.csv")
    files <- c(files,
      save_plot(plot_ret_dist(rp, sr, RISK_PORTFOLIO, risk_note), "10_ryzyko_rozklad_zwrotow.png", 10, 6),
      save_plot(plot_qq(rp, RISK_PORTFOLIO, risk_note), "11_ryzyko_qq.png", 8, 6.6))

    # --- b) Rolling backtest VaR ---
    cat(sprintf("\n[backtest VaR: okno %d sesji, prognoza na każdy dzień tylko z danych sprzed tego dnia]\n", VAR_WINDOW))
    fc <- var_forecasts(rp, VAR_WINDOW, VAR_LEVELS, EWMA_LAMBDA)
    ev <- evaluate_var(rp, fc, VAR_LEVELS)
    dates_e <- dates_d[fc$idx]; r_e <- rp[fc$idx]
    cat(sprintf("--- Backtest VaR: %s – %s, %d prognoz ---\n", dates_e[1], dates_e[length(dates_e)], length(dates_e)))
    tb <- ev$table
    print(data.frame(Metoda = tb$Metoda, Poziom = pct(tb$Poziom, 0),
                     `Wyjątki (oczekiwane)` = sprintf("%d (%.0f)", tb$`Wyjątki`, tb$`Oczekiwane wyjątki`),
                     `Kupiec p` = num(tb$`Kupiec p`, 3), `Christoffersen p` = num(tb$`Christoffersen p`, 3),
                     `Łączny p (CC)` = num(tb$`Łączny p (CC)`, 3),
                     `ES real./progn.` = ifelse(is.na(tb$`ES: strata realna / prognoza`), "–", num(tb$`ES: strata realna / prognoza`, 2)),
                     Wynik = ifelse(tb$`Łączny p (CC)` < 0.05, "ODRZUCONY", "ok"), check.names = FALSE), row.names = FALSE)
    cat("(p < 0,05 = model odrzucony; Kupiec: za dużo/mało wyjątków; Christoffersen: wyjątki w klastrach; ES realny/prognoza ~ 1 = dobrze skalibrowany)\n")
    cat("\n--- Strefy Bazylei (VaR 99%, ostatnie 250 sesji) ---\n")
    print(ev$zones, row.names = FALSE)
    cat("\n")
    write_csv_pl(tb, "ryzyko_backtest_var.csv")
    write_csv_pl(ev$zones, "ryzyko_strefy_bazylei.csv")
    fdf <- data.frame(Data = format(dates_e), `Zwrot portfela` = r_e, check.names = FALSE)
    for (m in RISK_METHODS) for (j in seq_along(VAR_LEVELS))
      fdf[[sprintf("VaR %s %s", pct(VAR_LEVELS[j], 0), m)]] <- fc$VaR[[m]][, j]
    write_csv_pl(fdf, "ryzyko_prognozy_var.csv")
    files <- c(files,
      save_plot(plot_var_backtest(dates_e, r_e, fc, ev$exc, 0.99, risk_note), "12_ryzyko_backtest_var.png", 11, 7),
      save_plot(plot_basel(dates_e, ev$exc, 0.99, risk_note), "13_ryzyko_strefy_bazylei.png", 11, 5.6))

    # --- c) Stress testy ---
    port_names <- unique(c(RISK_PORTFOLIO, "Równe wagi"))
    W <- sapply(port_names, function(nm) portfolios[[nm]][colnames(Rd)])
    hs <- if (IS_DEMO) list(rows = NULL, skipped = "scenariusze historyczne (dane symulowane)") else historical_stress(Pd, HIST_SCENARIOS, W)
    if (length(hs$skipped))
      cat("      Pominięte scenariusze (dane nie obejmują okna):", paste(hs$skipped, collapse = "; "), "\n")
    stress_tbl <- dplyr::bind_rows(hs$rows, hypothetical_stress(Rd, W, STRESS_MARKET_SHOCK, STRESS_NAME_SHOCK))
    cat("--- Stress testy (zwrot portfela w trakcie scenariusza) ---\n")
    print(data.frame(Scenariusz = stress_tbl$Scenariusz, stress_tbl[port_names] |> lapply(pct, digits = 1),
                     check.names = FALSE), row.names = FALSE)
    cat("\n")
    write_csv_pl(stress_tbl, "ryzyko_stress_testy.csv")
    files <- c(files, save_plot(plot_stress(stress_tbl, port_names, RISK_PORTFOLIO, risk_note), "14_ryzyko_stress_testy.png",
                                11, 3.2 + 0.7 * nrow(stress_tbl)))
  }, error = function(e) message("      Pomijam moduł ryzyka: ", conditionMessage(e)))
  options(op)
}

write_csv_pl(weights_wide, "wagi_portfeli.csv")
write_csv_pl(data.frame(Portfel = rownames(stats), `Zwrot roczny` = stats[, "ret"], `Ryzyko roczne` = stats[, "vol"],
                        Sharpe = stats[, "sharpe"], check.names = FALSE), "statystyki_portfeli.csv")
write_csv_pl(data.frame(`Ryzyko` = ef$vol, `Zwrot` = ef$ret, ef$W, check.names = FALSE), "granica_efektywna.csv")
write_csv_pl(data.frame(`Spółka` = tickers, `Oczekiwany zwrot roczny` = as.numeric(mu),
                        `Ryzyko roczne` = assets_df$vol, check.names = FALSE), "zalozenia_spolek.csv")

cat(sprintf("Gotowe. Wyniki w folderze '%s/': %d wykresów PNG + tabele CSV.\n", OUTPUT_DIR, length(files)))
if (IS_DEMO) cat("Przypomnienie: to były dane symulowane (DATA_SOURCE = \"demo\").\n")
cat("Uwaga: wyniki opierają się na danych historycznych i nie są rekomendacją inwestycyjną.\n")

