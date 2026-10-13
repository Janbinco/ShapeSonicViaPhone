// Internal types shared by the core's translation units.
#pragma once

#include <cmath>
#include <cstdint>
#include <functional>
#include <string>
#include <thread>
#include <unordered_map>
#include <vector>

#include "shapesonic.h"

namespace ss {

struct Vec3 {
  float x = 0, y = 0, z = 0;
  Vec3() = default;
  Vec3(float x_, float y_, float z_) : x(x_), y(y_), z(z_) {}
  float operator[](int i) const { return i == 0 ? x : i == 1 ? y : z; }
  float &operator[](int i) { return i == 0 ? x : i == 1 ? y : z; }
};
inline Vec3 operator+(Vec3 a, Vec3 b) { return {a.x + b.x, a.y + b.y, a.z + b.z}; }
inline Vec3 operator-(Vec3 a, Vec3 b) { return {a.x - b.x, a.y - b.y, a.z - b.z}; }
inline Vec3 operator*(Vec3 a, float s) { return {a.x * s, a.y * s, a.z * s}; }
inline Vec3 operator*(float s, Vec3 a) { return a * s; }
inline Vec3 &operator+=(Vec3 &a, Vec3 b) { return a = a + b; }
inline float dot(Vec3 a, Vec3 b) { return a.x * b.x + a.y * b.y + a.z * b.z; }
inline Vec3 cross(Vec3 a, Vec3 b) { return {a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x}; }
inline float length(Vec3 a) { return std::sqrt(dot(a, a)); }
inline Vec3 normalize(Vec3 a) {
  float l = length(a);
  return l > 0 ? a * (1 / l) : Vec3();
}
inline Vec3 vmin(Vec3 a, Vec3 b) { return {std::fmin(a.x, b.x), std::fmin(a.y, b.y), std::fmin(a.z, b.z)}; }
inline Vec3 vmax(Vec3 a, Vec3 b) { return {std::fmax(a.x, b.x), std::fmax(a.y, b.y), std::fmax(a.z, b.z)}; }

struct Tri {
  uint32_t v[3];
};

// Distance from p to an axis-aligned box, squared (0 inside).
inline float box_dist2(Vec3 p, Vec3 lo, Vec3 hi) {
  float d2 = 0;
  for (int i = 0; i < 3; i++) {
    float d = std::fmax(std::fmax(lo[i] - p[i], 0.f), p[i] - hi[i]);
    d2 += d * d;
  }
  return d2;
}

// Closest point on triangle (a, b, c) to p (Ericson, Real-Time Collision
// Detection, 5.1.5). region: 0 face; 1, 2, 3 edges ab, bc, ca; 4, 5, 6 vertices a, b, c.
Vec3 closest_on_triangle(Vec3 p, Vec3 a, Vec3 b, Vec3 c, int &region);

// Binary bounding-volume hierarchy over triangles.
class BVH {
 public:
  void build(const std::vector<Vec3> &verts, const std::vector<Tri> &tris);
  // Nearest triangle to p: returns squared distance, writes triangle, closest point and region.
  float closest(Vec3 p, uint32_t &tri, Vec3 &point, int &region) const;
  // Number of triangles hit by the ray p + t d, t > 0.
  int count_hits(Vec3 p, Vec3 d) const;

 private:
  struct Node {
    Vec3 lo, hi;
    uint32_t first;  // leaf: first index into order; internal: right child (left = this + 1)
    uint32_t count;  // > 0 for leaves
  };
  uint32_t build_node(uint32_t begin, uint32_t end, std::vector<Vec3> &centroids);
  std::vector<Node> nodes_;
  std::vector<uint32_t> order_;
  const std::vector<Vec3> *verts_ = nullptr;
  const std::vector<Tri> *tris_ = nullptr;
};

// Adaptive octree of signed distances, trilinear within each leaf.
class OctreeSDF {
 public:
  // Root cube centred on center, covering at least half_extent in every direction.
  void build(Vec3 center, float half_extent, float leaf_size, int threads,
             const std::function<float(Vec3)> &unsigned_dist, const std::function<float(Vec3)> &signed_dist);
  float sample(Vec3 p) const;
  size_t node_count() const { return nodes_.size(); }
  size_t leaf_count() const { return values_.size() / 8; }
  size_t bytes() const { return nodes_.size() * sizeof(uint32_t) + values_.size() * sizeof(int16_t); }
  float min_value() const { return min_value_; }

  static constexpr uint32_t kLeaf = 0x80000000u;
  // Build parameters, exposed for tests.
  std::vector<uint32_t> nodes_;  // internal: index of first of 8 children; leaf: kLeaf | leaf index
  std::vector<int16_t> values_;  // 8 quantized corner distances per leaf
  Vec3 origin_;                  // root cube min corner
  float size_ = 0;               // root cube side
  float quantum_ = 0;            // metres per quantization step
  float min_value_ = 0;
  Vec3 mesh_lo_, mesh_hi_;       // for queries outside the root cube
};

// Uniform hash grid of segments or points for range-limited nearest queries.
class FeatureGrid {
 public:
  void build_segments(const std::vector<Vec3> &endpoints, float cell);  // pairs of points
  void build_points(const std::vector<Vec3> &points, float cell);
  float nearest(Vec3 p, float max_distance) const;  // INFINITY if none within max_distance

 private:
  int64_t key(int i, int j, int k) const;
  std::unordered_map<int64_t, std::vector<uint32_t>> cells_;
  std::vector<Vec3> pts_;
  bool segments_ = false;
  float cell_ = 1;
};

void parallel_for(size_t n, int threads, const std::function<void(size_t begin, size_t end)> &body);

}  // namespace ss

struct ss_shape {
  std::vector<ss::Vec3> verts;
  std::vector<ss::Tri> tris;
  // Derived by ss_shape_build.
  std::vector<ss::Vec3> face_normals;
  std::vector<ss::Vec3> edge_normals;    // 3 per triangle (ab, bc, ca), unnormalized pseudonormals
  std::vector<ss::Vec3> vertex_normals;  // angle-weighted pseudonormals
  bool watertight = false;
  ss::BVH bvh;
  ss::OctreeSDF sdf;
  std::vector<ss::Vec3> sharp_edges;  // pairs of endpoints
  std::vector<ss::Vec3> corners;
  ss::FeatureGrid edge_grid, corner_grid;
  ss::Vec3 lo, hi;
  double build_seconds = 0;
  bool built = false;

  float signed_distance(ss::Vec3 p) const;
};
