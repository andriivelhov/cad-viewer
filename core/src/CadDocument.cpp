#include "cadcore/CadDocument.h"

#include <BRepAdaptor_Surface.hxx>
#include <BRepBndLib.hxx>
#include <BRepGProp.hxx>
#include <BRepMesh_IncrementalMesh.hxx>
#include <BRep_Builder.hxx>
#include <BRep_Tool.hxx>
#include <Bnd_Box.hxx>
#include <DE_Wrapper.hxx>
#include <Message_ProgressRange.hxx>
#include <RWObj_CafReader.hxx>
#include <GProp_GProps.hxx>
#include <Geom_CylindricalSurface.hxx>
#include <Message.hxx>
#include <Message_PrinterOStream.hxx>
#include <Poly_Triangulation.hxx>
#include <Standard_Failure.hxx>
#include <TDF_LabelSequence.hxx>
#include <TDocStd_Document.hxx>
#include <TopExp_Explorer.hxx>
#include <TopLoc_Location.hxx>
#include <TopoDS.hxx>
#include <TopoDS_Compound.hxx>
#include <TopoDS_Face.hxx>
#include <XCAFApp_Application.hxx>
#include <XCAFDoc_ColorTool.hxx>
#include <XCAFDoc_DocumentTool.hxx>
#include <XCAFDoc_ShapeTool.hxx>
#include <BRepExtrema_DistShapeShape.hxx>
#include <Poly_PolygonOnTriangulation.hxx>
#include <TopExp.hxx>
#include <TopTools_IndexedDataMapOfShapeListOfShape.hxx>
#include <TopTools_IndexedMapOfShape.hxx>
#include <TopTools_ListOfShape.hxx>
#include <TopoDS_Edge.hxx>
#include <gp.hxx>
#include <gp_Pln.hxx>
#include <BRepAdaptor_Curve.hxx>
#include <BRepGProp.hxx>
#include <GeomAPI_ProjectPointOnSurf.hxx>
#include <Geom_Surface.hxx>

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <functional>
#include <map>

namespace cadcore {

struct Document::Impl {
  Handle(TDocStd_Document) doc;
  TopoDS_Shape shape;
  std::vector<TopoDS_Face> facesById;  // index == faceId
  std::vector<TopoDS_Edge> edgesById;  // index == edgeId
  RenderMesh mesh;
  bool meshBuilt = false;
};

namespace {

struct FormatSpec {
  const char* id;
  const char* ext;
  Fidelity fidelity;
  bool declaresUnits;
};

// Everything below is served by OCCT's DE_Wrapper provider registry, so the
// marginal cost of each extra format here is one table row.
const FormatSpec kFormats[] = {
    {"STEP", "step", Fidelity::BRep, true},
    {"STEP", "stp", Fidelity::BRep, true},
    {"IGES", "iges", Fidelity::BRep, true},
    {"IGES", "igs", Fidelity::BRep, true},
    {"BREP", "brep", Fidelity::BRep, false},
    {"glTF", "gltf", Fidelity::Mesh, true},
    {"glTF", "glb", Fidelity::Mesh, true},
    {"OBJ", "obj", Fidelity::Mesh, false},
    {"STL", "stl", Fidelity::Mesh, false},
    {"VRML", "wrl", Fidelity::Mesh, false},
    {"VRML", "vrml", Fidelity::Mesh, false},
};

std::string lowerExt(const std::string& path) {
  auto dot = path.find_last_of('.');
  if (dot == std::string::npos) return {};
  std::string ext = path.substr(dot + 1);
  std::transform(ext.begin(), ext.end(), ext.begin(),
                 [](unsigned char c) { return std::tolower(c); });
  return ext;
}

const FormatSpec* findSpec(const std::string& ext) {
  for (const auto& f : kFormats)
    if (ext == f.ext) return &f;
  return nullptr;
}

// Mesh-format faces carry a triangulation but no geometric surface; asking
// BRepAdaptor_Surface about them throws. Callers must check this first.
bool hasAnalyticSurface(const TopoDS_Face& face) {
  TopLoc_Location loc;
  return !BRep_Tool::Surface(face, loc).IsNull();
}

void classify(const TopoDS_Face& face, SurfaceMix& mix) {
  if (!hasAnalyticSurface(face)) {
    mix.other++;
    return;
  }
  try {
    BRepAdaptor_Surface surf(face, false);
    switch (surf.GetType()) {
      case GeomAbs_Plane: mix.plane++; break;
      case GeomAbs_Cylinder: mix.cylinder++; break;
      case GeomAbs_Cone: mix.cone++; break;
      case GeomAbs_Sphere: mix.sphere++; break;
      case GeomAbs_Torus: mix.torus++; break;
      case GeomAbs_BSplineSurface: mix.bspline++; break;
      case GeomAbs_BezierSurface: mix.bezier++; break;
      case GeomAbs_SurfaceOfRevolution: mix.revolution++; break;
      case GeomAbs_SurfaceOfExtrusion: mix.extrusion++; break;
      default: mix.other++; break;
    }
  } catch (const Standard_Failure&) {
    mix.other++;
  }
}

}  // namespace

const char* toString(Fidelity f) {
  switch (f) {
    case Fidelity::BRep: return "B-rep (exact)";
    case Fidelity::Mesh: return "mesh (approximate)";
    default: return "unknown";
  }
}

Document::Document() : m_impl(std::make_unique<Impl>()) {}
Document::~Document() = default;

std::vector<FormatInfo> Document::supportedFormats() {
  std::vector<FormatInfo> out;
  for (const auto& f : kFormats)
    out.push_back({f.id, f.ext, f.fidelity});
  return out;
}

std::unique_ptr<Document> Document::load(const std::string& path,
                                         std::string& error) {
  const std::string ext = lowerExt(path);
  const FormatSpec* spec = findSpec(ext);
  if (!spec) {
    error = "unsupported extension: ." + ext;
    return nullptr;
  }

  auto self = std::unique_ptr<Document>(new Document());
  self->m_format = {spec->id, ext, spec->fidelity};

  Handle(XCAFApp_Application) app = XCAFApp_Application::GetApplication();
  app->NewDocument("BinXCAF", self->m_impl->doc);
  if (self->m_impl->doc.IsNull()) {
    error = "could not create XCAF document";
    return nullptr;
  }

  try {
    if (ext == "obj") {
      // OBJ declares no unit and OCCT's generic path assumes metres, so a
      // 100 mm part loads as 100 m. Use the concrete reader, where the file
      // and system units can be stated explicitly. Units are scale factors
      // against metres, so 0.001 on both sides means "mm in, mm out".
      RWObj_CafReader reader;
      reader.SetDocument(self->m_impl->doc);
      reader.SetFileLengthUnit(0.001);
      reader.SetSystemLengthUnit(0.001);
      // OBJ is conventionally Y-up; OCCT's default converts it to our Z-up.
      reader.SetFileCoordinateSystem(RWMesh_CoordinateSystem_Yup);
      reader.SetSystemCoordinateSystem(RWMesh_CoordinateSystem_Zup);
      if (!reader.Perform(path.c_str(), Message_ProgressRange())) {
        error = "OBJ reader failed";
        return nullptr;
      }
    } else {
      Handle(DE_Wrapper) wrapper = DE_Wrapper::GlobalWrapper();
      wrapper->GlobalParameters.LengthUnit = 1.0;  // mm
      wrapper->GlobalParameters.SystemUnit = 1.0;
      wrapper->UpdateLoad(Standard_True);
      if (!wrapper->Read(TCollection_AsciiString(path.c_str()),
                         self->m_impl->doc)) {
        error = "reader rejected the file";
        return nullptr;
      }
    }
  } catch (const Standard_Failure& e) {
    error = std::string("exception while reading: ") + e.GetMessageString();
    return nullptr;
  }

  Handle(XCAFDoc_ShapeTool) shapeTool =
      XCAFDoc_DocumentTool::ShapeTool(self->m_impl->doc->Main());
  Handle(XCAFDoc_ColorTool) colorTool =
      XCAFDoc_DocumentTool::ColorTool(self->m_impl->doc->Main());

  TDF_LabelSequence roots;
  shapeTool->GetFreeShapes(roots);
  if (roots.Length() == 0) {
    error = "file parsed but contained no shapes";
    return nullptr;
  }

  BRep_Builder builder;
  TopoDS_Compound compound;
  builder.MakeCompound(compound);
  for (Standard_Integer i = 1; i <= roots.Length(); ++i) {
    TopoDS_Shape s = shapeTool->GetShape(roots.Value(i));
    if (!s.IsNull()) builder.Add(compound, s);
  }
  self->m_impl->shape = compound;

  // Part count = leaf shapes, not assembly nodes.
  TDF_LabelSequence all;
  shapeTool->GetShapes(all);
  int leaves = 0, instances = 0;
  bool sawAssembly = false;
  for (Standard_Integer i = 1; i <= all.Length(); ++i) {
    const TDF_Label lab = all.Value(i);
    if (shapeTool->IsAssembly(lab)) {
      sawAssembly = true;
      TDF_LabelSequence comps;
      shapeTool->GetComponents(lab, comps);
      instances += comps.Length();
    } else if (shapeTool->IsSimpleShape(lab)) {
      leaves++;
    }
  }
  self->m_partCount = leaves > 0 ? leaves : roots.Length();
  // One prototype referenced many times is the common assembly shape; report
  // both so "1 part" doesn't look wrong for a 500-instance layout.
  self->m_instanceCount = instances > 0 ? instances : self->m_partCount;

  TDF_LabelSequence colors;
  colorTool->GetColors(colors);

  self->m_caps.faceSelection = spec->fidelity == Fidelity::BRep;
  self->m_caps.exactGeometry = spec->fidelity == Fidelity::BRep;
  self->m_caps.assemblyTree = sawAssembly || self->m_partCount > 1;
  self->m_caps.perFaceColor = colors.Length() > 0;
  self->m_caps.declaredUnits = spec->declaresUnits;

  Standard_Real unit = 1.0;
  if (XCAFDoc_DocumentTool::GetLengthUnit(self->m_impl->doc, unit) && unit > 0)
    self->m_unitMM = unit * 1000.0;  // OCCT reports metres

  self->analyze();
  return self;
}

void Document::analyze() {
  const TopoDS_Shape& shape = m_impl->shape;

  Bnd_Box box;
  BRepBndLib::Add(shape, box, false);
  if (!box.IsVoid()) {
    box.Get(m_bounds.min[0], m_bounds.min[1], m_bounds.min[2],
            m_bounds.max[0], m_bounds.max[1], m_bounds.max[2]);
    m_bounds.valid = true;
  }

  for (TopExp_Explorer e(shape, TopAbs_SOLID); e.More(); e.Next()) m_stats.solids++;
  for (TopExp_Explorer e(shape, TopAbs_SHELL); e.More(); e.Next()) m_stats.shells++;
  for (TopExp_Explorer e(shape, TopAbs_EDGE); e.More(); e.Next()) m_stats.edges++;
  for (TopExp_Explorer e(shape, TopAbs_VERTEX); e.More(); e.Next()) m_stats.vertices++;
  for (TopExp_Explorer e(shape, TopAbs_FACE); e.More(); e.Next()) {
    m_stats.faces++;
    classify(TopoDS::Face(e.Current()), m_stats.surfaces);
  }

  try {
    GProp_GProps surfaceProps;
    BRepGProp::SurfaceProperties(shape, surfaceProps);
    m_stats.area = surfaceProps.Mass();

    if (m_stats.solids > 0) {
      GProp_GProps volumeProps;
      BRepGProp::VolumeProperties(shape, volumeProps);
      m_stats.volume = volumeProps.Mass();
      const gp_Pnt com = volumeProps.CentreOfMass();
      m_stats.centerOfMass = {com.X(), com.Y(), com.Z()};
    } else {
      const gp_Pnt com = surfaceProps.CentreOfMass();
      m_stats.centerOfMass = {com.X(), com.Y(), com.Z()};
    }
  } catch (const Standard_Failure&) {
    // Mass properties can fail on invalid solids; stats stay zeroed.
  }
}

std::vector<CylinderFace> Document::cylinders(std::size_t limit) const {
  std::map<std::tuple<long, long, long, long>, CylinderFace> unique;

  for (TopExp_Explorer e(m_impl->shape, TopAbs_FACE); e.More(); e.Next()) {
    const TopoDS_Face face = TopoDS::Face(e.Current());
    if (!hasAnalyticSurface(face)) continue;
    try {
      BRepAdaptor_Surface surf(face, false);
      if (surf.GetType() != GeomAbs_Cylinder) continue;
      const gp_Cylinder cyl = surf.Cylinder();
      const gp_Ax1 axis = cyl.Axis();
      const gp_Pnt loc = axis.Location();
      const gp_Dir dir = axis.Direction();

      // A hole split across seam faces shows up several times; collapse by
      // rounding radius and axis position to 1e-4 mm.
      auto q = [](double v) { return static_cast<long>(std::llround(v * 1e4)); };
      const auto key = std::make_tuple(q(cyl.Radius()), q(loc.X()), q(loc.Y()), q(loc.Z()));

      CylinderFace cf;
      cf.radius = cyl.Radius();
      cf.axis = {dir.X(), dir.Y(), dir.Z()};
      cf.location = {loc.X(), loc.Y(), loc.Z()};
      unique.emplace(key, cf);
    } catch (const Standard_Failure&) {
    }
  }

  std::vector<CylinderFace> out;
  out.reserve(unique.size());
  for (auto& [k, v] : unique) out.push_back(v);
  std::sort(out.begin(), out.end(),
            [](const CylinderFace& a, const CylinderFace& b) {
              return a.radius > b.radius;
            });
  if (limit > 0 && out.size() > limit) out.resize(limit);
  return out;
}

bool Document::tessellate(double deflection, double angularDeg) {
  if (m_impl->shape.IsNull()) return false;
  if (deflection <= 0) {
    // Scale-relative deflection: absolute values wreck either tiny parts or
    // huge assemblies depending on which you pick.
    double diag = 1.0;
    if (m_bounds.valid) {
      const auto s = m_bounds.size();
      diag = std::sqrt(s[0] * s[0] + s[1] * s[1] + s[2] * s[2]);
    }
    deflection = std::max(diag * 1e-3, 1e-4);
  }
  m_deflection = deflection;
  try {
    BRepMesh_IncrementalMesh mesher(m_impl->shape, deflection, Standard_False,
                                    angularDeg * M_PI / 180.0, Standard_True);
    return mesher.IsDone();
  } catch (const Standard_Failure&) {
    return false;
  }
}

std::size_t Document::triangleCount() const {
  std::size_t n = 0;
  for (TopExp_Explorer e(m_impl->shape, TopAbs_FACE); e.More(); e.Next()) {
    TopLoc_Location loc;
    Handle(Poly_Triangulation) tri =
        BRep_Tool::Triangulation(TopoDS::Face(e.Current()), loc);
    if (!tri.IsNull()) n += static_cast<std::size_t>(tri->NbTriangles());
  }
  return n;
}

}  // namespace cadcore

// ---------------------------------------------------------------------------
// GPU buffer extraction
// ---------------------------------------------------------------------------

namespace cadcore {
namespace {

const char* surfaceTypeName(GeomAbs_SurfaceType t) {
  switch (t) {
    case GeomAbs_Plane: return "plane";
    case GeomAbs_Cylinder: return "cylinder";
    case GeomAbs_Cone: return "cone";
    case GeomAbs_Sphere: return "sphere";
    case GeomAbs_Torus: return "torus";
    case GeomAbs_BSplineSurface: return "b-spline";
    case GeomAbs_BezierSurface: return "bezier";
    case GeomAbs_SurfaceOfRevolution: return "revolved";
    case GeomAbs_SurfaceOfExtrusion: return "extruded";
    default: return "freeform";
  }
}

}  // namespace

const RenderMesh& Document::renderMesh(double deflection) {
  if (m_impl->meshBuilt) return m_impl->mesh;
  tessellate(deflection);

  RenderMesh& out = m_impl->mesh;
  m_impl->facesById.clear();
  m_impl->edgesById.clear();

  // Stable face ordering so faceId survives across calls.
  TopTools_IndexedMapOfShape faceMap;
  TopExp::MapShapes(m_impl->shape, TopAbs_FACE, faceMap);

  for (Standard_Integer fi = 1; fi <= faceMap.Extent(); ++fi) {
    const TopoDS_Face face = TopoDS::Face(faceMap(fi));
    TopLoc_Location loc;
    Handle(Poly_Triangulation) tri = BRep_Tool::Triangulation(face, loc);

    const std::uint32_t faceId = static_cast<std::uint32_t>(m_impl->facesById.size());
    m_impl->facesById.push_back(face);
    if (tri.IsNull() || tri->NbTriangles() == 0) continue;

    const gp_Trsf trsf = loc.Transformation();
    const bool reversed = face.Orientation() == TopAbs_REVERSED;
    const std::uint32_t baseVertex = static_cast<std::uint32_t>(out.vertices.size());
    const std::uint32_t firstIndex = static_cast<std::uint32_t>(out.indices.size());

    const bool haveNormals = tri->HasNormals();

    if (haveNormals) {
      for (Standard_Integer i = 1; i <= tri->NbNodes(); ++i) {
        gp_Pnt p = tri->Node(i);
        p.Transform(trsf);
        RenderVertex v{};
        v.position[0] = static_cast<float>(p.X());
        v.position[1] = static_cast<float>(p.Y());
        v.position[2] = static_cast<float>(p.Z());
        gp_Dir n = tri->Normal(i);
        n.Transform(trsf);
        const double s = reversed ? -1.0 : 1.0;
        v.normal[0] = static_cast<float>(n.X() * s);
        v.normal[1] = static_cast<float>(n.Y() * s);
        v.normal[2] = static_cast<float>(n.Z() * s);
        v.faceId = faceId;
        out.vertices.push_back(v);
      }
      for (Standard_Integer i = 1; i <= tri->NbTriangles(); ++i) {
        Standard_Integer a, b, c;
        tri->Triangle(i).Get(a, b, c);
        if (reversed) std::swap(b, c);
        out.indices.push_back(baseVertex + a - 1);
        out.indices.push_back(baseVertex + b - 1);
        out.indices.push_back(baseVertex + c - 1);
      }
    } else if (m_format.fidelity == Fidelity::BRep) {
      // A B-rep face is smooth by construction and gets its own vertex range,
      // so averaging shared vertices within it gives smooth curvature while
      // edges between faces stay hard.
      for (Standard_Integer i = 1; i <= tri->NbNodes(); ++i) {
        gp_Pnt p = tri->Node(i);
        p.Transform(trsf);
        RenderVertex v{};
        v.position[0] = static_cast<float>(p.X());
        v.position[1] = static_cast<float>(p.Y());
        v.position[2] = static_cast<float>(p.Z());
        v.faceId = faceId;
        out.vertices.push_back(v);
      }
      for (Standard_Integer i = 1; i <= tri->NbTriangles(); ++i) {
        Standard_Integer a, b, c;
        tri->Triangle(i).Get(a, b, c);
        if (reversed) std::swap(b, c);
        out.indices.push_back(baseVertex + a - 1);
        out.indices.push_back(baseVertex + b - 1);
        out.indices.push_back(baseVertex + c - 1);
      }
      for (std::size_t i = firstIndex; i + 2 < out.indices.size(); i += 3) {
        RenderVertex& v0 = out.vertices[out.indices[i]];
        RenderVertex& v1 = out.vertices[out.indices[i + 1]];
        RenderVertex& v2 = out.vertices[out.indices[i + 2]];
        const float ux = v1.position[0] - v0.position[0];
        const float uy = v1.position[1] - v0.position[1];
        const float uz = v1.position[2] - v0.position[2];
        const float wx = v2.position[0] - v0.position[0];
        const float wy = v2.position[1] - v0.position[1];
        const float wz = v2.position[2] - v0.position[2];
        const float nx = uy * wz - uz * wy;
        const float ny = uz * wx - ux * wz;
        const float nz = ux * wy - uy * wx;
        const float len = std::sqrt(nx * nx + ny * ny + nz * nz);
        const float s = len > 0 ? 1.0f / len : 0.0f;
        for (RenderVertex* v : {&v0, &v1, &v2}) {
          v->normal[0] += nx * s;
          v->normal[1] += ny * s;
          v->normal[2] += nz * s;
        }
      }
      for (std::size_t i = baseVertex; i < out.vertices.size(); ++i) {
        RenderVertex& v = out.vertices[i];
        const float l = std::sqrt(v.normal[0] * v.normal[0] +
                                  v.normal[1] * v.normal[1] +
                                  v.normal[2] * v.normal[2]);
        if (l > 0) { v.normal[0] /= l; v.normal[1] /= l; v.normal[2] /= l; }
      }
    } else {
      // A mesh file has no face structure: readers weld the whole model into
      // one surface, so averaging shared vertices smears every hard edge and a
      // plate comes out looking melted. Emit unshared vertices carrying their
      // triangle's own normal, which is the flat shading these formats want.
      for (Standard_Integer i = 1; i <= tri->NbTriangles(); ++i) {
        Standard_Integer a, b, c;
        tri->Triangle(i).Get(a, b, c);
        if (reversed) std::swap(b, c);

        gp_Pnt p0 = tri->Node(a), p1 = tri->Node(b), p2 = tri->Node(c);
        p0.Transform(trsf); p1.Transform(trsf); p2.Transform(trsf);

        const gp_Vec u(p0, p1), w(p0, p2);
        gp_Vec normal = u.Crossed(w);
        const double length = normal.Magnitude();
        if (length > gp::Resolution()) normal /= length;

        for (const gp_Pnt& p : {p0, p1, p2}) {
          RenderVertex v{};
          v.position[0] = static_cast<float>(p.X());
          v.position[1] = static_cast<float>(p.Y());
          v.position[2] = static_cast<float>(p.Z());
          v.normal[0] = static_cast<float>(normal.X());
          v.normal[1] = static_cast<float>(normal.Y());
          v.normal[2] = static_cast<float>(normal.Z());
          v.faceId = faceId;
          out.indices.push_back(static_cast<std::uint32_t>(out.vertices.size()));
          out.vertices.push_back(v);
        }
      }
    }

    out.faces.push_back({faceId, firstIndex,
                         static_cast<std::uint32_t>(out.indices.size() - firstIndex)});
  }

  // Feature edges. These come from the tessellation OCCT already computed, so
  // they follow the true geometry - deriving them from the mesh would miss
  // smooth silhouettes and add noise on curved faces.
  // Ancestor map so each edge only consults the faces it actually belongs to.
  // Scanning every face per edge is O(edges x faces) and dominates load time on
  // real assemblies (4.6 s -> milliseconds on a 500-part model).
  TopTools_IndexedDataMapOfShapeListOfShape edgeToFaces;
  TopExp::MapShapesAndAncestors(m_impl->shape, TopAbs_EDGE, TopAbs_FACE, edgeToFaces);

  TopTools_IndexedMapOfShape edgeMap;
  TopExp::MapShapes(m_impl->shape, TopAbs_EDGE, edgeMap);
  for (Standard_Integer ei = 1; ei <= edgeMap.Extent(); ++ei) {
    const TopoDS_Edge edge = TopoDS::Edge(edgeMap(ei));

    // Prefer the polygon shared with a face triangulation; fall back to a
    // standalone 3D polygon.
    Handle(Poly_Polygon3D) poly3d;
    std::vector<gp_Pnt> pts;

    TopLoc_Location eloc;
    poly3d = BRep_Tool::Polygon3D(edge, eloc);
    if (!poly3d.IsNull()) {
      const gp_Trsf t = eloc.Transformation();
      for (Standard_Integer i = 1; i <= poly3d->NbNodes(); ++i) {
        gp_Pnt p = poly3d->Nodes().Value(i);
        p.Transform(t);
        pts.push_back(p);
      }
    } else if (edgeToFaces.Contains(edge)) {
      for (TopTools_ListOfShape::Iterator it(edgeToFaces.FindFromKey(edge));
           it.More() && pts.empty(); it.Next()) {
        const TopoDS_Face f = TopoDS::Face(it.Value());
        TopLoc_Location floc;
        Handle(Poly_Triangulation) tri = BRep_Tool::Triangulation(f, floc);
        if (tri.IsNull()) continue;
        Handle(Poly_PolygonOnTriangulation) pot =
            BRep_Tool::PolygonOnTriangulation(edge, tri, floc);
        if (pot.IsNull()) continue;
        const gp_Trsf t = floc.Transformation();
        for (Standard_Integer i = 1; i <= pot->NbNodes(); ++i) {
          gp_Pnt p = tri->Node(pot->Node(i));
          p.Transform(t);
          pts.push_back(p);
        }
      }
    }
    if (pts.size() < 2) continue;

    const std::uint32_t edgeId =
        static_cast<std::uint32_t>(m_impl->edgesById.size());
    m_impl->edgesById.push_back(edge);

    const std::uint32_t base =
        static_cast<std::uint32_t>(out.edgePositions.size() / 3);
    for (const gp_Pnt& p : pts) {
      out.edgePositions.push_back(static_cast<float>(p.X()));
      out.edgePositions.push_back(static_cast<float>(p.Y()));
      out.edgePositions.push_back(static_cast<float>(p.Z()));
    }
    for (std::size_t i = 0; i + 1 < pts.size(); ++i) {
      out.edgeIndices.push_back(base + static_cast<std::uint32_t>(i));
      out.edgeIndices.push_back(base + static_cast<std::uint32_t>(i) + 1);
      out.edgeIds.push_back(edgeId);
    }
  }

  out.edgeCount = static_cast<std::uint32_t>(m_impl->edgesById.size());

  m_impl->meshBuilt = true;
  return out;
}

FaceInfo Document::faceInfo(std::uint32_t faceId) const {
  FaceInfo info;
  if (faceId >= m_impl->facesById.size()) return info;
  const TopoDS_Face& face = m_impl->facesById[faceId];
  if (face.IsNull()) return info;

  try {
    GProp_GProps props;
    BRepGProp::SurfaceProperties(face, props);
    info.area = props.Mass();
  } catch (const Standard_Failure&) {
  }

  if (!hasAnalyticSurface(face)) {
    info.valid = true;
    info.surfaceType = "mesh";
    return info;
  }

  try {
    BRepAdaptor_Surface surf(face, false);
    info.surfaceType = surfaceTypeName(surf.GetType());
    info.valid = true;
    if (surf.GetType() == GeomAbs_Cylinder) {
      const gp_Cylinder cyl = surf.Cylinder();
      info.hasRadius = true;
      info.radius = cyl.Radius();
      const gp_Ax1 ax = cyl.Axis();
      info.axis = {ax.Direction().X(), ax.Direction().Y(), ax.Direction().Z()};
      info.location = {ax.Location().X(), ax.Location().Y(), ax.Location().Z()};
    } else if (surf.GetType() == GeomAbs_Sphere) {
      info.hasRadius = true;
      info.radius = surf.Sphere().Radius();
    } else if (surf.GetType() == GeomAbs_Plane) {
      const gp_Pln pln = surf.Plane();
      const gp_Dir n = pln.Axis().Direction();
      info.normal = {n.X(), n.Y(), n.Z()};
      const gp_Pnt o = pln.Location();
      info.location = {o.X(), o.Y(), o.Z()};
    }
  } catch (const Standard_Failure&) {
  }
  return info;
}


}  // namespace cadcore

// ---------------------------------------------------------------------------
// Edge and point queries
// ---------------------------------------------------------------------------

namespace cadcore {
namespace {

const char* curveTypeName(GeomAbs_CurveType t) {
  switch (t) {
    case GeomAbs_Line: return "line";
    case GeomAbs_Circle: return "circle";
    case GeomAbs_Ellipse: return "ellipse";
    case GeomAbs_Hyperbola: return "hyperbola";
    case GeomAbs_Parabola: return "parabola";
    case GeomAbs_BezierCurve: return "bezier";
    case GeomAbs_BSplineCurve: return "spline";
    default: return "curve";
  }
}

}  // namespace

EdgeInfo Document::edgeInfo(std::uint32_t edgeId) const {
  EdgeInfo info;
  if (edgeId >= m_impl->edgesById.size()) return info;
  const TopoDS_Edge& edge = m_impl->edgesById[edgeId];
  if (edge.IsNull()) return info;

  try {
    // Exact arc length from the curve, not the tessellated polyline.
    GProp_GProps props;
    BRepGProp::LinearProperties(edge, props);
    info.length = props.Mass();

    BRepAdaptor_Curve curve(edge);
    info.curveType = curveTypeName(curve.GetType());
    info.closed = BRep_Tool::IsClosed(edge) != Standard_False;
    if (curve.GetType() == GeomAbs_Circle) {
      info.hasRadius = true;
      info.radius = curve.Circle().Radius();
    }
    const gp_Pnt a = curve.Value(curve.FirstParameter());
    const gp_Pnt b = curve.Value(curve.LastParameter());
    info.start = {a.X(), a.Y(), a.Z()};
    info.end = {b.X(), b.Y(), b.Z()};
    info.valid = true;
  } catch (const Standard_Failure&) {
  }
  return info;
}

bool Document::distanceBetween(EntityKind kindA, std::uint32_t idA,
                               EntityKind kindB, std::uint32_t idB,
                               double& outDistance) const {
  auto resolve = [this](EntityKind kind, std::uint32_t id,
                        TopoDS_Shape& shape) {
    if (kind == EntityKind::Face) {
      if (id >= m_impl->facesById.size()) return false;
      shape = m_impl->facesById[id];
    } else {
      if (id >= m_impl->edgesById.size()) return false;
      shape = m_impl->edgesById[id];
    }
    return !shape.IsNull();
  };

  TopoDS_Shape a, b;
  if (!resolve(kindA, idA, a) || !resolve(kindB, idB, b)) return false;
  try {
    BRepExtrema_DistShapeShape solver(a, b);
    if (!solver.IsDone()) return false;
    outDistance = solver.Value();
    return true;
  } catch (const Standard_Failure&) {
    return false;
  }
}

bool Document::snapPointToFace(std::uint32_t faceId,
                               const std::array<double, 3>& approximate,
                               std::array<double, 3>& outExact) const {
  outExact = approximate;
  if (faceId >= m_impl->facesById.size()) return false;
  const TopoDS_Face& face = m_impl->facesById[faceId];
  if (face.IsNull() || !hasAnalyticSurface(face)) return false;

  try {
    TopLoc_Location loc;
    Handle(Geom_Surface) surface = BRep_Tool::Surface(face, loc);
    if (surface.IsNull()) return false;
    gp_Pnt query(approximate[0], approximate[1], approximate[2]);
    query.Transform(loc.Transformation().Inverted());

    GeomAPI_ProjectPointOnSurf projector(query, surface);
    if (!projector.IsDone() || projector.NbPoints() < 1) return false;
    gp_Pnt nearest = projector.NearestPoint();
    nearest.Transform(loc.Transformation());
    outExact = {nearest.X(), nearest.Y(), nearest.Z()};
    return true;
  } catch (const Standard_Failure&) {
    return false;
  }
}

}  // namespace cadcore

// ---------------------------------------------------------------------------
// Snapping
// ---------------------------------------------------------------------------

#include <BRepAdaptor_Curve.hxx>
#include <GeomAPI_ProjectPointOnCurve.hxx>
#include <TopExp.hxx>
#include <TopoDS_Vertex.hxx>

namespace cadcore {

const char* toString(SnapKind kind) {
  switch (kind) {
    case SnapKind::Vertex: return "vertex";
    case SnapKind::EdgeMidpoint: return "midpoint";
    case SnapKind::CircleCentre: return "centre";
    case SnapKind::EdgePoint: return "on edge";
    default: return "on face";
  }
}

namespace {

// A face can bound a great many edges; snapping only ever needs the handful
// near the cursor, so cap the work done per click.
constexpr std::size_t kMaxSnapCandidates = 240;

void appendEdgeCandidates(const TopoDS_Edge& edge,
                          std::vector<SnapCandidate>& out) {
  if (out.size() >= kMaxSnapCandidates) return;
  try {
    TopoDS_Vertex first, last;
    TopExp::Vertices(edge, first, last);
    if (!first.IsNull()) {
      const gp_Pnt p = BRep_Tool::Pnt(first);
      out.push_back({SnapKind::Vertex, {p.X(), p.Y(), p.Z()}});
    }
    if (!last.IsNull()) {
      const gp_Pnt p = BRep_Tool::Pnt(last);
      out.push_back({SnapKind::Vertex, {p.X(), p.Y(), p.Z()}});
    }

    BRepAdaptor_Curve curve(edge);
    const double mid =
        (curve.FirstParameter() + curve.LastParameter()) * 0.5;
    const gp_Pnt m = curve.Value(mid);
    out.push_back({SnapKind::EdgeMidpoint, {m.X(), m.Y(), m.Z()}});

    if (curve.GetType() == GeomAbs_Circle) {
      const gp_Pnt c = curve.Circle().Location();
      out.push_back({SnapKind::CircleCentre, {c.X(), c.Y(), c.Z()}});
    }
  } catch (const Standard_Failure&) {
  }
}

}  // namespace

std::vector<SnapCandidate> Document::snapCandidates(EntityKind kind,
                                                    std::uint32_t id) const {
  std::vector<SnapCandidate> out;
  if (kind == EntityKind::Edge) {
    if (id < m_impl->edgesById.size())
      appendEdgeCandidates(m_impl->edgesById[id], out);
    return out;
  }

  if (id >= m_impl->facesById.size()) return out;
  const TopoDS_Face& face = m_impl->facesById[id];
  if (face.IsNull()) return out;
  for (TopExp_Explorer e(face, TopAbs_EDGE); e.More(); e.Next()) {
    appendEdgeCandidates(TopoDS::Edge(e.Current()), out);
    if (out.size() >= kMaxSnapCandidates) break;
  }
  return out;
}

bool Document::projectPointOntoEdge(std::uint32_t edgeId,
                                    const std::array<double, 3>& approximate,
                                    std::array<double, 3>& outExact) const {
  outExact = approximate;
  if (edgeId >= m_impl->edgesById.size()) return false;
  const TopoDS_Edge& edge = m_impl->edgesById[edgeId];
  if (edge.IsNull()) return false;

  try {
    Standard_Real first = 0, last = 0;
    TopLoc_Location loc;
    Handle(Geom_Curve) curve = BRep_Tool::Curve(edge, loc, first, last);
    if (curve.IsNull()) return false;

    gp_Pnt query(approximate[0], approximate[1], approximate[2]);
    query.Transform(loc.Transformation().Inverted());
    GeomAPI_ProjectPointOnCurve projector(query, curve, first, last);
    if (projector.NbPoints() < 1) return false;
    gp_Pnt nearest = projector.NearestPoint();
    nearest.Transform(loc.Transformation());
    outExact = {nearest.X(), nearest.Y(), nearest.Z()};
    return true;
  } catch (const Standard_Failure&) {
    return false;
  }
}

}  // namespace cadcore

#include <BRepBuilderAPI_MakeVertex.hxx>

namespace cadcore {

MeasureResult Document::measure(const MeasureRef& a, const MeasureRef& b) const {
  MeasureResult result;

  auto asShape = [this](const MeasureRef& ref, TopoDS_Shape& shape) {
    if (ref.isPoint) {
      shape = BRepBuilderAPI_MakeVertex(
                  gp_Pnt(ref.point[0], ref.point[1], ref.point[2]))
                  .Vertex();
      return true;
    }
    if (ref.kind == EntityKind::Face) {
      if (ref.id >= m_impl->facesById.size()) return false;
      shape = m_impl->facesById[ref.id];
    } else {
      if (ref.id >= m_impl->edgesById.size()) return false;
      shape = m_impl->edgesById[ref.id];
    }
    return !shape.IsNull();
  };

  TopoDS_Shape shapeA, shapeB;
  if (!asShape(a, shapeA) || !asShape(b, shapeB)) return result;

  try {
    // Vertices make points first-class here, so the same exact solver covers
    // every combination instead of a special case per pair.
    BRepExtrema_DistShapeShape solver(shapeA, shapeB);
    if (!solver.IsDone() || solver.NbSolution() < 1) return result;
    result.distance = solver.Value();
    const gp_Pnt pa = solver.PointOnShape1(1);
    const gp_Pnt pb = solver.PointOnShape2(1);
    result.pointA = {pa.X(), pa.Y(), pa.Z()};
    result.pointB = {pb.X(), pb.Y(), pb.Z()};
    result.valid = true;
  } catch (const Standard_Failure&) {
  }
  return result;
}

}  // namespace cadcore

namespace cadcore {

Document::EdgeGroup Document::measureEdges(
    const std::vector<std::uint32_t>& edgeIds) const {
  EdgeGroup group;
  if (edgeIds.empty()) return group;

  // Endpoints are matched by position rather than by TopoDS identity, so edges
  // that meet across separate faces still count as connected.
  struct Node {
    gp_Pnt point;
    int degree = 0;
    int parent = 0;
  };
  std::vector<Node> nodes;
  const double tolerance = 1e-6;

  auto nodeFor = [&](const gp_Pnt& p) {
    for (std::size_t i = 0; i < nodes.size(); ++i)
      if (nodes[i].point.SquareDistance(p) < tolerance) return int(i);
    nodes.push_back({p, 0, int(nodes.size())});
    return int(nodes.size()) - 1;
  };
  std::function<int(int)> findRoot = [&](int i) {
    while (nodes[i].parent != i) {
      nodes[i].parent = nodes[nodes[i].parent].parent;
      i = nodes[i].parent;
    }
    return i;
  };

  for (std::uint32_t id : edgeIds) {
    if (id >= m_impl->edgesById.size()) continue;
    const TopoDS_Edge& edge = m_impl->edgesById[id];
    if (edge.IsNull()) continue;
    try {
      GProp_GProps props;
      BRepGProp::LinearProperties(edge, props);
      group.totalLength += props.Mass();
      group.count++;

      TopoDS_Vertex first, last;
      TopExp::Vertices(edge, first, last);
      if (first.IsNull() || last.IsNull()) continue;
      const int a = nodeFor(BRep_Tool::Pnt(first));
      const int b = nodeFor(BRep_Tool::Pnt(last));
      nodes[a].degree++;
      nodes[b].degree++;
      nodes[findRoot(a)].parent = findRoot(b);
    } catch (const Standard_Failure&) {
    }
  }
  group.valid = group.count > 0;
  if (!group.valid || nodes.empty()) return group;

  int components = 0;
  std::vector<int> freeEnds;
  for (std::size_t i = 0; i < nodes.size(); ++i) {
    if (findRoot(int(i)) == int(i)) components++;
    if (nodes[i].degree == 1) freeEnds.push_back(int(i));
    if (nodes[i].degree > 2) return group;  // a branch, not a chain
  }
  if (components != 1) return group;

  if (freeEnds.empty()) {
    group.connected = true;
    group.closed = true;
  } else if (freeEnds.size() == 2) {
    group.connected = true;
    group.endToEnd =
        nodes[freeEnds[0]].point.Distance(nodes[freeEnds[1]].point);
  }
  return group;
}

double Document::totalArea(const std::vector<std::uint32_t>& faceIds) const {
  double total = 0;
  for (std::uint32_t id : faceIds) {
    if (id >= m_impl->facesById.size()) continue;
    try {
      GProp_GProps props;
      BRepGProp::SurfaceProperties(m_impl->facesById[id], props);
      total += props.Mass();
    } catch (const Standard_Failure&) {
    }
  }
  return total;
}

}  // namespace cadcore
