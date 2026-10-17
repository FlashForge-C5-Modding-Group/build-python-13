// Step generation benchmark for c_helper builds: drives Kalico's real
// pipeline (trapq -> input-shaped corexy itersolve -> stepcompress) with
// no Python in the way, times it, and checksums every queue_step message
// so builds with different flags can be checked for identical output.
// Build: gcc [flags] -o stepgen_bench stepgen_bench.c <chelper .c files> -lm
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include "list.h"
#include "msgblock.h"
#include "itersolve.h"
#include "stepcompress.h"
#include "trapq.h"

struct stepper_kinematics *corexy_stepper_alloc(char type);
struct stepper_kinematics *input_shaper_alloc(void);
int input_shaper_set_sk(struct stepper_kinematics *sk, struct stepper_kinematics *orig_sk);
int input_shaper_set_shaper_params(struct stepper_kinematics *sk, char axis, int n,
                                   double a[], double t[]);

static double now(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec * 1e-9;
}

int main(int argc, char **argv)
{
    int moves = argc > 1 ? atoi(argv[1]) : 20000;
    const double freq = 600e6;   // Creator 5 mainboard clock
    struct trapq *tq = trapq_alloc();
    struct stepper_kinematics *sk[2], *shaped[2];
    struct stepcompress *sc[2];
    struct list_head mq;
    list_init(&mq);
    // MZV at 60.8 / 64.2 Hz, as in the printer's [input_shaper]
    double a[3] = {0.2375, 0.5250, 0.2375}, tx[3], ty[3];
    double px = 1. / 60.8 / 2. / 0.99, py = 1. / 64.2 / 2. / 0.99;
    tx[0] = 0.; tx[1] = .375 * px * 2; tx[2] = .75 * px * 2;
    ty[0] = 0.; ty[1] = .375 * py * 2; ty[2] = .75 * py * 2;
    for (int i = 0; i < 2; i++) {
        sk[i] = corexy_stepper_alloc(i ? '-' : '+');
        itersolve_set_trapq(sk[i], tq, 0.0125);
        shaped[i] = input_shaper_alloc();
        input_shaper_set_sk(shaped[i], sk[i]);
        input_shaper_set_shaper_params(shaped[i], 'x', 3, a, tx);
        input_shaper_set_shaper_params(shaped[i], 'y', 3, a, ty);
        itersolve_set_trapq(shaped[i], tq, 0.0125);
        itersolve_set_position(shaped[i], 100., 100., 0.3);
        sc[i] = stepcompress_alloc(&mq);
        stepcompress_fill(sc[i], i + 1, 15000, 1, 2);   // max_error 25 us
        stepcompress_set_time(sc[i], 0., freq);
    }
    // Infill-like zigzag: short accel/cruise/decel segments in varying
    // directions at 300 mm/s and 10000 mm/s^2.
    double t = 0.1, x = 100., y = 100.;
    uint64_t sum = 1469598103934665603ULL, nmsg = 0;
    double busy = 0.;
    for (int i = 0; i < moves; i++) {
        double ang = (i % 7) * 0.9 + (i % 2) * 3.14159;
        double dx = __builtin_cos(ang), dy = __builtin_sin(ang);
        if (x < 40 || x > 260 || y < 40 || y > 220) {
            // head back toward the middle (motion stays continuous)
            double cx = 150. - x, cy = 130. - y, d = __builtin_sqrt(cx * cx + cy * cy);
            dx = cx / d; dy = cy / d;
        }
        double v = 300., acc = 10000., dist = 4. + (i % 5) * 3.;
        if (dist < v * v / acc)   // too short to reach v: triangle profile
            v = __builtin_sqrt(acc * dist);
        double at = v / acc, ad = .5 * acc * at * at;
        double ct = (dist - 2 * ad) / v;
        if (ct < 0.) ct = 0.;
        trapq_append(tq, t, at, ct, at, x, y, 0.3, dx, dy, 0., 0., v, acc);
        t += 2 * at + ct;
        x += dx * dist; y += dy * dist;
        if (i % 50 == 49) {
            double flush = t - 0.5, s = now();
            for (int j = 0; j < 2; j++) {
                itersolve_generate_steps(shaped[j], sc[j], flush);
                stepcompress_flush(sc[j], (uint64_t)(flush * freq));
            }
            busy += now() - s;
            trapq_finalize_moves(tq, flush - 0.1, flush - 1.);
            struct queue_message *qm, *n;
            list_for_each_entry_safe(qm, n, &mq, node) {
                for (int k = 0; k < qm->len; k++)
                    sum = (sum ^ qm->msg[k]) * 1099511628211ULL;
                nmsg++;
                list_del(&qm->node);
                message_free(qm);
            }
        }
    }
    printf("moves %d, queue_step messages %llu, step generation %.3f s, checksum %016llx\n",
           moves, (unsigned long long)nmsg, busy, (unsigned long long)sum);
    return 0;
}
