# Run Kalico's input shaper calibration maths on a synthetic accelerometer
# recording (resonance at 46 Hz on X, 58 Hz on Y) and print the results, so
# an x86 numpy and the MIPS build can be compared.
# Usage: python numpy_test.py KALICO_KLIPPY_DIR
import sys
sys.path.insert(0, sys.argv[1])
import numpy as np
from extras import shaper_calibrate

fs, secs = 3200.0, 4.0
t = np.arange(int(fs * secs)) / fs
rng = np.random.default_rng(1234)
def axis(freq):
    sweep = np.sin(2 * np.pi * (5 + 30 * t) * t)
    ring = np.sin(2 * np.pi * freq * t) * np.exp(-((t % 0.5) * 8.0))
    return 2000.0 * sweep + 9000.0 * ring + rng.normal(0, 150.0, t.size)
data = np.column_stack([t, axis(46.0), axis(58.0), rng.normal(0, 80.0, t.size)])

cal = shaper_calibrate.ShaperCalibrate(None)
cd = cal.calc_freq_response(data)
cd.set_numpy(np)
cd.normalize_to_frequencies()
print("numpy", np.__version__)
print("PSD peak X %.3f Hz, Y %.3f Hz" % (cd.freq_bins[cd.psd_x.argmax()],
                                        cd.freq_bins[cd.psd_y.argmax()]))
best, shapers = cal.find_best_shaper(cd, scv=5.0)
for s in shapers:
    print("SHAPER %-5s freq %.1f vibrs %.4f smoothing %.4f max_accel %.0f"
          % (s.name, s.freq, s.vibrs, s.smoothing, s.max_accel))
print("BEST %s %.1f" % (best.name, best.freq))
print("LINALG", np.round(np.linalg.solve([[3.0, 1.0], [1.0, 2.0]], [9.0, 8.0]), 12),
      round(float(np.linalg.det(np.eye(3) * 2.5)), 9))
