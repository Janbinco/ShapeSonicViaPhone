// Geometric building blocks: closest point on a triangle, a triangle BVH, a
// hash grid for feature distances, and a small parallel_for.

#include <algorithm>
#include <atomic>
#include <limits>

#include "internal.hpp"

namespace ss {

Vec3 closest_on_triangle(Vec3 p, Vec3 a, Vec3 b, Vec3 c, int &region) {
  Vec3 ab = b - a, ac = c - a, ap = p - a;
  float d1 = dot(ab, ap), d2 = dot(ac, ap);
  if (d1 <= 0 && d2 <= 0) {
    region = 4;
    return a;
  }
  Vec3 bp = p - b;
  float d3 = dot(ab, bp), d4 = dot(ac, bp);
  if (d3 >= 0 && d4 <= d3) {
    region = 5;
    return b;
  }
  float vc = d1 * d4 - d3 * d2;
  if (vc <= 0 && d1 >= 0 && d3 <= 0) {
    region = 1;
    return a + ab * (d1 / (d1 - d3));
  }
  Vec3 cp = p - c;
  float d5 = dot(ab, cp), d6 = dot(ac, cp);
  if (d6 >= 0 && d5 <= d6) {
    region = 6;
    return c;
  }
  float vb = d5 * d2 - d1 * d6;
  if (vb <= 0 && d2 >= 0 && d6 <= 0) {
    region = 3;
    return a + ac * (d2 / (d2 - d6));
  }
  float va = d3 * d6 - d5 * d4;
  if (va <= 0 && (d4 - d3) >= 0 && (d5 - d6) >= 0) {
    region = 2;
    return b + (c - b) * ((d4 - d3) / ((d4 - d3) + (d5 - d6)));
  }
  float denom = va + vb + vc;
  if (!(denom > 0)) {  // degenerate triangle: fall back to its vertices
    region = 4;
    return a;
  }
  float v = vb / denom, w = vc / denom;
  region = 0;
  return a + ab * v + ac * w;
}

// ---- BVH --------------------------------------------------------------------

static constexpr uint32_t kLeafTris = 4;

void BVH::build(const std::vector<Vec3> &verts, const std::vector<Tri> &tris) {
  verts_ = &verts;
  tris_ = &tris;
  nodes_.clear();
  order_.resize(tris.size());
  std::vector<Vec3> centroids(tris.size());
  for (uint32_t i = 0; i < tris.size(); i++) {
    order_[i] = i;
    const Tri &t = tris[i];
    centroids[i] = (verts[t.v[0]] + verts[t.v[1]] + verts[t.v[2]]) * (1.f / 3);
  }
  nodes_.reserve(2 * tris.size() / kLeafTris + 1);
  if (!tris.empty()) build_node(0, (uint32_t)tris.size(), centroids);
}

uint32_t BVH::build_node(uint32_t begin, uint32_t end, std::vector<Vec3> &centroids) {
  uint32_t index = (uint32_t)nodes_.size();
  nodes_.push_back({});
  const float inf = std::numeric_limits<float>::infinity();
  Vec3 lo(inf, inf, inf), hi(-inf, -inf, -inf), clo = lo, chi = hi;
  for (uint32_t i = begin; i < end; i++) {
    const Tri &t = (*tris_)[order_[i]];
    for (int k = 0; k < 3; k++) {
      lo = vmin(lo, (*verts_)[t.v[k]]);
      hi = vmax(hi, (*verts_)[t.v[k]]);
    }
    clo = vmin(clo, centroids[order_[i]]);
    chi = vmax(chi, centroids[order_[i]]);
  }
  nodes_[index].lo = lo;
  nodes_[index].hi = hi;
  if (end - begin <= kLeafTris) {
    nodes_[index].first = begin;
    nodes_[index].count = end - begin;
    return index;
  }
  Vec3 ext = chi - clo;
  int axis = ext.x > ext.y ? (ext.x > ext.z ? 0 : 2) : (ext.y > ext.z ? 1 : 2);
  uint32_t mid = (begin + end) / 2;
  std::nth_element(order_.begin() + begin, order_.begin() + mid, order_.begin() + end,
                   [&](uint32_t a, uint32_t b) { return centroids[a][axis] < centroids[b][axis]; });
  build_node(begin, mid, centroids);
  uint32_t right = build_node(mid, end, centroids);
  nodes_[index].first = right;
  nodes_[index].count = 0;
  return index;
}

float BVH::closest(Vec3 p, uint32_t &tri, Vec3 &point, int &region) const {
  float best = std::numeric_limits<float>::infinity();
  if (nodes_.empty()) return best;
  uint32_t stack[64];
  int top = 0;
  stack[top++] = 0;
  while (top > 0) {
    const Node &n = nodes_[stack[--top]];
    if (box_dist2(p, n.lo, n.hi) >= best) continue;
    if (n.count) {
      for (uint32_t i = n.first; i < n.first + n.count; i++) {
        const Tri &t = (*tris_)[order_[i]];
        int r;
        Vec3 q = closest_on_triangle(p, (*verts_)[t.v[0]], (*verts_)[t.v[1]], (*verts_)[t.v[2]], r);
        Vec3 d = p - q;
        float d2 = dot(d, d);
        if (d2 < best) {
          best = d2;
          tri = order_[i];
          point = q;
          region = r;
        }
      }
      continue;
    }
    uint32_t left = (uint32_t)(&n - nodes_.data()) + 1, right = n.first;
    float dl = box_dist2(p, nodes_[left].lo, nodes_[left].hi);
    float dr = box_dist2(p, nodes_[right].lo, nodes_[right].hi);
    // Push the farther child first so the nearer one is visited first.
    if (dl < dr) std::swap(left, right), std::swap(dl, dr);
    if (dl < best && top < 64) stack[top++] = left;
    if (dr < best && top < 64) stack[top++] = right;
  }
  return best;
}

static bool ray_box(Vec3 p, Vec3 inv, Vec3 lo, Vec3 hi) {
  float t0 = 0, t1 = std::numeric_limits<float>::infinity();
  for (int i = 0; i < 3; i++) {
    float a = (lo[i] - p[i]) * inv[i], b = (hi[i] - p[i]) * inv[i];
    if (a > b) std::swap(a, b);
    t0 = std::fmax(t0, a);
    t1 = std::fmin(t1, b);
    if (t0 > t1) return false;
  }
  return true;
}

int BVH::count_hits(Vec3 p, Vec3 d) const {
  if (nodes_.empty()) return 0;
  Vec3 inv(1 / d.x, 1 / d.y, 1 / d.z);
  int hits = 0;
  uint32_t stack[64];
  int top = 0;
  stack[top++] = 0;
  while (top > 0) {
    const Node &n = nodes_[stack[--top]];
    if (!ray_box(p, inv, n.lo, n.hi)) continue;
    if (n.count) {
      for (uint32_t i = n.first; i < n.first + n.count; i++) {
        const Tri &t = (*tris_)[order_[i]];
        Vec3 a = (*verts_)[t.v[0]], e1 = (*verts_)[t.v[1]] - a, e2 = (*verts_)[t.v[2]] - a;
        Vec3 h = cross(d, e2);
        float det = dot(e1, h);
        if (std::fabs(det) < 1e-12f) continue;
        float f = 1 / det;
        Vec3 s = p - a;
        float u = f * dot(s, h);
        if (u < 0 || u > 1) continue;
        Vec3 q = cross(s, e1);
        float v = f * dot(d, q);
        if (v < 0 || u + v > 1) continue;
        if (f * dot(e2, q) > 0) hits++;
      }
      continue;
    }
    if (top < 63) {
      stack[top++] = (uint32_t)(&n - nodes_.data()) + 1;
      stack[top++] = n.first;
    }
  }
  return hits;
}

// ---- Feature grid -------------------------------------------------------------

int64_t FeatureGrid::key(int i, int j, int k) const {
  return ((int64_t)(i & 0x1fffff) << 42) | ((int64_t)(j & 0x1fffff) << 21) | (int64_t)(k & 0x1fffff);
}

void FeatureGrid::build_segments(const std::vector<Vec3> &endpoints, float cell) {
  cells_.clear();
  pts_ = endpoints;
  segments_ = true;
  cell_ = cell;
  for (uint32_t s = 0; s + 1 < pts_.size(); s += 2) {
    Vec3 lo = vmin(pts_[s], pts_[s + 1]), hi = vmax(pts_[s], pts_[s + 1]);
    for (int i = (int)std::floor(lo.x / cell); i <= (int)std::floor(hi.x / cell); i++)
      for (int j = (int)std::floor(lo.y / cell); j <= (int)std::floor(hi.y / cell); j++)
        for (int k = (int)std::floor(lo.z / cell); k <= (int)std::floor(hi.z / cell); k++)
          cells_[key(i, j, k)].push_back(s / 2);
  }
}

void FeatureGrid::build_points(const std::vector<Vec3> &points, float cell) {
  cells_.clear();
  pts_ = points;
  segments_ = false;
  cell_ = cell;
  for (uint32_t s = 0; s < pts_.size(); s++) {
    Vec3 p = pts_[s];
    cells_[key((int)std::floor(p.x / cell), (int)std::floor(p.y / cell), (int)std::floor(p.z / cell))].push_back(s);
  }
}

static float point_segment_dist2(Vec3 p, Vec3 a, Vec3 b) {
  Vec3 ab = b - a;
  float l2 = dot(ab, ab);
  float t = l2 > 0 ? std::clamp(dot(p - a, ab) / l2, 0.f, 1.f) : 0.f;
  Vec3 d = p - (a + ab * t);
  return dot(d, d);
}

float FeatureGrid::nearest(Vec3 p, float max_distance) const {
  float best = max_distance * max_distance;
  bool found = false;
  auto test = [&](uint32_t s) {
    float d2 = segments_ ? point_segment_dist2(p, pts_[2 * s], pts_[2 * s + 1]) : dot(p - pts_[s], p - pts_[s]);
    if (d2 < best) best = d2, found = true;
  };
  if (pts_.empty()) return std::numeric_limits<float>::infinity();
  int r = (int)std::ceil(max_distance / cell_);
  if (r > 3) {  // large range: brute force
    size_t n = segments_ ? pts_.size() / 2 : pts_.size();
    for (uint32_t s = 0; s < n; s++) test(s);
  } else {
    int ci = (int)std::floor(p.x / cell_), cj = (int)std::floor(p.y / cell_), ck = (int)std::floor(p.z / cell_);
    for (int i = ci - r; i <= ci + r; i++)
      for (int j = cj - r; j <= cj + r; j++)
        for (int k = ck - r; k <= ck + r; k++) {
          auto it = cells_.find(key(i, j, k));
          if (it == cells_.end()) continue;
          for (uint32_t s : it->second) test(s);
        }
  }
  return found ? std::sqrt(best) : std::numeric_limits<float>::infinity();
}

// ---- parallel_for ---------------------------------------------------------------

void parallel_for(size_t n, int threads, const std::function<void(size_t, size_t)> &body) {
  if (threads <= 0) threads = (int)std::max(1u, std::thread::hardware_concurrency());
  const size_t chunk = 256;
  if (threads == 1 || n <= chunk) {
    body(0, n);
    return;
  }
  std::atomic<size_t> next{0};
  auto worker = [&] {
    for (;;) {
      size_t b = next.fetch_add(chunk);
      if (b >= n) return;
      body(b, std::min(n, b + chunk));
    }
  };
  std::vector<std::thread> pool;
  for (int t = 1; t < threads; t++) pool.emplace_back(worker);
  worker();
  for (auto &t : pool) t.join();
}

}  // namespace ss
