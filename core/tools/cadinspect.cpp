// cadinspect - de-risking spike for the 3D viewer.
// Proves we can load a CAD file, walk its topology, and pull exact analytic
// dimensions out of it. Everything the viewer needs comes from these calls.

#include "cadcore/CadDocument.h"

#include <chrono>
#include <cstdio>
#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <vector>
#include <string>

using namespace cadcore;

static void printFormats() {
  std::printf("Supported formats:\n");
  for (const auto& f : Document::supportedFormats())
    std::printf("  .%-6s %-6s %s\n", f.extension.c_str(), f.id.c_str(),
                toString(f.fidelity));
}

int main(int argc, char** argv) {
  if (argc < 2) {
    std::printf("usage: cadinspect <file>\n\n");
    printFormats();
    return 1;
  }
  const std::string path = argv[1];
  int distA = -1, distB = -1, edgeA = -1, edgeB = -1;
  for (int i = 2; i + 2 < argc; ++i)
    if (std::string(argv[i]) == "--dist") {
      distA = std::atoi(argv[i + 1]);
      distB = std::atoi(argv[i + 2]);
    } else if (std::string(argv[i]) == "--edist") {
      edgeA = std::atoi(argv[i + 1]);
      edgeB = std::atoi(argv[i + 2]);
    }

  auto t0 = std::chrono::steady_clock::now();
  std::string error;
  auto doc = Document::load(path, error);
  auto t1 = std::chrono::steady_clock::now();

  if (!doc) {
    std::fprintf(stderr, "FAILED to load %s\n  %s\n", path.c_str(), error.c_str());
    return 2;
  }
  auto ms = [](auto a, auto b) {
    return std::chrono::duration<double, std::milli>(b - a).count();
  };

  const auto& s = doc->stats();
  const auto& c = doc->caps();
  const auto& b = doc->bounds();

  std::printf("%s\n", path.c_str());
  std::printf("  format        %s (.%s), %s\n", doc->format().id.c_str(),
              doc->format().extension.c_str(), toString(doc->fidelity()));
  std::printf("  read time     %.1f ms\n", ms(t0, t1));
  std::printf("  parts         %d unique, %d instances\n",
              doc->partCount(), doc->instanceCount());
  std::printf("  unit          %g mm%s\n", doc->lengthUnitMM(),
              c.declaredUnits ? " (declared)" : " (assumed)");

  std::printf("  capabilities  face-select:%s exact-geom:%s tree:%s color:%s\n",
              c.faceSelection ? "yes" : "no", c.exactGeometry ? "yes" : "no",
              c.assemblyTree ? "yes" : "no", c.perFaceColor ? "yes" : "no");

  if (b.valid) {
    const auto d = b.size();
    std::printf("  bounding box  %.3f x %.3f x %.3f mm\n", d[0], d[1], d[2]);
  }
  std::printf("  topology      %d solids, %d shells, %d faces, %d edges, %d verts\n",
              s.solids, s.shells, s.faces, s.edges, s.vertices);

  if (s.surfaces.total() > 0) {
    const auto& m = s.surfaces;
    std::printf("  surfaces      %d plane, %d cylinder, %d cone, %d sphere, "
                "%d torus, %d nurbs, %d other\n",
                m.plane, m.cylinder, m.cone, m.sphere, m.torus,
                m.bspline + m.bezier, m.revolution + m.extrusion + m.other);
  }

  std::printf("  area          %.3f mm^2\n", s.area);
  if (s.volume > 0) {
    std::printf("  volume        %.3f mm^3  (%.3f cm^3)\n", s.volume, s.volume / 1000.0);
    std::printf("  center mass   (%.3f, %.3f, %.3f)\n", s.centerOfMass[0],
                s.centerOfMass[1], s.centerOfMass[2]);
  }

  // The payoff: exact hole diameters straight from the analytic surface,
  // with no mesh approximation anywhere in the path.
  if (c.exactGeometry) {
    auto cyls = doc->cylinders(12);
    if (!cyls.empty()) {
      std::printf("  cylindrical faces (exact, largest first):\n");
      for (const auto& cy : cyls)
        std::printf("      d=%9.4f mm  r=%8.4f  axis(%.2f,%.2f,%.2f) at (%.2f,%.2f,%.2f)\n",
                    cy.radius * 2.0, cy.radius, cy.axis[0], cy.axis[1], cy.axis[2],
                    cy.location[0], cy.location[1], cy.location[2]);
    }
  }

  if (distA >= 0) {
    doc->renderMesh();  // populates the faceId table
    double d = 0;
    if (doc->distanceBetween(EntityKind::Face, static_cast<std::uint32_t>(distA),
                             EntityKind::Face, static_cast<std::uint32_t>(distB), d))
      std::printf("  distance      face %d to face %d = %.6f mm (exact)\n",
                  distA, distB, d);
    else
      std::printf("  distance      query failed\n");
  }

  if (edgeA >= 0) {
    doc->renderMesh();
    double d = 0;
    if (doc->distanceBetween(EntityKind::Edge, static_cast<std::uint32_t>(edgeA),
                             EntityKind::Edge, static_cast<std::uint32_t>(edgeB), d))
      std::printf("  edge distance edge %d to edge %d = %.6f mm (exact)\n",
                  edgeA, edgeB, d);
    else
      std::printf("  edge distance query failed\n");
  }

  {
    std::vector<std::uint32_t> group;
    for (int i = 2; i < argc; ++i)
      if (std::string(argv[i]) == "--group")
        for (int j = i + 1; j < argc; ++j) group.push_back(std::atoi(argv[j]));
    if (!group.empty()) {
      doc->renderMesh();
      const auto g = doc->measureEdges(group);
      std::printf("  edge group    %zu edges, total length %.4f mm, %s%s",
                  g.count, g.totalLength,
                  g.connected ? "connected" : "not connected",
                  g.closed ? " (closed loop)" : "");
      if (g.connected && !g.closed)
        std::printf(", end to end %.4f mm", g.endToEnd);
      std::printf("\n");
    }
  }

  for (int i = 2; i + 1 < argc; ++i)
    if (std::string(argv[i]) == "--quality")
      doc->retessellate(std::atof(argv[i + 1]));

  auto t2 = std::chrono::steady_clock::now();
  const auto& mesh = doc->renderMesh();
  auto t3 = std::chrono::steady_clock::now();
  std::printf("  render mesh   %zu verts, %zu tris, %zu face ranges in %.1f ms\n",
              mesh.vertices.size(), mesh.indices.size() / 3, mesh.faces.size(),
              ms(t2, t3));
  {
    double nlen = 0; std::size_t zero = 0;
    for (const auto &v : mesh.vertices) {
      const double l = std::sqrt(double(v.normal[0]*v.normal[0] +
                                        v.normal[1]*v.normal[1] +
                                        v.normal[2]*v.normal[2]));
      nlen += l; if (l < 1e-6) zero++;
    }
    std::printf("  normals       mean len %.4f, %zu degenerate of %zu\n",
                mesh.vertices.empty() ? 0.0 : nlen / mesh.vertices.size(),
                zero, mesh.vertices.size());
    for (std::size_t i = 0; i < 3 && i < mesh.vertices.size(); ++i)
      std::printf("      v%zu pos(%.2f,%.2f,%.2f) n(%.3f,%.3f,%.3f)\n", i,
                  mesh.vertices[i].position[0], mesh.vertices[i].position[1],
                  mesh.vertices[i].position[2], mesh.vertices[i].normal[0],
                  mesh.vertices[i].normal[1], mesh.vertices[i].normal[2]);
  }
  std::printf("  edges         %zu points, %zu line segments\n",
              mesh.edgePositions.size() / 3, mesh.edgeIndices.size() / 2);
  const double mb =
      (mesh.vertices.size() * sizeof(RenderVertex) +
       mesh.indices.size() * 4 + mesh.edgePositions.size() * 4 +
       mesh.edgeIndices.size() * 4) / (1024.0 * 1024.0);
  std::printf("  gpu upload    %.2f MB\n", mb);

  if (!mesh.edgeIds.empty()) {
    std::vector<std::uint32_t> unique;
    for (auto id : mesh.edgeIds)
      if (unique.empty() || unique.back() != id) unique.push_back(id);
    std::sort(unique.begin(), unique.end());
    unique.erase(std::unique(unique.begin(), unique.end()), unique.end());
    std::printf("  edges (%zu unique, longest first):\n", unique.size());
    std::vector<std::pair<double, std::uint32_t>> byLength;
    for (auto id : unique) byLength.push_back({doc->edgeInfo(id).length, id});
    std::sort(byLength.rbegin(), byLength.rend());
    const std::size_t shown = std::getenv("EDGES_ALL") ? byLength.size() : 6;
    for (std::size_t i = 0; i < byLength.size() && i < shown; ++i) {
      const auto info = doc->edgeInfo(byLength[i].second);
      std::printf("      edge %-4u %-8s length %10.4f mm", byLength[i].second,
                  info.curveType.c_str(), info.length);
      if (info.hasRadius) std::printf("  d=%.4f", info.radius * 2.0);
      if (std::getenv("EDGES_ALL"))
        std::printf("  (%.1f,%.1f,%.1f)->(%.1f,%.1f,%.1f)", info.start[0],
                    info.start[1], info.start[2], info.end[0], info.end[1],
                    info.end[2]);
      std::printf("\n");
    }
  }


  // Simulate a pick on every face, the way the identity buffer will.
  if (c.exactGeometry && !mesh.faces.empty()) {
    std::printf("  face probe (first 6 of %zu):\n", mesh.faces.size());
    for (std::size_t i = 0; i < mesh.faces.size() && i < 6; ++i) {
      const auto fi = doc->faceInfo(mesh.faces[i].faceId);
      std::printf("      face %-4u %-9s area=%10.3f mm^2", mesh.faces[i].faceId,
                  fi.surfaceType.c_str(), fi.area);
      if (fi.hasRadius) std::printf("  d=%.4f mm", fi.radius * 2.0);
      std::printf("\n");
    }
    // Exact face-to-face distance: the core measurement operation.
    double dist = 0;
    if (mesh.faces.size() >= 2 &&
        doc->distanceBetween(EntityKind::Face, mesh.faces[0].faceId,
                             EntityKind::Face, mesh.faces[1].faceId, dist))
      std::printf("  distance      face %u to face %u = %.4f mm (exact)\n",
                  mesh.faces[0].faceId, mesh.faces[1].faceId, dist);
  }
  std::printf("  total         %.1f ms\n", ms(t0, t3));
  return 0;
}
