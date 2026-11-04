import numpy as np
import pandas as pd
import requests

BASE = "https://api.openf1.org/v1"
YEAR = 2026
CIRCUIT = "Monza"
SESSION = "Qualifying"

def get(endpoint, **params):
    r = requests.get(f"{BASE}/{endpoint}", params=params, timeout=60)
    r.raise_for_status()
    return r.json()

# 1. Find the session
sessions = get("sessions", year=YEAR, circuit_short_name=CIRCUIT, session_name=SESSION)
if not sessions:
    raise SystemExit("Session not found. Try YEAR = 2025.")
skey = sessions[0]["session_key"]

# 2. Candidate laps, fastest first
laps = pd.DataFrame(get("laps", session_key=skey)).dropna(subset=["lap_duration"])
laps = laps.sort_values("lap_duration").head(10)

car_cache = {}
chosen = None

for _, lap_row in laps.iterrows():
    drv = int(lap_row["driver_number"])
    if drv not in car_cache:
        c = pd.DataFrame(get("car_data", session_key=skey, driver_number=drv))
        c["date"] = pd.to_datetime(c["date"], utc=True, format="ISO8601")
        car_cache[drv] = c
    car = car_cache[drv]

    start = pd.to_datetime(lap_row["date_start"], utc=True)
    end = start + pd.to_timedelta(lap_row["lap_duration"], unit="s")
    lap = car[(car["date"] >= start) & (car["date"] <= end)].copy()
    if len(lap) < 50:
        print(f"Driver {drv}: only {len(lap)} samples, skipped")
        continue

    lap["t_s"] = (lap["date"] - start).dt.total_seconds()
    t = lap["t_s"].to_numpy()
    v = lap["speed"].to_numpy() / 3.6
    a = np.diff(v) / np.diff(t)

    # Measure each check
    thr_max = lap["throttle"].max()
    a_max_g = np.abs(a).max() / 9.81
    gap_max = np.diff(t).max()
    both = ((lap["brake"] > 0) & (lap["throttle"] > 90)).to_numpy().astype(int)
    longest_both = np.convolve(both, np.ones(3, dtype=int), "valid").max() if len(both) >= 3 else 0

    # Rules: catch frozen or invalid data, tolerate normal sampling noise
    reasons = []
    if thr_max > 100:      reasons.append(f"throttle max {thr_max:.0f} (invalid-data marker)")
    if a_max_g > 10:       reasons.append(f"accel {a_max_g:.1f} g (impossible)")
    if longest_both >= 3:  reasons.append("3+ consecutive brake+throttle samples (frozen data)")
    if gap_max > 1.5:      reasons.append(f"gap {gap_max:.2f} s")

    status = "clean" if not reasons else "rejected: " + ", ".join(reasons)
    print(f"Driver {drv}, {lap_row['lap_duration']:.3f} s, {len(lap)} samples: {status}")

    if not reasons and chosen is None:
        chosen = (drv, lap_row["lap_duration"], lap, t, v)

if chosen is None:
    raise SystemExit("No clean lap. Send me the printout.")

# 3. Distance (integrated from speed) and export
drv, lap_time, lap, t, v = chosen
lap["Distance"] = np.concatenate([[0], np.cumsum(np.diff(t) * (v[1:] + v[:-1]) / 2)])

out = lap.rename(columns={"speed": "Speed", "throttle": "Throttle", "brake": "Brake",
                          "n_gear": "nGear", "rpm": "RPM"})
out = out[["t_s", "Distance", "Speed", "Throttle", "Brake", "nGear", "RPM"]]
out.to_csv(f"{CIRCUIT}_{YEAR}_Q_clean.csv", index=False)

print(f"Chosen: driver {drv}, lap time {lap_time:.3f} s")
print(f"Saved {len(out)} samples, lap distance {out['Distance'].iloc[-1]:.0f} m")
