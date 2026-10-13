// Adaptive octree signed distance field.
//
// Refinement, level by level:
// * A cell the surface may pass through (its centre is within kNear sides of
//   the surface; the half-diagonal is 0.87 sides) is always split, down to the
//   leaf size, so the zero level set is resolved at the finest level.
// * Any other cell is split if it is large compared to its distance from the
//   surface (side > distance / kFar), or if trilinear interpolation of its
//   corners misses the exact distance at its centre by more than
//   kTolAbs + kTolRel * |distance| (error-driven, as in adaptive distance
//   fields). This concentrates cells near the medial axis and other kinks of
//   the distance field, where interpolation is worst.
// Each leaf stores its 8 corner values, quantized to int16. Corners shared by
// several leaves are evaluated once.

#include <algorithm>
#include <limits>

#include "internal.hpp"

namespace ss {

static constexpr float kNear = 0.9f, kFar = 1.0f;
static constexpr float kTolAbs = 0.0005f, kTolRel = 0.01f;
static constexpr int kMaxDepth = 12;

void OctreeSDF::build(Vec3 center, float half_extent, float leaf_size, int threads,
                      const std::function<float(Vec3)> &unsigned_dist,
                      const std::function<float(Vec3)> &signed_dist) {
  // Root side = leaf_size * 2^depth >= 2 * half_extent, so leaves are exactly leaf_size.
  int depth = 0;
  while (depth < kMaxDepth && leaf_size * float(1 << depth) < 2 * half_extent) depth++;
  size_ = leaf_size * float(1 << depth);
  origin_ = center - Vec3(size_, size_, size_) * 0.5f;
  const uint32_t lattice = 1u << depth;  // root side in leaf units

  struct Cell {
    uint32_t node;
    uint32_t i, j, k;  // min corner in leaf units
    uint32_t side;     // in leaf units
  };
  nodes_.assign(1, 0);
  std::vector<Cell> level{{0, 0, 0, 0, lattice}}, next, leaves;
  std::vector<char> split;
  while (!level.empty()) {
    split.assign(level.size(), 0);
    parallel_for(level.size(), threads, [&](size_t b, size_t e) {
      for (size_t c = b; c < e; c++) {
        const Cell &cell = level[c];
        if (cell.side <= 1) continue;
        const float side = cell.side * leaf_size, h = 0.5f * cell.side;
        const Vec3 lo = origin_ + Vec3(float(cell.i), float(cell.j), float(cell.k)) * leaf_size;
        const float d = unsigned_dist(lo + Vec3(h, h, h) * leaf_size);
        if (d < kNear * side || d < kFar * side) {
          split[c] = 1;
          continue;
        }
        // Compare trilinear interpolation with exact values at the centre (the
        // mean of the 8 corners) and the 6 face centres (the mean of 4 corners).
        float corner[8];
        for (int o = 0; o < 8; o++) corner[o] = signed_dist(lo + Vec3(float(o & 1), float((o >> 1) & 1), float(o >> 2)) * side);
        auto off = [&](Vec3 t, float interpolated) {
          float exact = signed_dist(lo + t * side);
          return std::fabs(interpolated - exact) > kTolAbs + kTolRel * std::fabs(exact);
        };
        float mean = 0;
        for (float v : corner) mean += v / 8;
        bool bad = off(Vec3(0.5f, 0.5f, 0.5f), mean);
        for (int axis = 0; axis < 3 && !bad; axis++)
          for (int side01 = 0; side01 < 2 && !bad; side01++) {
            float face = 0;
            for (int o = 0; o < 8; o++)
              if (((o >> axis) & 1) == side01) face += corner[o] / 4;
            Vec3 t(0.5f, 0.5f, 0.5f);
            t[axis] = float(side01);
            bad = off(t, face);
          }
        split[c] = bad;
      }
    });
    next.clear();
    for (size_t c = 0; c < level.size(); c++) {
      const Cell &cell = level[c];
      if (split[c]) {
        uint32_t first = (uint32_t)nodes_.size();
        nodes_[cell.node] = first;
        nodes_.resize(first + 8, 0);
        uint32_t s = cell.side / 2;
        for (uint32_t o = 0; o < 8; o++)
          next.push_back({first + o, cell.i + (o & 1) * s, cell.j + ((o >> 1) & 1) * s, cell.k + ((o >> 2) & 1) * s, s});
      } else {
        nodes_[cell.node] = kLeaf | (uint32_t)leaves.size();
        leaves.push_back(cell);
      }
    }
    std::swap(level, next);
  }

  // Unique leaf corners, keyed by lattice coordinates (each < 2^13).
  auto corner_key = [](uint32_t i, uint32_t j, uint32_t k) { return (uint64_t(i) << 26) | (uint64_t(j) << 13) | k; };
  std::vector<uint64_t> keys;
  keys.reserve(leaves.size() * 8);
  for (const Cell &c : leaves)
    for (uint32_t o = 0; o < 8; o++)
      keys.push_back(corner_key(c.i + (o & 1) * c.side, c.j + ((o >> 1) & 1) * c.side, c.k + ((o >> 2) & 1) * c.side));
  std::sort(keys.begin(), keys.end());
  keys.erase(std::unique(keys.begin(), keys.end()), keys.end());
  std::vector<float> values(keys.size());
  parallel_for(keys.size(), threads, [&](size_t b, size_t e) {
    for (size_t n = b; n < e; n++) {
      uint64_t key = keys[n];
      Vec3 p = origin_ + Vec3(float(key >> 26), float((key >> 13) & 0x1fff), float(key & 0x1fff)) * leaf_size;
      values[n] = signed_dist(p);
    }
  });

  float max_abs = 0;
  min_value_ = 0;
  for (float v : values) {
    max_abs = std::fmax(max_abs, std::fabs(v));
    min_value_ = std::fmin(min_value_, v);
  }
  quantum_ = std::fmax(max_abs, 1e-6f) / 32767.f;
  values_.resize(leaves.size() * 8);
  parallel_for(leaves.size(), threads, [&](size_t b, size_t e) {
    for (size_t l = b; l < e; l++) {
      const Cell &c = leaves[l];
      for (uint32_t o = 0; o < 8; o++) {
        uint64_t key = corner_key(c.i + (o & 1) * c.side, c.j + ((o >> 1) & 1) * c.side, c.k + ((o >> 2) & 1) * c.side);
        size_t n = std::lower_bound(keys.begin(), keys.end(), key) - keys.begin();
        values_[8 * l + o] = (int16_t)std::lround(values[n] / quantum_);
      }
    }
  });
}

float OctreeSDF::sample(Vec3 p) const {
  if (nodes_.empty()) return std::numeric_limits<float>::infinity();
  Vec3 t = (p - origin_) * (1 / size_);
  if (t.x < 0 || t.y < 0 || t.z < 0 || t.x >= 1 || t.y >= 1 || t.z >= 1) {
    // Outside the domain, which extends past the guidance range: a lower bound is enough.
    return std::sqrt(box_dist2(p, mesh_lo_, mesh_hi_));
  }
  uint32_t n = nodes_[0];
  while (!(n & kLeaf)) {
    t = t * 2.f;
    uint32_t o = 0;
    if (t.x >= 1) o |= 1, t.x -= 1;
    if (t.y >= 1) o |= 2, t.y -= 1;
    if (t.z >= 1) o |= 4, t.z -= 1;
    n = nodes_[n + o];
  }
  const int16_t *v = &values_[8 * (n & ~kLeaf)];
  float x0 = v[0] + (v[1] - v[0]) * t.x, x1 = v[2] + (v[3] - v[2]) * t.x;
  float x2 = v[4] + (v[5] - v[4]) * t.x, x3 = v[6] + (v[7] - v[6]) * t.x;
  float y0 = x0 + (x1 - x0) * t.y, y1 = x2 + (x3 - x2) * t.y;
  return (y0 + (y1 - y0) * t.z) * quantum_;
}

}  // namespace ss
