#!/bin/bash
# Checks. Not an Xcode test target: these compile the sources straight with swiftc, so
# they run in a few seconds with no scheme, no simulator, no host app.
#
# Checks/ sits outside Pomodore/Pomodore/, which is a file-system synchronized group, so
# nothing in here is ever compiled into the app.
#
# menubar.d needs a logged-in GUI session and briefly puts a real item in the menu bar.
set -euo pipefail

cd "$(dirname "$0")"

MODEL=(../Pomodore/Phase.swift ../Pomodore/Settings.swift ../Pomodore/WakeLock.swift
       ../Pomodore/TimerEngine.swift ../Pomodore/SystemSounds.swift ../Pomodore/Alerts.swift
       ../Pomodore/SessionStore.swift ../Pomodore/Chord.swift ../Pomodore/HotKey.swift)

# menubar.d drives the real controller, so it needs the view layer too. Everything except
# PomodoreApp.swift, which owns @main.
UI=("${MODEL[@]}" ../Pomodore/Theme.swift ../Pomodore/PopoverView.swift
    ../Pomodore/HotKeyController.swift ../Pomodore/ChordRecorder.swift
    ../Pomodore/SettingsView.swift ../Pomodore/SettingsWindow.swift
    ../Pomodore/MenuBarController.swift)

OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT

for check in engine history assertions hotkey menubar; do
  case "$check" in
    menubar | hotkey) SRC=("${UI[@]}") ;;
    *) SRC=("${MODEL[@]}") ;;
  esac
  echo "== $check"
  swiftc -swift-version 6 -target arm64-apple-macos14.0 \
    "${SRC[@]}" "$check.d/main.swift" -o "$OUT/$check"

  # The UI checks drive real AppKit controls, which can in principle wedge the main
  # queue and outlive their own watchdog. Never let that hang the whole run.
  "$OUT/$check" &
  pid=$!
  waited=0
  while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt 90 ]; do
    sleep 1
    waited=$((waited + 1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill -9 "$pid" 2>/dev/null
    echo "FAIL  $check wedged and was killed after ${waited}s"
    exit 1
  fi
  wait "$pid"
done
