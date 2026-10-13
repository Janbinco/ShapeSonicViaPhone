// Core tests: OBJ parsing, SDF accuracy and sign, feature detection, probing,
// and the mixer. Run: cmake -S core -B build && cmake --build build && ctest --test-dir build -V

#include <chrono>
#include <cmath>
#include <cstdio>
#include <fstream>
#include <random>
#include <sstream>
#include <string>
#include <vector>

#include "../src/internal.hpp"
#include "shapesonic.h"

static int failures = 0;
#define CHECK(cond, ...)                                     \
  do {                                                       \
    if (!(cond)) {                                           \
      failures++;                                            \
      std::printf("FAIL %s:%d: %s: ", __FILE__, __LINE__, #cond); \
      std::printf(__VA_ARGS__);                              \
      std::printf("\n");                                     \
    }                                                        \
  } while (0)

static ss_shape *build_obj(const std::string &text, const ss_build_options *o = nullptr) {
  char err[256] = "";
  ss_shape *s = ss_shape_from_obj(text.data(), text.size(), err, sizeof err);
  if (!s) {
    std::printf("parse error: %s\n", err);
    return nullptr;
  }
  if (ss_shape_build(s, o, err, sizeof err)) {
    std::printf("build error: %s\n", err);
    ss_shape_destroy(s);
    return nullptr;
  }
  return s;
}

static std::string read_file(const std::string &path) {
  std::ifstream f(path, std::ios::binary);
  std::stringstream ss;
  ss << f.rdbuf();
  return ss.str();
}

static void test_obj_parsing() {
  // A unit cube written with quads, slashes and negative indices.
  const char *obj =
      "# cube\nv 0 0 0\nv 1 0 0\nv 1 1 0\nv 0 1 0\nv 0 0 1\nv 1 0 1\nv 1 1 1\nv 0 1 1\n"
      "vt 0 0\nvn 0 0 1\n"
      "f 1/1/1 4/1/1 3/1/1 2/1/1\nf 5//1 6//1 7//1 8//1\nf -8 -7 -3 -4\r\n"
      "f 2 3 7 6\nf 3 4 8 7\nf 4 1 5 8\n";
  ss_build_options o;
  ss_build_options_default(&o);
  o.fit_size = 0;  // keep units
  ss_shape *s = build_obj(obj, &o);
  CHECK(s, "cube parse/build");
  if (!s) return;
  ss_shape_info info;
  ss_shape_get_info(s, &info);
  CHECK(info.triangle_count == 12, "%zu triangles", info.triangle_count);
  CHECK(info.watertight, "watertight");
  // The build centres the bounding box on the origin.
  CHECK(std::fabs(ss_shape_sdf_exact(s, 0, 0, 0) + 0.5f) < 1e-5f, "centre depth");
  CHECK(std::fabs(ss_shape_sdf_exact(s, 1.5f, 0, 0) - 1) < 1e-5f, "outside distance");
  CHECK(std::fabs(ss_shape_sdf(s, 0, 0, 0) + 0.5f) < 2e-3f, "octree centre %f", ss_shape_sdf(s, 0, 0, 0));
  ss_shape_destroy(s);

  char err[128];
  CHECK(!ss_shape_from_obj("v 0 0 0\nf 1 2 3\n", 16, err, sizeof err), "bad index rejected");
}

struct Expect {
  const char *name;
  int edges, corners;  // -1: don't check
};

static void test_models() {
  const Expect models[] = {{"cube", 12, 8},  {"sphere", 0, 0}, {"torus", 0, 0}, {"cone", -1, 1}, {"table", -1, -1}, {"bed", -1, -1},
                           {"bottle", -1, -1}, {"bowl", -1, -1}, {"sofa", -1, -1}, {"mug", -1, -1}, {"cat", -1, -1}};
  std::printf("%-7s %6s %6s %5s %8s %8s %7s %6s %6s %8s %8s %8s %8s %8s\n", "model", "tris", "edges", "crnrs", "leaves",
              "MB", "build s", "minSDF", "wtight", "outErr", "inErr/D", "nearErr", "surfErr", "signBad");
  for (const Expect &m : models) {
    std::string text = read_file(std::string(MODELS_DIR) + "/" + m.name + ".obj");
    CHECK(!text.empty(), "%s missing", m.name);
    ss_shape *s = build_obj(text);
    CHECK(s, "%s build", m.name);
    if (!s) continue;
    ss_shape_info info;
    ss_shape_get_info(s, &info);

    // Octree vs exact distances at random points around the shape.
    std::mt19937 rng(1);
    float outErr = 0, inErr = 0, nearErr = 0, surfErr = 0;
    int signBad = 0;
    for (int i = 0; i < 20000; i++) {
      float p[3];
      for (int k = 0; k < 3; k++) {
        std::uniform_real_distribution<float> u(info.bbox_min[k] - 0.1f, info.bbox_max[k] + 0.1f);
        p[k] = u(rng);
      }
      float exact = ss_shape_sdf_exact(s, p[0], p[1], p[2]);
      float approx = ss_shape_sdf(s, p[0], p[1], p[2]);
      float err = std::fabs(exact - approx);
      // Far from the surface, error matters relative to the sound's range D:
      // guidance outside (D = 0.5 m), contact inside (D = |min SDF|).
      if (exact >= 0.01f) outErr = std::fmax(outErr, err);
      if (exact <= -0.01f) inErr = std::fmax(inErr, err / std::fabs(info.min_sdf));
      if (std::fabs(exact) < 0.01f) nearErr = std::fmax(nearErr, err);
      if (std::fabs(exact) < 0.002f) surfErr = std::fmax(surfErr, err);
      // Independent sign check by ray parity.
      ss::Vec3 x(p[0], p[1], p[2]);
      int inside = 0;
      const ss::Vec3 dirs[3] = {ss::normalize(ss::Vec3(0.31f, 0.83f, 0.47f)), ss::normalize(ss::Vec3(-0.6f, 0.2f, 0.77f)),
                                ss::normalize(ss::Vec3(0.1f, -0.7f, -0.7f))};
      for (auto d : dirs) inside += s->bvh.count_hits(x, d) & 1;
      if (std::fabs(exact) > 1e-4f && ((inside >= 2) != (exact < 0))) signBad++;
    }
    std::printf("%-7s %6zu %6zu %5zu %8zu %8.2f %7.2f %6.3f %6d %8.5f %8.3f %8.5f %8.5f %8d\n", m.name, info.triangle_count,
                info.sharp_edge_count, info.corner_count, info.octree_leaves, info.sdf_bytes / 1e6,
                info.build_seconds, info.min_sdf, info.watertight, outErr, inErr, nearErr, surfErr, signBad);
    CHECK(info.watertight, "%s watertight", m.name);
    CHECK(surfErr < 0.001f, "%s SDF error within 2 mm of the surface %f", m.name, surfErr);
    CHECK(nearErr < 0.003f, "%s SDF error within 1 cm of the surface %f", m.name, nearErr);
    CHECK(outErr < 0.01f, "%s SDF error outside %f", m.name, outErr);
    CHECK(inErr < 0.08f, "%s SDF error inside, relative to |min SDF| %f", m.name, inErr);
    CHECK(signBad < 5, "%s sign mismatches %d", m.name, signBad);
    if (m.edges >= 0) CHECK((int)info.sharp_edge_count == m.edges, "%s edges %zu", m.name, info.sharp_edge_count);
    if (m.corners >= 0) CHECK((int)info.corner_count == m.corners, "%s corners %zu", m.name, info.corner_count);

    // Probe timing: 10 fingers.
    ss_finger fingers[10];
    for (int f = 0; f < 10; f++) fingers[f] = {0.01f * f, 0.02f, 0.03f, f / 5, f % 5};
    ss_hand_levels levels[2];
    auto t0 = std::chrono::steady_clock::now();
    for (int i = 0; i < 10000; i++) ss_probe(s, nullptr, fingers, 10, levels, nullptr);
    double us = std::chrono::duration<double, std::micro>(std::chrono::steady_clock::now() - t0).count() / 10000;
    CHECK(us < 50, "%s probe %.1f us", m.name, us);
    ss_shape_destroy(s);
  }
}

static void test_probe() {
  std::string text = read_file(std::string(MODELS_DIR) + "/cube.obj");
  ss_shape *s = build_obj(text);  // fitted: half side 0.2
  if (!s) return;
  ss_hand_levels lv[2];
  ss_finger_probe pr[3];
  // Left: one finger at the centre (deepest: contact ~0). Right: one just inside a
  // face, one 10 cm outside.
  ss_finger f[3] = {{0, 0, 0, 0, 0}, {0.199f, 0, 0, 1, 2}, {0.3f, 0, 0, 1, 3}};
  ss_probe(s, nullptr, f, 3, lv, pr);
  CHECK(std::fabs(pr[0].sdf + 0.2f) < 0.002f, "centre sdf %f", pr[0].sdf);
  CHECK(lv[0].contact[0] < 0.05f, "centre contact quiet %f", lv[0].contact[0]);
  CHECK(lv[0].guidance == 0, "no guidance when all inside");
  CHECK(lv[1].contact[2] > 0.7f, "near-surface contact loud %f", lv[1].contact[2]);
  CHECK(std::fabs(lv[1].guidance - std::exp(-5 * 0.1f / 0.5f)) < 0.01f, "guidance %f", lv[1].guidance);
  CHECK(lv[1].edge == 0 && lv[1].corner == 0, "no features mid-face");
  // Near a corner: edge and corner both sound.
  ss_finger c[1] = {{0.205f, 0.205f, 0.205f, 1, 0}};
  ss_probe(s, nullptr, c, 1, lv, pr);
  CHECK(lv[1].corner > 0.6f && lv[1].edge > 0.6f, "corner %f edge %f", lv[1].corner, lv[1].edge);
  // Near an edge only.
  ss_finger e[1] = {{0.205f, 0.205f, 0, 1, 0}};
  ss_probe(s, nullptr, e, 1, lv, pr);
  CHECK(lv[1].edge > 0.6f && lv[1].corner == 0, "edge %f corner %f", lv[1].edge, lv[1].corner);
  // Re-detect with a threshold above 90 degrees: no features on a cube.
  ss_shape_detect_features(s, 100);
  ss_shape_info info;
  ss_shape_get_info(s, &info);
  CHECK(info.sharp_edge_count == 0, "threshold respected");
  ss_shape_destroy(s);
}

static void test_mixer() {
  const double sr = 48000;
  ss_mixer *m = ss_mixer_create(sr);
  std::vector<float> sine(48000), pluck(24000);
  for (size_t i = 0; i < sine.size(); i++) sine[i] = 0.5f * std::sin(2 * M_PI * 440 * i / sr);
  // A pluck with 100 samples of leading silence, which must be trimmed.
  for (size_t i = 100; i < pluck.size(); i++) pluck[i] = 0.5f * std::exp(-(double)i / 4000) * std::sin(0.1 * i);
  const float *ch[1] = {sine.data()};
  const float *pc[1] = {pluck.data()};
  for (int snd = 0; snd < SS_SOUND_COUNT; snd++)
    CHECK(ss_mixer_load(m, (ss_sound)snd, snd >= SS_SOUND_EDGE_LEFT ? pc : ch, 1,
                        snd >= SS_SOUND_EDGE_LEFT ? pluck.size() : sine.size(), sr) == 0, "load %d", snd);
  std::vector<float> l(128), r(128);
  auto rms = [&](const std::vector<float> &x) {
    double s = 0;
    for (float v : x) s += v * v;
    return std::sqrt(s / x.size());
  };
  ss_mixer_render(m, l.data(), r.data(), l.size());
  CHECK(rms(l) == 0 && rms(r) == 0, "silent at rest");

  // Left guidance only: left ear sounds, right ear stays silent.
  ss_hand_levels lv[2] = {};
  lv[0].guidance = 1;
  ss_mixer_set_levels(m, lv);
  for (int b = 0; b < 20; b++) ss_mixer_render(m, l.data(), r.data(), l.size());
  CHECK(rms(l) > 0.1 && rms(r) == 0, "guidance left %f right %f", rms(l), rms(r));

  // Right contact: settles within a few ms.
  lv[0].guidance = 0;
  lv[1].contact[3] = 0.8f;
  ss_mixer_set_levels(m, lv);
  for (int b = 0; b < 4; b++) ss_mixer_render(m, l.data(), r.data(), l.size());
  CHECK(rms(r) > 0.08, "contact right %f", rms(r));

  // Corner pluck starts immediately on entering the range, without leading silence.
  lv[1] = {};
  lv[0].corner = 1;
  for (int b = 0; b < 40; b++) ss_mixer_render(m, l.data(), r.data(), l.size());  // let others decay
  ss_mixer_set_levels(m, lv);
  ss_mixer_render(m, l.data(), r.data(), l.size());
  CHECK(std::fabs(l[1]) > 0 || std::fabs(l[2]) > 0, "pluck at once");

  // Render cost.
  lv[0] = lv[1] = {};
  for (int h = 0; h < 2; h++) {
    lv[h].guidance = 0.5f;
    for (int f = 0; f < 5; f++) lv[h].contact[f] = 0.5f;
    lv[h].edge = lv[h].corner = 0.7f;
  }
  ss_mixer_set_levels(m, lv);
  auto t0 = std::chrono::steady_clock::now();
  for (int b = 0; b < 3750; b++) ss_mixer_render(m, l.data(), r.data(), l.size());  // 10 s of audio
  double ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();
  std::printf("mixer: 10 s of audio with every voice on rendered in %.1f ms\n", ms);
  CHECK(ms < 500, "render too slow");
  ss_mixer_destroy(m);
}

int main() {
  test_obj_parsing();
  test_probe();
  test_mixer();
  test_models();
  if (failures) std::printf("%d failure(s)\n", failures);
  else std::printf("all tests passed\n");
  return failures ? 1 : 0;
}
