#pragma once
#include <array>
#include <cstdint>
#include <memory>
#include <string>
#include <vector>

namespace cadcore {

// How much the source file actually gives us. Drives which tools the UI enables.
enum class Fidelity {
  Unknown,
  Mesh,   // triangles only: no topological faces, measurements are approximate
  BRep    // full topology + analytic surfaces: exact measurement
};

// What the loaded document can support. The UI reads these to enable/disable
// tools instead of guessing from the file extension.
struct Capabilities {
  bool exactGeometry = false;  // analytic surfaces -> exact radius/distance
  bool faceSelection = false;  // real topological faces to pick
  bool assemblyTree  = false;  // named part hierarchy
  bool perFaceColor  = false;  // colors carried per face/part
  bool declaredUnits = false;  // file states its unit (else we assume mm)
};

struct Bounds {
  std::array<double, 3> min{0, 0, 0};
  std::array<double, 3> max{0, 0, 0};
  bool valid = false;
  std::array<double, 3> size() const {
    return {max[0] - min[0], max[1] - min[1], max[2] - min[2]};
  }
};

// An analytic cylindrical face: this is what makes "click a hole, get its
// diameter" exact rather than a mesh estimate.
struct CylinderFace {
  double radius = 0;
  std::array<double, 3> axis{0, 0, 1};
  std::array<double, 3> location{0, 0, 0};
};

struct SurfaceMix {
  int plane = 0, cylinder = 0, cone = 0, sphere = 0, torus = 0;
  int bspline = 0, bezier = 0, revolution = 0, extrusion = 0, other = 0;
  int total() const {
    return plane + cylinder + cone + sphere + torus + bspline + bezier +
           revolution + extrusion + other;
  }
};

struct Stats {
  int solids = 0, shells = 0, faces = 0, edges = 0, vertices = 0;
  double volume = 0;   // mm^3, solids only
  double area = 0;     // mm^2
  std::array<double, 3> centerOfMass{0, 0, 0};
  SurfaceMix surfaces;
};

// Flat, GPU-ready. faceId is per-vertex so a single draw call can write an
// identity buffer for pixel-exact picking.
struct RenderVertex {
  float position[3];
  float normal[3];
  std::uint32_t faceId;
};

// Lets the UI highlight or isolate one face without re-uploading anything.
struct FaceRange {
  std::uint32_t faceId;
  std::uint32_t firstIndex;
  std::uint32_t indexCount;
};

// Which kind of topological entity an id refers to.
enum class EntityKind { Face, Edge };

// What a picked edge is. Length is exact: taken from the curve, not the
// tessellated polyline.
struct EdgeInfo {
  bool valid = false;
  std::string curveType;   // "line", "circle", "ellipse", "spline", ...
  double length = 0;
  bool hasRadius = false;
  double radius = 0;
  bool closed = false;
  std::array<double, 3> start{0, 0, 0};
  std::array<double, 3> end{0, 0, 0};
};

// What a measurement point locked onto. Ordered by how much a user would
// prefer it: an exact vertex beats a point that merely lies on a face.
enum class SnapKind {
  Surface = 0,      // projected onto the face
  EdgePoint = 1,    // projected onto the curve
  CircleCentre = 2,
  EdgeMidpoint = 3,
  Vertex = 4
};

struct SnapCandidate {
  SnapKind kind = SnapKind::Surface;
  std::array<double, 3> position{0, 0, 0};
};

const char* toString(SnapKind kind);

// Display units. Geometry is always millimetres internally; this only affects
// how a measurement is written out.
enum class Unit { Millimetres, Centimetres, Metres, Inches };
double scaleFromMillimetres(Unit unit);
const char* unitSuffix(Unit unit);
std::string formatLength(double millimetres, Unit unit);

// One end of a measurement. Either a topological entity or a bare point, so a
// single code path covers face-to-face, edge-to-edge, point-to-point and every
// mix of them.
struct MeasureRef {
  bool isPoint = false;
  EntityKind kind = EntityKind::Face;  // when !isPoint
  std::uint32_t id = 0;                // when !isPoint
  std::array<double, 3> point{0, 0, 0};  // when isPoint

  static MeasureRef entity(EntityKind kind, std::uint32_t id) {
    MeasureRef r; r.isPoint = false; r.kind = kind; r.id = id; return r;
  }
  static MeasureRef atPoint(const std::array<double, 3>& p) {
    MeasureRef r; r.isPoint = true; r.point = p; return r;
  }
};

// The closest points are reported so the UI can draw the measurement where it
// is actually taken, rather than between two arbitrary picks.
struct MeasureResult {
  bool valid = false;
  double distance = 0;
  std::array<double, 3> pointA{0, 0, 0};
  std::array<double, 3> pointB{0, 0, 0};
};

struct RenderMesh {
  std::vector<RenderVertex> vertices;
  std::vector<std::uint32_t> indices;
  std::vector<FaceRange> faces;
  std::vector<float> edgePositions;        // xyz triples
  std::vector<std::uint32_t> edgeIndices;  // line-list pairs
  std::vector<std::uint32_t> edgeIds;      // one per segment, for picking
  std::uint32_t edgeCount = 0;
  bool empty() const { return indices.empty(); }
};

// What a picked face actually is, straight from the analytic surface.
struct FaceInfo {
  bool valid = false;
  std::string surfaceType;   // "plane", "cylinder", ...
  double area = 0;
  bool hasRadius = false;
  double radius = 0;
  std::array<double, 3> axis{0, 0, 1};
  std::array<double, 3> location{0, 0, 0};
  std::array<double, 3> normal{0, 0, 1};  // planes only
};

struct FormatInfo {
  std::string id;         // "STEP", "IGES", "GLTF", ...
  std::string extension;  // as seen on disk, lowercased
  Fidelity fidelity = Fidelity::Unknown;
};

class Document {
 public:
  ~Document();
  Document(const Document&) = delete;
  Document& operator=(const Document&) = delete;

  // Returns nullptr on failure and fills `error`.
  static std::unique_ptr<Document> load(const std::string& path,
                                        std::string& error);

  // Extensions we can open right now, for NSDocument / QuickLook registration.
  static std::vector<FormatInfo> supportedFormats();

  const FormatInfo& format() const { return m_format; }
  const Capabilities& caps() const { return m_caps; }
  Fidelity fidelity() const { return m_format.fidelity; }

  int partCount() const { return m_partCount; }        // unique parts
  int instanceCount() const { return m_instanceCount; }  // placements in the tree
  double lengthUnitMM() const { return m_unitMM; }
  const Bounds& bounds() const { return m_bounds; }
  const Stats& stats() const { return m_stats; }

  // Distinct cylindrical faces, largest radius first. Deduplicated by
  // (radius, axis, location) so a hole split across seams counts once.
  std::vector<CylinderFace> cylinders(std::size_t limit = 0) const;

  // Triangulate. deflection <= 0 picks a value from the bounding box so the
  // tessellation is scale-appropriate instead of absolute.
  bool tessellate(double deflection = -1, double angularDeg = -1);
  std::size_t triangleCount() const;

  // Chordal deviation used by the last tessellation, in mm.
  double deflection() const { return m_deflection; }

  // Builds (once) and returns the GPU buffers. Tessellates if needed.
  const RenderMesh& renderMesh(double deflection = -1);

  // Throws the cached mesh away so the next renderMesh() re-tessellates. The
  // multiplier scales the automatic chordal deviation: below 1 is finer and
  // slower, above 1 is coarser and faster.
  void retessellate(double deflectionMultiplier);

  // Exact query for a face picked out of the identity buffer.
  FaceInfo faceInfo(std::uint32_t faceId) const;
  EdgeInfo edgeInfo(std::uint32_t edgeId) const;

  // Exact minimum distance between any two picked entities.
  bool distanceBetween(EntityKind kindA, std::uint32_t idA,
                       EntityKind kindB, std::uint32_t idB,
                       double& outDistance) const;

  MeasureResult measure(const MeasureRef& a, const MeasureRef& b) const;

  // Totals for a multi-selection of edges. `connected` means the edges form a
  // single chain, in which case `endToEnd` is the straight-line span between
  // its two free ends.
  struct EdgeGroup {
    bool valid = false;
    std::size_t count = 0;
    double totalLength = 0;
    bool connected = false;
    bool closed = false;
    double endToEnd = 0;
  };
  EdgeGroup measureEdges(const std::vector<std::uint32_t>& edgeIds) const;

  // Total area of a multi-selection of faces.
  double totalArea(const std::vector<std::uint32_t>& faceIds) const;

  // Pulls a point sampled from the depth buffer onto the exact surface, so a
  // point measurement is not limited by tessellation.
  // Snap targets near an entity: its vertices, edge midpoints and circle
  // centres. Screen-space proximity is decided by the caller.
  std::vector<SnapCandidate> snapCandidates(EntityKind kind,
                                            std::uint32_t id) const;

  bool projectPointOntoEdge(std::uint32_t edgeId,
                            const std::array<double, 3>& approximate,
                            std::array<double, 3>& outExact) const;

  bool snapPointToFace(std::uint32_t faceId,
                       const std::array<double, 3>& approximate,
                       std::array<double, 3>& outExact) const;

  struct Impl;

 private:
  Document();
  void analyze();

  std::unique_ptr<Impl> m_impl;
  FormatInfo m_format;
  Capabilities m_caps;
  Bounds m_bounds;
  Stats m_stats;
  int m_partCount = 0;
  int m_instanceCount = 0;
  double m_unitMM = 1.0;
  double m_deflection = 0;
};

const char* toString(Fidelity f);

}  // namespace cadcore
