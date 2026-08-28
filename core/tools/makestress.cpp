// Builds an N-part assembly to test the load/tessellate path at scale.
#include <BRepAlgoAPI_Cut.hxx>
#include <BRepPrimAPI_MakeBox.hxx>
#include <BRepPrimAPI_MakeCylinder.hxx>
#include <BRepBuilderAPI_Transform.hxx>
#include <DE_Wrapper.hxx>
#include <TDocStd_Document.hxx>
#include <XCAFApp_Application.hxx>
#include <XCAFDoc_DocumentTool.hxx>
#include <XCAFDoc_ShapeTool.hxx>
#include <TDF_Label.hxx>
#include <gp_Trsf.hxx>
#include <cstdio>
#include <cstdlib>

int main(int argc, char** argv) {
  const int n = argc > 1 ? std::atoi(argv[1]) : 200;
  const std::string out = argc > 2 ? argv[2] : "samples/assembly.step";

  // One reasonably detailed part: a plate with 8 holes.
  TopoDS_Shape part = BRepPrimAPI_MakeBox(40.0, 30.0, 6.0).Shape();
  for (int i = 0; i < 8; ++i) {
    const double x = 5.0 + (i % 4) * 10.0, y = 8.0 + (i / 4) * 14.0;
    TopoDS_Shape drill = BRepPrimAPI_MakeCylinder(
        gp_Ax2(gp_Pnt(x, y, -1), gp_Dir(0, 0, 1)), 2.0, 8.0).Shape();
    part = BRepAlgoAPI_Cut(part, drill).Shape();
  }

  Handle(TDocStd_Document) doc;
  XCAFApp_Application::GetApplication()->NewDocument("BinXCAF", doc);
  Handle(XCAFDoc_ShapeTool) st = XCAFDoc_DocumentTool::ShapeTool(doc->Main());

  TDF_Label protoLabel = st->AddShape(part, Standard_False);
  TDF_Label asmLabel = st->NewShape();
  const int cols = 20;
  for (int i = 0; i < n; ++i) {
    gp_Trsf t;
    t.SetTranslation(gp_Vec((i % cols) * 50.0, (i / cols) * 40.0, 0));
    st->AddComponent(asmLabel, protoLabel, TopLoc_Location(t));
  }
  st->UpdateAssemblies();

  DE_Wrapper::GlobalWrapper()->Write(TCollection_AsciiString(out.c_str()), doc);
  std::printf("wrote %s with %d instances\n", out.c_str(), n);
  return 0;
}
