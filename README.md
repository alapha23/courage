# Courage

A floating macOS widget that shows how much you've earned today, ticking up in real time while you work.

Enter your monthly **pre-tax** and/or **take-home** pay once. Courage works out your daily, hourly and per-second rate from the working days in the current month, then counts up from your start time to your finish time.

## Features

- **Earned today**, live to three decimal places. Click the number to switch between take-home and pre-tax.
- **Per second, hourly and daily** rates, worked time, progress bar and clock-out countdown.
- **This month so far** and workdays left.
- Knows about **weekends, public holidays, your days off and an unpaid lunch break**.
- **Menu bar** readout, which you can hide when screen sharing.
- Optional **payslip import**: reads the newest `YYYYMM.pdf` from a folder you choose.
- Floats above other windows on every Space. Drag it anywhere; it remembers where you left it.

## Install

Requires macOS 13+ and the Xcode Command Line Tools (`xcode-select --install`).

```sh
./build.sh                         # builds and installs to ~/Applications/Courage.app
open ~/Applications/Courage.app
```

`NO_INSTALL=1 ./build.sh` only builds (to `build/Courage.app`); `APPDIR=/Applications ./build.sh` installs elsewhere.

On first launch the Settings window opens. Enter your pay and hours, then click **Save**. Turn on **Launch at login** from the menu bar item.

## Settings

Open from the menu bar item → **Settings…** (⌘,).

| Setting | Notes |
|---|---|
| Pre-tax (gross) | Monthly pay before tax |
| Take-home (net) | Monthly pay after tax and deductions |
| Currency symbol | Defaults to your system currency |
| Start / Finish | Your working hours |
| Unpaid lunch | Minutes; excluded from paid time |
| Days off | Annual leave etc., as `YYYY-MM-DD`, comma-separated |
| Show amount in menu bar | Turn off for screen sharing |
| Payslip import | Optional folder, salary label and deduction labels |

Public holidays default to Ireland's 2026–27 list. To use your own, choose **Edit config file…** and replace `publicHolidays`.

### How the rate is worked out

```
daily      = monthly pay ÷ workdays this month (weekdays minus holidays and days off)
per second = daily ÷ paid seconds per day (finish − start − unpaid lunch)
```

### Payslip import

If you'd rather not type the numbers in, point Courage at a folder of payslip PDFs named `YYYYMM.pdf`. It reads the amount after the salary label as pre-tax, and subtracts each deduction label's amount to get take-home. The defaults (`SALARY`; `PAYE`, `PRSI`, `USC`) suit Irish payslips; change them to match yours. Any amount you type in Settings takes precedence.

## Privacy

- Everything stays on your Mac. Courage makes no network requests.
- Settings, including your pay, are saved to `~/Library/Application Support/Courage/config.json`, readable only by your user account (mode `600`).
- Payslips are read in place and never copied.
- Hide the menu bar amount before sharing your screen.

## Development

Everything is in `Sources/main.swift`. Set `COURAGE_CONFIG=/path/to/demo.json` to run against a throwaway config without touching your real one:

```sh
NO_INSTALL=1 ./build.sh
COURAGE_CONFIG=/tmp/demo.json ./build/Courage.app/Contents/MacOS/Courage
```
