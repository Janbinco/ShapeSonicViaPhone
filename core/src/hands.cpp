// Fingertips from a depth camera, for the "hands in the air" mode: depth at a
// fingertip, unprojection, one-euro smoothing, and placing the shape in front
// of a device that stays still. See shapesonic.h.

#include <algorithm>
#include <cmath>
#include <vector>

#include "shapesonic.h"

float ss_fingertip_depth(const float *depth, int width, int height, size_t row_stride, float tip_u,
                         float tip_v, float dip_u, float dip_v, float radius_px) {
  if (!depth || width <= 0 || height <= 0) return NAN;
  const float su = tip_u + 0.25f * (dip_u - tip_u);
  const float sv = tip_v + 0.25f * (dip_v - tip_v);
  const int r = std::max(1, (int)std::lround(radius_px));
  const int cu = (int)std::lround(su), cv = (int)std::lround(sv);
  float samples[256];
  int n = 0;
  for (int dv = -r; dv <= r; dv++) {
    for (int du = -r; du <= r; du++) {
      if (du * du + dv * dv > r * r || n >= 256) continue;
      const int u = cu + du, v = cv + dv;
      if (u < 0 || v < 0 || u >= width || v >= height) continue;
      const float z = depth[(size_t)v * row_stride + u];
      if (std::isfinite(z) && z > 0.05f && z < 3.0f) samples[n++] = z;
    }
  }
  if (n == 0) return NAN;
  const int k = n / 5;  // 20th percentile
  std::nth_element(samples, samples + k, samples + n);
  return samples[k];
}

void ss_unproject(const ss_intrinsics *k, float u, float v, float z, float out[3]) {
  out[0] = (u - k->cx) / k->fx * z;
  out[1] = (v - k->cy) / k->fy * z;
  out[2] = z;
}

void ss_one_euro3_init(ss_one_euro3 *f, float min_cutoff, float beta) {
  *f = ss_one_euro3{};
  f->min_cutoff = min_cutoff;
  f->beta = beta;
  f->d_cutoff = 1.0f;
}

static float smoothing_alpha(float cutoff, float dt) {
  const float tau = 1.0f / (2.0f * 3.14159265f * cutoff);
  return 1.0f / (1.0f + tau / dt);
}

void ss_one_euro3_filter(ss_one_euro3 *f, const float in[3], double t, float out[3]) {
  if (!f->initialized || t <= f->t || t - f->t > 0.5) {
    for (int i = 0; i < 3; i++) f->x[i] = in[i], f->dx[i] = 0;
    f->t = t;
    f->initialized = 1;
    for (int i = 0; i < 3; i++) out[i] = in[i];
    return;
  }
  const float dt = (float)(t - f->t);
  f->t = t;
  const float ad = smoothing_alpha(f->d_cutoff, dt);
  float speed2 = 0;
  for (int i = 0; i < 3; i++) {
    const float d = (in[i] - f->x[i]) / dt;
    f->dx[i] += ad * (d - f->dx[i]);
    speed2 += f->dx[i] * f->dx[i];
  }
  const float a = smoothing_alpha(f->min_cutoff + f->beta * std::sqrt(speed2), dt);
  for (int i = 0; i < 3; i++) {
    f->x[i] += a * (in[i] - f->x[i]);
    out[i] = f->x[i];
  }
}

namespace {
struct V3 {
  float x, y, z;
};
V3 operator-(V3 a, V3 b) { return {a.x - b.x, a.y - b.y, a.z - b.z}; }
V3 operator*(V3 a, float s) { return {a.x * s, a.y * s, a.z * s}; }
float dot(V3 a, V3 b) { return a.x * b.x + a.y * b.y + a.z * b.z; }
V3 cross(V3 a, V3 b) { return {a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x}; }
float len(V3 a) { return std::sqrt(dot(a, a)); }
V3 norm(V3 a) {
  const float l = len(a);
  return l > 0 ? a * (1 / l) : a;
}
V3 horizontal(V3 v, V3 up) { return v - up * dot(v, up); }
}  // namespace

void ss_air_placement(const float gravity[3], float distance, float scale, float m[16]) {
  V3 g{gravity[0], gravity[1], gravity[2]};
  const V3 up = len(g) > 1e-3f ? norm(g * -1) : V3{0, 1, 0};
  V3 front = horizontal({0, 0, 1}, up);           // standing: out of the screen
  if (len(front) < 0.5f) front = horizontal({0, -1, 0}, up);  // flat: toward the bottom edge
  if (len(front) < 1e-3f) front = {0, 0, 1};
  const V3 z = norm(front), y = up, x = norm(cross(y, z));
  const V3 cols[3] = {x * scale, y * scale, norm(cross(x, y)) * scale};
  for (int c = 0; c < 3; c++) {
    m[4 * c] = cols[c].x;
    m[4 * c + 1] = cols[c].y;
    m[4 * c + 2] = cols[c].z;
    m[4 * c + 3] = 0;
  }
  m[12] = 0;
  m[13] = 0;
  m[14] = distance;
  m[15] = 1;
}
