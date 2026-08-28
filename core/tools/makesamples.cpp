// Builds a plate with holes of known diameters and exports it to every format
// we claim to read. Known dimensions let us verify measurement is exact.

#include <BRepAlgoAPI_Cut.hxx>
#include <BRepAlgoAPI_Fuse.hxx>
#include <BRepPrimAPI_MakeBox.hxx>
#include <BRepPrimAPI_MakeCylinder.hxx>
#include <BRepMesh_IncrementalMesh.hxx>
#include <DE_Wrapper.hxx>
#include <TDocStd_Document.hxx>
#include <XCAFApp_Application.hxx>
#include <XCAFDoc_DocumentTool.hxx>
#include <XCAFDoc_ShapeTool.hxx>
#include <gp_Ax2.hxx>
#include <cstdio>

// Plate 100 x 60 x 10 mm, four through-holes of these diameters:
static const double kHoles[4][3] = {
    // x,     y,    diameter
    {15.0, 15.0, 12.0},
    {85.0, 15.0, 8.0},
    {15.0, 45.0, 6.0},
    {85.0, 45.0, 5.0},
};

int main(int argc, char** argv) {
  const std::string outDir = argc > 1 ? argv[1] : "samples";

  TopoDS_Shape plate = BRepPrimAPI_MakeBox(100.0, 60.0, 10.0).Shape();
  for (const auto& h : kHoles) {
    TopoDS_Shape drill = BRepPrimAPI_MakeCylinder(
        gp_Ax2(gp_Pnt(h[0], h[1], -1.0), gp_Dir(0, 0, 1)), h[2] / 2.0, 12.0).Shape();
    plate = BRepAlgoAPI_Cut(plate, drill).Shape();
  }

  Handle(TDocStd_Document) doc;
  XCAFApp_Application::GetApplication()->NewDocument("BinXCAF", doc);
  XCAFDoc_DocumentTool::ShapeTool(doc->Main())->AddShape(plate);

  // Mesh formats need a triangulation present before export.
  BRepMesh_IncrementalMesh(plate, 0.05, Standard_False, 0.35, Standard_True);

  Handle(DE_Wrapper) de = DE_Wrapper::GlobalWrapper();
  const char* exts[] = {"step", "iges", "brep", "stl", "obj", "glb", "ply"};
  for (const char* ext : exts) {
    const std::string path = outDir + "/plate." + ext;
    bool ok = false;
    try {
      ok = de->Write(TCollection_AsciiString(path.c_str()), doc);
    } catch (const Standard_Failure& e) {
      std::printf("  %-5s write threw: %s\n", ext, e.GetMessageString());
      continue;
    }
    std::printf("  %-5s %s\n", ext, ok ? "written" : "NOT SUPPORTED for write");
  }
  // A long, thin part: the shape that exposes framing bugs, because fitting a
  // bounding sphere wastes the whole width while still clipping the length.
  TopoDS_Shape column =
      BRepPrimAPI_MakeCylinder(gp_Ax2(gp_Pnt(0, 0, 0), gp_Dir(0, 0, 1)), 20.0,
                               600.0)
          .Shape();
  for (int i = 0; i < 5; ++i) {
    const double z = 60.0 + i * 110.0;
    TopoDS_Shape boss = BRepPrimAPI_MakeCylinder(
        gp_Ax2(gp_Pnt(0, 0, z), gp_Dir(1, 0, 0)), 14.0, 45.0).Shape();
    column = BRepAlgoAPI_Fuse(column, boss).Shape();
  }
  Handle(TDocStd_Document) columnDoc;
  XCAFApp_Application::GetApplication()->NewDocument("BinXCAF", columnDoc);
  XCAFDoc_DocumentTool::ShapeTool(columnDoc->Main())->AddShape(column);
  BRepMesh_IncrementalMesh(column, 0.4, Standard_False, 0.35, Standard_True);
  de->Write(TCollection_AsciiString((outDir + "/column.step").c_str()), columnDoc);
  std::printf("  column.step written (40 dia x 600 long, 5 bosses)\n");

  std::printf("\nplate is 100 x 60 x 10 mm with holes d=12, 8, 6, 5 mm\n");
  return 0;
}
