# Knowledge Hub monitoring tool

A command-line tool that measures system metrics (CPU, memory and disk usage), stores them in a local SQLite database, and reports stored measurements over a chosen time period.

It runs without any interaction, so it can be scheduled (for example with cron on Linux or Task Scheduler on Windows).

## Requirements

- Python 3.12 or later
- psutil

```
pip install psutil
```

`sqlite3`, `argparse` and `logging` are part of the Python standard library.

## How to run

The tool has two modes: `measure` and `report`.

| Command | What it does |
| --- | --- |
| `python monitor.py measure` | Measures all metrics and adds them to the database |
| `python monitor.py measure --metrics cpu-usage memory-usage` | Measures only the chosen metrics |
| `python monitor.py measure --reset` | Deletes all stored measurements first, then measures |
| `python monitor.py report --start 2026-09-29` | Shows all measurements from that date until now |
| `python monitor.py report --start "2026-09-29 10:00" --end "2026-09-29 12:00"` | Shows measurements in a specific time window |
| `python monitor.py report --start 2026-09-29 --metric cpu-usage` | Shows only one metric |
| `python monitor.py --help` | Shows all options |

A date without a time counts as the start of that day for `--start`, and as the end of that day for `--end`. `--end` defaults to `now`.

## How it collects data

| Metric | Measured with | Meaning |
| --- | --- | --- |
| `cpu-usage` | `psutil.cpu_percent(interval=1)` | CPU usage in percent, averaged over one second |
| `memory-usage` | `psutil.virtual_memory().percent` | RAM in use, in percent |
| `disk-usage` | `psutil.disk_usage("/").percent` | Used space on the main disk, in percent |

All metrics measured in one run share the same timestamp.

## Storage

Measurements are stored in `measurements.db` (SQLite), in one table:

| Column | Type | Content |
| --- | --- | --- |
| `id` | INTEGER | Unique number per measurement |
| `timestamp` | TEXT | Date and time, format `YYYY-MM-DD HH:MM:SS` |
| `metric` | TEXT | Name of the metric, e.g. `cpu-usage` |
| `value` | REAL | Measured value in percent |

The tool only adds rows. Existing data is never overwritten, unless you explicitly use `--reset`. A different database file can be used with `--db <file>`.

## Output format

`measure` prints one line per metric:

```
2026-09-29 11:31:30  cpu-usage         4.3%
2026-09-29 11:31:30  memory-usage     88.4%
2026-09-29 11:31:30  disk-usage       25.0%
```

`report` prints a table, followed by the average per metric and the number of measurements:

```
Measurements from 2026-09-29 00:00:00 to 2026-09-29 11:31:47
=============================================
Timestamp            Metric             Value
---------------------------------------------
2026-09-29 11:31:30  cpu-usage           4.3%
2026-09-29 11:31:30  disk-usage         25.0%
2026-09-29 11:31:30  memory-usage       88.4%
---------------------------------------------
Average cpu-usage                        4.3%  (1x)
Average disk-usage                      25.0%  (1x)
Average memory-usage                    88.4%  (1x)
```

## Log format

Every measurement, report, reset and error is written to `monitor.log`:

```
2026-09-29 11:31:30,512 INFO Measured cpu-usage = 4.3%
2026-09-29 11:31:47,201 INFO Report 2026-09-29 00:00:00 to 2026-09-29 11:31:47: 3 measurements
2026-09-29 11:40:02,118 WARNING All stored measurements were deleted (--reset)
2026-09-29 11:41:15,004 ERROR 'banana' is not a valid date or time, use for example 2026-09-29 or '2026-09-29 14:00'
```

Each line has a date and time, a level (INFO, WARNING or ERROR) and a message.

## Adding a metric

Write a function that returns the value, and add it to the `METRICS` dictionary in `monitor.py`:

```python
def measure_swap():
    """Return the swap usage in percent."""
    return psutil.swap_memory().percent


METRICS = {
    ...
    "swap-usage": measure_swap,
}
```

The new metric is then available in `--metrics`, `--metric` and the report automatically.

## History

- Task 5: interactive script that asks for a hostname, IP address and metric names, and shows them as a summary.
- Tasks 10 and 11: non-interactive command-line tool that measures real metrics, stores them in SQLite, and reports them over a time period.
