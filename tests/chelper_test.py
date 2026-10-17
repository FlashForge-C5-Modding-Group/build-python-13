# Exercise c_helper.so through cffi exactly like klippy does (doubles in and
# out), and hammer it plus libc/errno from threads. Prints values so a host
# build and the MIPS build can be diffed.
import sys, threading, math, os
sys.path.insert(0, sys.argv[1])          # kalico klippy dir, for chelper defs
import cffi
import chelper

ffi = cffi.FFI()
for d in chelper.defs_all:
    ffi.cdef(d)
lib = ffi.dlopen(sys.argv[2])

# Kalico forks differ: some take a step_dist here, some don't.
def set_trapq(sk, tq):
    try:
        lib.itersolve_set_trapq(sk, tq, 0.0125)
    except TypeError:
        lib.itersolve_set_trapq(sk, tq)

tq = lib.trapq_alloc()
t = 0.0
moves = [
    # accel_t, cruise_t, decel_t, start xyz, axes_r xyz, start_v, cruise_v, accel
    (0.05, 0.4, 0.05, 10.0, 20.0, 0.3, 0.8, 0.6, 0.0, 0.0, 300.0, 5000.0),
    (0.02, 0.0, 0.02, 132.5, 110.0, 0.3, -0.6, 0.8, 0.0, 12.5, 112.5, 9000.0),
    (0.1, 1.25, 0.1, 100.0, 150.0, 0.3, 0.0, 0.0, 1.0, 0.0, 15.0, 150.0),
]
for m in moves:
    lib.trapq_append(tq, t, *m)
    t += m[0] + m[1] + m[2]

out = []
for axis in (b"+", b"-"):
    sk = lib.corexy_stepper_alloc(axis)
    set_trapq(sk, tq)
    out.append(lib.itersolve_check_active(sk, t))
    for x, y, z in ((0.0, 0.0, 0.0), (123.456, -7.25, 3.5), (1e-9, 255.999, 0.2)):
        out.append(lib.itersolve_calc_position_from_coord(sk, x, y, z))
ext = lib.extruder_stepper_alloc()
try:
    lib.extruder_set_pressure_advance(ext, 0.5, 0.042, 0.04)
except TypeError:   # forks without the print_time argument
    lib.extruder_set_pressure_advance(ext, 0.042, 0.04)
shaper = lib.input_shaper_alloc()
cart = lib.cartesian_stepper_alloc(b"x")
set_trapq(cart, tq)
out.append(lib.input_shaper_set_sk(shaper, cart))
a = ffi.new("double[]", [0.25, 0.5, 0.25])
tt = ffi.new("double[]", [0.0, 0.0125, 0.025])
out.append(lib.input_shaper_set_shaper_params(shaper, b"x", 3, a, tt))
lib.trapq_finalize_moves(tq, t + 1.0, 0.0)
pm = ffi.new("struct pull_move[8]")
n = lib.trapq_extract_old(tq, pm, 8, 0.0, t + 1.0)
out.append(n)
for i in range(n):
    m = pm[i]
    out += [m.print_time, m.move_t, m.start_v, m.accel, m.start_x, m.start_y,
            m.start_z, m.x_r, m.y_r, m.z_r]
print("VALUES", " ".join(repr(v) for v in out))

# Threads: libc errno/TLS (ldexp overflow, failing stat) and cffi doubles,
# the pattern that crashed the old glibc 2.27 build in background threads.
errors = []
def worker(k):
    try:
        local_tq = lib.trapq_alloc()
        for i in range(2000):
            try:
                math.ldexp(1.5, 2000) if i % 7 else math.ldexp(1.0, -2000)
            except OverflowError:
                pass
            try:
                os.stat("/nonexistent/%d/%d" % (k, i))
            except OSError:
                pass
            try:
                float(10 ** 400 // 3 ** 100)   # PyLong_AsDouble -> ldexp
            except OverflowError:
                pass
            lib.trapq_append(local_tq, i * 0.01, 0.001, 0.0, 0.001, 0.0, 0.0,
                             0.0, 1.0, 0.0, 0.0, 0.0, 1.0, 1000.0)
        lib.trapq_free(local_tq)
    except Exception as e:
        errors.append(repr(e))
threads = [threading.Thread(target=worker, args=(k,)) for k in range(8)]
for th in threads: th.start()
for th in threads: th.join()
print("THREADS ok" if not errors else "THREADS errors %s" % errors[:3])
