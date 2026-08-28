#include <metal_stdlib>
#include "ShaderTypes.h"

#ifdef __RUNTIME_COMPILE__
#define CUBE_FACE_FLAG 0x40000000u
#define ENTITY_EDGE_FLAG 0x80000000u
#define ENTITY_INDEX_MASK 0x7FFFFFFFu
#define EDGE_PICK_RADIUS 5
typedef struct {
  float4x4 modelViewProjection;
  float4 lightDirection;
  float4 baseColor;
  float4 backgroundTop;
  float4 backgroundBottom;
  float4x4 cubeOrientation;
  float4 cubePlacement;
  float4 markerColor;
  float4 viewport;
  uint selectedEntityId;
  uint hoverEntityId;
  uint shadingMode;
  uint pad0;
} Uniforms;
#endif
using namespace metal;

// Matches cadcore::RenderVertex byte-for-byte.
struct RenderVertex {
  packed_float3 position;
  packed_float3 normal;
  uint faceId;
};

struct ShadedOut {
  float4 clipPosition [[position]];
  float3 worldNormal;
  uint faceId;
  uint selected [[flat]];
};

struct FragmentOut {
  float4 color [[color(0)]];
  uint faceId [[color(1)]];  // identity buffer -> pixel-exact picking
};

// --- background -------------------------------------------------------------
// Fullscreen triangle, no vertex buffer. A soft vertical gradient reads as
// depth without competing with the model.

struct BackgroundOut {
  float4 clipPosition [[position]];
  float2 uv;
};

vertex BackgroundOut vsBackground(uint vid [[vertex_id]]) {
  const float2 corners[3] = {float2(-1, -3), float2(-1, 1), float2(3, 1)};
  BackgroundOut out;
  out.clipPosition = float4(corners[vid], 1.0, 1.0);  // z=1 -> far plane
  out.uv = corners[vid] * 0.5 + 0.5;
  return out;
}

fragment FragmentOut fsBackground(BackgroundOut in [[stage_in]],
                                  constant Uniforms& u [[buffer(1)]]) {
  FragmentOut out;
  out.color = float4(mix(u.backgroundBottom.rgb, u.backgroundTop.rgb, in.uv.y), 1.0);
  out.faceId = FACE_ID_NONE;
  return out;
}

// --- shaded surfaces --------------------------------------------------------

vertex ShadedOut vsShaded(uint vid [[vertex_id]],
                          const device RenderVertex* vertices [[buffer(0)]],
                          constant Uniforms& u [[buffer(1)]],
                          const device uint* faceSelected [[buffer(2)]]) {
  const RenderVertex v = vertices[vid];
  ShadedOut out;
  out.selected = faceSelected[v.faceId];
  out.clipPosition = u.modelViewProjection * float4(v.position, 1.0);
  out.worldNormal = float3(v.normal);  // model transform is identity
  out.faceId = v.faceId;
  return out;
}

fragment FragmentOut fsShaded(ShadedOut in [[stage_in]],
                              constant Uniforms& u [[buffer(1)]],
                              bool frontFacing [[front_facing]]) {
  float3 n = normalize(in.worldNormal);
  if (!frontFacing) n = -n;  // back faces of open shells still shade sanely

  // Hemispheric fill plus one key light: matte, even, no specular hotspots
  // fighting the edges. This is what makes it read as CAD and not a game.
  const float3 sky = float3(0.62, 0.67, 0.74);
  const float3 ground = float3(0.20, 0.19, 0.18);
  const float hemi = n.z * 0.5 + 0.5;
  const float3 ambient = mix(ground, sky, hemi);

  const float key = saturate(dot(n, normalize(u.lightDirection.xyz)));
  const float3 lit = u.baseColor.rgb * (ambient * 0.55 + key * 0.75);

  // Wireframe: paint surfaces in the background gradient so they still occlude
  // the edges behind them, which is what makes hidden-line removal work.
  if (u.shadingMode == 2u) {
    const float t = 1.0 - in.clipPosition.y / max(u.viewport.y, 1.0);
    FragmentOut wire;
    wire.color = float4(mix(u.backgroundBottom.rgb, u.backgroundTop.rgb, t), 1.0);
    wire.faceId = in.faceId;
    return wire;
  }

  float3 color = lit;
  if (in.selected != 0u)
    color = mix(color, float3(1.00, 0.58, 0.16), 0.72);
  else if (in.faceId == u.hoverEntityId)
    color = mix(color, float3(0.42, 0.72, 1.00), 0.35);

  FragmentOut out;
  out.color = float4(color, 1.0);
  out.faceId = in.faceId;
  return out;
}

// --- feature edges ----------------------------------------------------------

struct EdgeOut {
  float4 clipPosition [[position]];
  uint edgeId [[flat]];
  uint selected [[flat]];
};

// Metal rasterizes lines at exactly one pixel, which reads as thin and washed
// out. Each segment is expanded into a screen-space quad instead, so edge
// weight is controllable and consistent on Retina.
//
// No depth offset here on purpose: the shaded pass biases surfaces away, which
// is slope-aware and keeps curved-face rims intact. Offsetting the edges
// themselves breaks those rims into arcs.
vertex EdgeOut vsEdge(uint vid [[vertex_id]],
                      const device packed_float3* positions [[buffer(0)]],
                      constant Uniforms& u [[buffer(1)]],
                      const device uint* segments [[buffer(2)]],
                      const device uint* segmentEdgeIds [[buffer(3)]],
                      const device uint* edgeSelected [[buffer(4)]]) {
  const uint seg = vid / 6u, corner = vid % 6u;
  const float4 c0 = u.modelViewProjection * float4(positions[segments[seg * 2u]], 1.0);
  const float4 c1 = u.modelViewProjection * float4(positions[segments[seg * 2u + 1u]], 1.0);

  // NDC spans 2.0, so half the drawable size converts NDC to pixels.
  const float2 px = u.viewport.xy * 0.5;
  const float2 s0 = c0.xy / max(c0.w, 1e-6) * px;
  const float2 s1 = c1.xy / max(c1.w, 1e-6) * px;

  float2 dir = s1 - s0;
  dir = length(dir) > 1e-6 ? normalize(dir) : float2(1.0, 0.0);
  const float2 normal = float2(-dir.y, dir.x) * u.viewport.z;

  // 0,1,2 / 3,4,5 -> two triangles covering the segment
  const bool atEnd = (corner == 2u || corner == 3u || corner == 5u);
  const bool positive = (corner == 1u || corner == 4u || corner == 5u);

  const float4 base = atEnd ? c1 : c0;
  const float2 offset = (positive ? normal : -normal) / px;

  EdgeOut out;
  out.clipPosition = float4(base.xy + offset * base.w, base.z, base.w);
  const uint edgeIndex = segmentEdgeIds[seg];
  out.edgeId = edgeIndex | ENTITY_EDGE_FLAG;
  out.selected = edgeSelected[edgeIndex];
  return out;
}

fragment FragmentOut fsEdge(EdgeOut in [[stage_in]],
                            constant Uniforms& u [[buffer(1)]]) {
  FragmentOut out;
  // In wireframe the edges sit on the background rather than on a lit surface,
  // so they have to contrast with it: dark ink on a light ground, light ink on
  // a dark one. This keeps every background preset readable.
  const float groundLuma =
      dot(u.backgroundBottom.rgb, float3(0.299, 0.587, 0.114));
  const float3 ink = (u.shadingMode == 2u && groundLuma < 0.35)
                         ? float3(0.86, 0.89, 0.93)
                         : float3(0.10, 0.11, 0.13);

  // Same highlight language as faces: amber selected, blue hovered. Edges are
  // thin, so they take the colour at full strength rather than a tint.
  if (in.selected != 0u)
    out.color = float4(1.00, 0.58, 0.16, 1.0);
  else if (in.edgeId == u.hoverEntityId)
    out.color = float4(0.30, 0.66, 1.00, 1.0);
  else
    out.color = float4(ink, 1.0);
  out.faceId = in.edgeId;
  return out;
}

// --- pick resolve ------------------------------------------------------------
// Integer formats cannot be multisample-resolved (resolve averages, which is
// meaningless for IDs), so the identity buffer stays multisampled and one texel
// is resolved on demand. Samples are scanned in order and the first real face
// wins, so clicking near an antialiased edge still selects the face under it
// rather than the edge's FACE_ID_NONE.

vertex float4 vsPickResolve(uint vid [[vertex_id]]) {
  const float2 corners[3] = {float2(-1, -3), float2(-1, 1), float2(3, 1)};
  return float4(corners[vid], 0.0, 1.0);
}

// Depth rides along with the face id so one resolve gives both what was hit and
// where it is in space - the pivot for cursor-centred orbit and zoom.
struct PickResolveOut {
  uint faceId [[color(0)]];
  float depth [[color(1)]];
};

fragment PickResolveOut fsPickResolve(texture2d_ms<uint> identity [[texture(0)]],
                                      depth2d_ms<float> depths [[texture(1)]],
                                      constant uint2& coord [[buffer(0)]]) {
  PickResolveOut out;
  out.faceId = FACE_ID_NONE;
  out.depth = depths.read(coord, 0);

  const uint samples = identity.get_num_samples();
  const int width = int(identity.get_width());
  const int height = int(identity.get_height());

  // An edge anywhere inside the tolerance beats the face under the cursor,
  // because a 2 px line is otherwise almost impossible to click. Nearest edge
  // wins so adjacent edges stay separable.
  int bestEdgeDistance = (EDGE_PICK_RADIUS + 1) * (EDGE_PICK_RADIUS + 1);
  bool foundEdge = false;

  for (int dy = -EDGE_PICK_RADIUS; dy <= EDGE_PICK_RADIUS; ++dy) {
    for (int dx = -EDGE_PICK_RADIUS; dx <= EDGE_PICK_RADIUS; ++dx) {
      const int px = int(coord.x) + dx, py = int(coord.y) + dy;
      if (px < 0 || py < 0 || px >= width || py >= height) continue;
      const int distance = dx * dx + dy * dy;
      if (distance >= bestEdgeDistance) continue;
      const uint2 at = uint2(uint(px), uint(py));
      for (uint s = 0; s < samples; ++s) {
        const uint id = identity.read(at, s).r;
        if (id != FACE_ID_NONE && (id & ENTITY_EDGE_FLAG) != 0u) {
          bestEdgeDistance = distance;
          foundEdge = true;
          out.faceId = id;
          out.depth = depths.read(at, s);
          break;
        }
      }
    }
  }
  if (foundEdge) return out;

  for (uint s = 0; s < samples; ++s) {
    const uint id = identity.read(coord, s).r;
    if (id != FACE_ID_NONE) {
      out.faceId = id;
      out.depth = depths.read(coord, s);
      return out;
    }
  }
  return out;
}

// --- measurement point markers ----------------------------------------------
// Screen-space squares at placed points, drawn without depth testing so a point
// on the far side of the part is still visible while you measure.

struct MarkerOut {
  float4 clipPosition [[position]];
};

vertex MarkerOut vsMarker(uint vid [[vertex_id]],
                          const device packed_float3* points [[buffer(0)]],
                          constant Uniforms& u [[buffer(1)]]) {
  const uint index = vid / 6u, corner = vid % 6u;
  const float2 corners[6] = {float2(-1, -1), float2(1, -1), float2(-1, 1),
                             float2(-1, 1),  float2(1, -1), float2(1, 1)};
  float4 clip = u.modelViewProjection * float4(points[index], 1.0);
  const float2 halfPixels = u.viewport.xy * 0.5;
  clip.xy += corners[corner] * u.viewport.w / halfPixels * clip.w;
  MarkerOut out;
  out.clipPosition = clip;
  return out;
}

fragment FragmentOut fsMarker(constant Uniforms& u [[buffer(1)]]) {
  FragmentOut out;
  out.color = u.markerColor;
  out.faceId = FACE_ID_NONE;  // markers are not pickable
  return out;
}

// --- measurement line --------------------------------------------------------
// The segment between two placed points, expanded to a screen-space quad so it
// keeps a constant weight, and drawn without depth so it reads as an annotation
// rather than geometry.

vertex MarkerOut vsMeasureLine(uint vid [[vertex_id]],
                               const device packed_float3* points [[buffer(0)]],
                               constant Uniforms& u [[buffer(1)]]) {
  const uint corner = vid % 6u;
  float4 c0 = u.modelViewProjection * float4(points[0], 1.0);
  float4 c1 = u.modelViewProjection * float4(points[1], 1.0);

  const float2 halfPixels = u.viewport.xy * 0.5;
  const float2 s0 = c0.xy / max(c0.w, 1e-6) * halfPixels;
  const float2 s1 = c1.xy / max(c1.w, 1e-6) * halfPixels;
  float2 dir = s1 - s0;
  dir = length(dir) > 1e-6 ? normalize(dir) : float2(1.0, 0.0);
  const float2 normal = float2(-dir.y, dir.x) * 1.6;

  const bool atEnd = (corner == 2u || corner == 3u || corner == 5u);
  const bool positive = (corner == 1u || corner == 4u || corner == 5u);
  const float4 base = atEnd ? c1 : c0;
  const float2 offset = (positive ? normal : -normal) / halfPixels;

  MarkerOut out;
  out.clipPosition = float4(base.xy + offset * base.w, base.z, base.w);
  return out;
}

// --- view cube ---------------------------------------------------------------
// A small orientation widget in the corner. It shares the identity buffer with
// the model, so clicking a face is resolved by the same pick pass; the ids just
// carry CUBE_FACE_FLAG.

struct CubeVertex {
  packed_float3 position;
  packed_float3 normal;
  packed_float2 uv;
  uint face;
};

struct CubeOut {
  float4 clipPosition [[position]];
  float3 normal;
  float2 uv;
  uint face [[flat]];
};

vertex CubeOut vsCube(uint vid [[vertex_id]],
                      const device CubeVertex* vertices [[buffer(0)]],
                      constant Uniforms& u [[buffer(1)]]) {
  const CubeVertex v = vertices[vid];
  const float3 rotated =
      (u.cubeOrientation * float4(float3(v.position), 0.0)).xyz;
  const float3 normal =
      (u.cubeOrientation * float4(float3(v.normal), 0.0)).xyz;

  CubeOut out;
  // Orthographic, placed by pixel size so the cube stays square whatever the
  // window aspect. Depth is squeezed into a sliver at the very front so the
  // cube sits above the model and still self-occludes correctly.
  out.clipPosition = float4(u.cubePlacement.xy + rotated.xy * u.cubePlacement.zw,
                            0.01 - rotated.z * 0.004, 1.0);
  out.normal = normal;
  out.uv = float2(v.uv);
  out.face = v.face;
  return out;
}

fragment FragmentOut fsCube(CubeOut in [[stage_in]],
                            constant Uniforms& u [[buffer(1)]],
                            texture2d<float> labels [[texture(0)]],
                            sampler labelSampler [[sampler(0)]]) {
  const uint id = in.face | CUBE_FACE_FLAG;
  const float3 n = normalize(in.normal);
  const float shade = 0.55 + 0.45 * saturate(n.z * 0.5 + 0.5);

  float3 base = float3(0.82, 0.84, 0.88) * shade;
  if (id == u.hoverEntityId) base = mix(base, float3(0.30, 0.66, 1.00), 0.55);

  // The atlas holds white glyphs on transparent; composite them as ink.
  const float ink = labels.sample(labelSampler, in.uv).a;
  const float3 colour = mix(base, float3(0.12, 0.13, 0.16), ink);

  FragmentOut out;
  out.color = float4(colour, 1.0);
  out.faceId = id;
  return out;
}
