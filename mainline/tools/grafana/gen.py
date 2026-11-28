#!/usr/bin/env python3
# Generates u2ac-drives.json, the Grafana dashboard for the home upload (Pushgateway job "u2ac", one group per
# flight-log slot: label log_seq). Datasource: the dashboard variable ds (any Prometheus). python3 gen.py
import json

DS = {"type": "prometheus", "uid": "${ds}"}
R = "[$__range]"

def per(expr):   # one value per drive over the dashboard range
    return f"max by (log_seq) (max_over_time({expr}{R}))"

ALL = f"max by (log_seq) (max_over_time(u2ac_flightlog_seq{R}))"
def full(expr):  # every drive gets a row: NaN (shown as a dash) where expr has nothing for it (an empty frame
    return f"({expr}) or on(log_seq) ({ALL} * NaN)"   # would leave the whole table empty)

def latest(m):   # the latest uploaded drive that has metric m
    return f"max({m} and on(log_seq) (u2ac_flightlog_seq == scalar(max(u2ac_flightlog_seq and on(log_seq) {m}))))"

def th(*steps):  # thresholds: th("green", (26, "yellow"), (35, "red"))
    out = [{"color": steps[0], "value": None}]
    out += [{"color": c, "value": v} for v, c in steps[1:]]
    return {"mode": "absolute", "steps": out}

GRN, YEL, RED, BLU, PUR, TXT = "green", "#EAB839", "red", "#5794F2", "#B877D9", "text"
T_AA = th(GRN, (26, YEL), (35, RED))
T_WIFI = th(GRN, (18, YEL), (25, RED))
T_ZERO = th(GRN, (1, RED))
T_TEMP = th(GRN, (70, YEL), (80, RED))
T_SIG = th(RED, (-80, YEL), (-70, GRN))
T_DEV = th(GRN, (2, RED))
T_REP = th(GRN, (1, YEL))

NULLMAP = {"type": "special", "options": {"match": "null+nan", "result": {"text": "–", "color": "text", "index": 99}}}
panels = []
pid = [0]
def add(p):
    pid[0] += 1; p["id"] = pid[0]; panels.append(p); return p

def row(title, y, collapsed=False):
    add({"type": "row", "title": title, "collapsed": collapsed, "gridPos": {"h": 1, "w": 24, "x": 0, "y": y}, "panels": []})

def stat(title, desc, expr, unit, x, y, w=3, h=4, thr=None, dec=1, mappings=None, color_mode="value"):
    return add({"type": "stat", "title": title, "description": desc, "datasource": DS,
        "gridPos": {"h": h, "w": w, "x": x, "y": y},
        "targets": [{"refId": "A", "datasource": DS, "expr": expr, "instant": True, "range": False}],
        "fieldConfig": {"defaults": {"unit": unit, "decimals": dec, "noValue": "–", "color": {"mode": "thresholds"},
                                     "thresholds": thr or th(TXT), "mappings": (mappings or []) + [NULLMAP]}, "overrides": []},
        "options": {"reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False}, "colorMode": color_mode,
                    "graphMode": "none", "textMode": "value", "justifyMode": "center", "wideLayout": True,
                    "showPercentChange": False}})

def drive_axis(value_names):  # table frames by log_seq -> one row per drive, oldest left
    return [{"id": "merge", "options": {}},
            {"id": "organize", "options": {"excludeByName": {"Time": True}, "renameByName": dict({"log_seq": "Drive"}, **value_names)}},
            {"id": "convertFieldType", "options": {"conversions": [{"targetField": "Drive", "destinationType": "number"}]}},
            {"id": "sortBy", "options": {"sort": [{"field": "Drive", "desc": False}]}},
            {"id": "convertFieldType", "options": {"conversions": [{"targetField": "Drive", "destinationType": "string"}]}}]

def bars(title, desc, targets, names, unit, x, y, w, h, stacking="none", thr=None, colors=None, dec=1, axis=""):
    overrides = [{"matcher": {"id": "byName", "options": n}, "properties": [{"id": "color", "value": {"mode": "fixed", "fixedColor": c}}]}
                 for n, c in (colors or {}).items()]
    overrides.append({"matcher": {"id": "byName", "options": "Drive"}, "properties": [{"id": "unit", "value": "none"}]})
    color = {"mode": "thresholds"} if thr else {"mode": "palette-classic"}
    return add({"type": "barchart", "title": title, "description": desc, "datasource": DS,
        "gridPos": {"h": h, "w": w, "x": x, "y": y},
        "targets": [{"refId": r, "datasource": DS, "expr": e, "instant": True, "range": False, "format": "table"} for r, e in targets],
        "transformations": drive_axis(names),
        "fieldConfig": {"defaults": {"unit": unit, "decimals": dec, "color": color, "thresholds": thr or th(BLU),
                                     "custom": {"fillOpacity": 85, "lineWidth": 0, "gradientMode": "none", "axisLabel": axis,
                                                "axisPlacement": "auto", "axisSoftMin": 0 if unit != "dBm" else None}},
                        "overrides": overrides},
        "options": {"xField": "Drive", "orientation": "vertical", "groupWidth": 0.7, "barWidth": 0.85, "barRadius": 0.05,
                    "showValue": "never", "stacking": stacking, "xTickLabelRotation": 0, "xTickLabelSpacing": 0,
                    "colorByField": None, "fullHighlight": False,
                    "legend": {"displayMode": "list", "placement": "bottom", "showLegend": bool(colors)},
                    "tooltip": {"mode": "multi", "sort": "none"}}})

y = 0
add({"type": "text", "title": "", "gridPos": {"h": 2, "w": 24, "x": 0, "y": y}, "transparent": True,
     "options": {"mode": "markdown", "content":
        "**One bar or row per drive** (the dongle's flight-log number). A drive's numbers arrive at the start of the "
        "next drive from home, so the newest drive shows up then. Start-up times are seconds from power-on. "
        "Hover a panel title for what it measures."}})
y += 2
row("Latest drive", y); y += 1
stat("AA on screen", "Seconds from power-on until Android Auto was on the car screen.", latest('u2ac_aa_event_seconds{event="proxying"}'), "s", 0, y, thr=T_AA)
stat("On hotspot", "Seconds from power-on until the phone reported it joined the dongle's Wi-Fi.", latest('u2ac_aa_event_seconds{event="wifi_joined"}'), "s", 3, y, thr=T_WIFI)
stat("Drive length", "How long the dongle was powered (within a minute: it records once a minute).", latest("u2ac_drive_seconds"), "dtdurations", 6, y, dec=0)
stat("Drops", "Times Android Auto stopped and restarted during the drive.", latest("u2ac_drive_drops"), "none", 9, y, thr=T_ZERO, dec=0)
stat("Peak temp", "Highest chip temperature during the drive. It throttles at 85 °C.", latest("u2ac_drive_temperature_max_celsius"), "celsius", 12, y, thr=T_TEMP, dec=0)
stat("Worst signal", "Weakest Wi-Fi signal from the phone during the drive (closer to 0 is better).", latest("u2ac_drive_signal_min_dbm"), "dBm", 15, y, thr=T_SIG, dec=0)
stat("Data relayed", "Wi-Fi data between phone and dongle during the drive (mostly the video to the car).", f"({latest('u2ac_drive_rx_bytes')}) + ({latest('u2ac_drive_tx_bytes')})", "decbytes", 18, y, dec=0)
stat("Started", "Wall-clock start of the latest drive that began at home (only those drives learn the time).", latest("u2ac_drive_start_timestamp_seconds") + " * 1000", "dateTimeAsLocalNoDateIfToday", 21, y, dec=0)
y += 4
stat("Last upload", "When the dongle last sent its drive logs.", 'max(push_time_seconds{job="u2ac"}) * 1000', "dateTimeFromNow", 0, y, w=4, h=3, dec=0)
stat("Drives", "Drives with Android Auto in the selected time range.", f'count(count by (log_seq) (max_over_time(u2ac_flightlog_info{{why="session+60s"}}{R}))) or vector(0)', "none", 4, y, w=4, h=3, dec=0)
stat("Slow or failed starts", "Power-ons with no Android Auto session in the first 90 s (a phone VPN, Bluetooth off, no phone).", f'count(count by (log_seq) (max_over_time(u2ac_flightlog_info{{why="start+90s"}}{R}))) or vector(0)', "none", 8, y, w=4, h=3, thr=T_ZERO, dec=0)
stat("Hotspot devices", "Different devices that joined the dongle's Wi-Fi in the latest drive. More than 1 means not only your phone.", latest("u2ac_drive_hotspot_devices"), "none", 12, y, w=4, h=3, thr=T_DEV, dec=0)
reset_q = ('max(((u2ac_last_reset{cause="power"} * 1) or (u2ac_last_reset{cause="software"} * 2) or (u2ac_last_reset{cause="watchdog"} * 3) or (u2ac_last_reset{cause="unknown"} * 4))'
           ' and on(log_seq) (u2ac_flightlog_seq == scalar(max(u2ac_flightlog_seq and on(log_seq) u2ac_last_reset))))')
stat("How it started", "What started the dongle for the latest drive: a power-on is normal; a reboot or the watchdog is not.", reset_q, "none", 16, y, w=4, h=3, dec=0,
     mappings=[{"type": "value", "options": {"1": {"text": "Power-on", "color": GRN, "index": 0}, "2": {"text": "Reboot", "color": YEL, "index": 1},
                                             "3": {"text": "Watchdog", "color": RED, "index": 2}, "4": {"text": "Unknown", "color": TXT, "index": 3}}}])
stat("Repairs", "Radio daemon repairs plus relay restarts in the latest drive.", f"({latest('u2ac_drive_radio_repairs')}) + ({latest('u2ac_drive_relay_restarts')})", "none", 20, y, w=4, h=3, thr=T_REP, dec=0)
y += 3

row("Start-up", y); y += 1
ev = lambda e: f'max_over_time(u2ac_aa_event_seconds{{event="{e}"}}{R})'
bars("Where the start-up time goes", "Per drive, stacked: power-on until the dongle calls the phone over Bluetooth, then until the phone is on the dongle's Wi-Fi, then until the car shows Android Auto. The bar's height is the time to Android Auto.",
     [("A", f"max by (log_seq) ({ev('bt_try')})"),
      ("B", f"clamp_min(max by (log_seq) ({ev('wifi_joined')}) - max by (log_seq) ({ev('bt_try')}), 0)"),
      ("C", f"clamp_min(max by (log_seq) ({ev('proxying')}) - max by (log_seq) ({ev('wifi_joined')}), 0)")],
     {"Value #A": "Dongle starts, calls phone", "Value #B": "Phone joins hotspot", "Value #C": "Car switches to Android Auto"},
     "s", 0, y, 16, 9, stacking="normal", axis="seconds from power-on",
     colors={"Dongle starts, calls phone": BLU, "Phone joins hotspot": PUR, "Car switches to Android Auto": GRN})
add({"type": "bargauge", "title": "Latest drive, step by step", "description": "Seconds from power-on to each step of the latest drive's start.",
     "datasource": DS, "gridPos": {"h": 9, "w": 8, "x": 16, "y": y},
     "targets": [{"refId": r, "datasource": DS, "instant": True, "range": False, "legendFormat": name,
                  "expr": latest(f'u2ac_aa_event_seconds{{event="{e}"}}')} for r, e, name in
                 [("A", "bt_try", "Dongle calls the phone"), ("B", "bt_connected", "Phone answers (Bluetooth)"),
                  ("C", "wifi_joined", "Phone on the hotspot"), ("D", "phone_tcp", "Phone connects to the relay"),
                  ("E", "car_aoa_start", "Car asks for Android Auto"), ("F", "proxying", "Android Auto on screen")]],
     "fieldConfig": {"defaults": {"unit": "s", "decimals": 1, "min": 0, "color": {"mode": "thresholds"}, "thresholds": T_AA}, "overrides": []},
     "options": {"orientation": "horizontal", "displayMode": "gradient", "showUnfilled": True, "valueMode": "color",
                 "namePlacement": "top", "sizing": "auto", "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False}}})
y += 9

row("Drives", y); y += 1
cols = [  # refId, expr, column, unit, decimals, thresholds
    ("A", f"max by (log_seq, why) (max_over_time(u2ac_flightlog_info{R}))", None, None, None, None),
    ("B", per("u2ac_drive_start_timestamp_seconds") + " * 1000", "Started", "dateTimeAsLocal", 0, None),
    ("C", per("u2ac_drive_seconds"), "Length", "dtdurations", 0, None),
    ("D", per('u2ac_aa_event_seconds{event="proxying"}'), "Android Auto", "s", 1, T_AA),
    ("E", per('u2ac_aa_event_seconds{event="wifi_joined"}'), "On hotspot", "s", 1, T_WIFI),
    ("F", per("u2ac_drive_drops"), "Drops", "none", 0, T_ZERO),
    ("G", per("u2ac_drive_temperature_max_celsius"), "Peak temp", "celsius", 0, T_TEMP),
    ("H", per("u2ac_drive_signal_min_dbm"), "Worst signal", "dBm", 0, T_SIG),
    ("I", f"max by (log_seq) (max_over_time(u2ac_drive_rx_bytes{R}) + max_over_time(u2ac_drive_tx_bytes{R}))", "Data", "decbytes", 0, None),
    ("J", per("u2ac_drive_hotspot_devices"), "Devices", "none", 0, T_DEV),
    ("K", f"max by (log_seq) (max_over_time(u2ac_drive_radio_repairs{R}) + max_over_time(u2ac_drive_relay_restarts{R}))", "Repairs", "none", 0, T_REP),
    ("L", "max by (log_seq) (" + " or ".join(f'(max by (log_seq) (max_over_time(u2ac_last_reset{{cause="{c}"}}{R})) * {n})' for c, n in
                                                (("power", 1), ("software", 2), ("watchdog", 3), ("unknown", 4))) + ")", "Started by", "none", 0, None),
    ("M", per("u2ac_home_upload_seconds"), "Upload", "s", 1, None),
]
rename = {"log_seq": "Drive", "why": "Log"}
exclude = {"Time": True, "Value #A": True}
order = {"log_seq": 0}
overrides = []
for i, (ref, expr, name, unit, dec, thr) in enumerate(cols):
    if name:
        rename[f"Value #{ref}"] = name; order[f"Value #{ref}"] = i + 1
        props = [{"id": "unit", "value": unit}, {"id": "decimals", "value": dec}]
        if thr:
            props += [{"id": "thresholds", "value": thr}, {"id": "color", "value": {"mode": "thresholds"}},
                      {"id": "custom.cellOptions", "value": {"type": "color-text"}}]
        overrides.append({"matcher": {"id": "byName", "options": name}, "properties": props})
order["why"] = len(cols) + 1
overrides.append({"matcher": {"id": "byName", "options": "Log"}, "properties": [
    {"id": "mappings", "value": [{"type": "value", "options": {
        "session+60s": {"text": "drive", "index": 0}, "start+90s": {"text": "no Android Auto in 90 s", "color": RED, "index": 1},
        "session-end": {"text": "session ended", "index": 2}, "periodic": {"text": "update", "index": 3},
        "sleep": {"text": "car-off sleep", "index": 4}, "bench-test": {"text": "bench test", "index": 5}}}]},
    {"id": "custom.cellOptions", "value": {"type": "color-text"}}]})
overrides.append({"matcher": {"id": "byName", "options": "Started by"}, "properties": [
    {"id": "mappings", "value": [NULLMAP, {"type": "value", "options": {
        "1": {"text": "power-on", "color": TXT, "index": 0}, "2": {"text": "reboot", "color": YEL, "index": 1},
        "3": {"text": "watchdog", "color": RED, "index": 2}, "4": {"text": "unknown", "color": TXT, "index": 3}}}]},
    {"id": "custom.cellOptions", "value": {"type": "color-text"}}]})
overrides.append({"matcher": {"id": "byName", "options": "Drive"}, "properties": [{"id": "custom.width", "value": 70}]})
add({"type": "table", "title": "All drives", "description": "One row per flight-log entry, newest first. Dashes: not recorded by that firmware or not known (start times exist only for drives that began at home).",
     "datasource": DS, "gridPos": {"h": 10, "w": 24, "x": 0, "y": y},
     "targets": [{"refId": r, "datasource": DS, "expr": full(e), "instant": True, "range": False, "format": "table"} for r, e, *_ in cols],
     "transformations": [
         {"id": "joinByField", "options": {"byField": "log_seq", "mode": "outer"}},
         {"id": "filterFieldsByName", "options": {"include": {"pattern": "^(?!Time).*$"}}},
         {"id": "organize", "options": {"excludeByName": exclude, "renameByName": rename, "indexByName": order}},
         {"id": "convertFieldType", "options": {"conversions": [{"targetField": "Drive", "destinationType": "number"}]}},
         {"id": "sortBy", "options": {"sort": [{"field": "Drive", "desc": True}]}}],
     "fieldConfig": {"defaults": {"noValue": "–", "mappings": [NULLMAP], "custom": {"align": "auto", "cellOptions": {"type": "auto"}, "inspect": False, "minWidth": 70}}, "overrides": overrides},
     "options": {"showHeader": True, "cellHeight": "sm", "footer": {"show": False}, "sortBy": [{"displayName": "Drive", "desc": True}]}})
y += 10

row("Per drive", y); y += 1
bars("Data relayed", "Wi-Fi data between phone and dongle per drive (mostly the video to the car).", [("A", f"max by (log_seq) (max_over_time(u2ac_drive_rx_bytes{R}) + max_over_time(u2ac_drive_tx_bytes{R}))")], {"Value": "Data relayed"}, "decbytes", 0, y, 6, 7, thr=th(BLU), dec=0)
bars("Peak temperature", "Highest chip temperature per drive.", [("A", per("u2ac_drive_temperature_max_celsius"))], {"Value": "Peak temperature"}, "celsius", 6, y, 6, 7, thr=T_TEMP, dec=0)
bars("Worst phone signal", "Weakest Wi-Fi signal from the phone per drive.", [("A", per("u2ac_drive_signal_min_dbm"))], {"Value": "Worst signal"}, "dBm", 12, y, 6, 7, thr=T_SIG, dec=0)
bars("Drive length", "How long the dongle was powered per drive.", [("A", per("u2ac_drive_seconds"))], {"Value": "Drive length"}, "dtdurations", 18, y, 6, 7, thr=th(BLU), dec=0)
y += 7

row("Home upload", y); y += 1
stat("Upload time", "How long the latest upload took (it starts before the hotspot; the limit is 4 s at a car start).", latest("u2ac_home_upload_seconds"), "s", 0, y, w=4, h=4, thr=th(GRN, (3, YEL), (4, RED)))
stat("Home Wi-Fi signal", "Signal of the home network where the car was parked, at the latest upload.", latest("u2ac_home_upload_signal_dbm"), "dBm", 4, y, w=4, h=4, thr=th(RED, (-82, YEL), (-75, GRN)), dec=0)
stat("Old lease used", "1 when DHCP did not answer in time and the dongle used its last address.", latest("u2ac_home_upload_lease_reused"), "none", 8, y, w=4, h=4, thr=th(GRN, (1, YEL)), dec=0,
     mappings=[{"type": "value", "options": {"0": {"text": "No", "index": 0}, "1": {"text": "Yes", "index": 1}}}])
bars("Upload time per drive", "Per drive, the time each step of its upload took: find the network, join it, get an address (the rest is sending).",
     [("A", per('u2ac_home_upload_phase_seconds{phase="scan"}')), ("B", per('u2ac_home_upload_phase_seconds{phase="join"}')),
      ("C", per('u2ac_home_upload_phase_seconds{phase="address"}'))],
     {"Value #A": "Find network", "Value #B": "Join", "Value #C": "Get address"}, "s", 12, y, 12, 8, stacking="normal",
     colors={"Find network": BLU, "Join": PUR, "Get address": GRN})
y += 8

dash = {"uid": "u2ac-drives", "title": "Car dongle", "tags": ["carlinkit", "u2ac", "android-auto"],
        "description": "Carlinkit U2AC mainline firmware: per-drive health from the flight log, sent by the home upload (Pushgateway job u2ac).",
        "timezone": "browser", "editable": True, "graphTooltip": 1, "schemaVersion": 39, "refresh": "",
        "time": {"from": "now-90d", "to": "now"}, "timepicker": {"hidden": False},
        "templating": {"list": [{"name": "ds", "label": "Prometheus", "type": "datasource", "query": "prometheus",
                                 "hide": 0, "refresh": 1, "current": {}}]},
        "panels": panels}
json.dump(dash, open("u2ac-drives.json", "w"), indent=1)
print("panels", len(panels))
