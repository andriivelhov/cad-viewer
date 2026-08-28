// Shared between Objective-C++ and Metal. Only float4x4/float4/uint are used:
// float3 and float3x3 pack differently on each side and silently corrupt the
// fields that follow them.
#pragma once
#include <simd/simd.h>

#define FACE_ID_NONE 0xFFFFFFFFu
// Edges share the identity buffer with faces; the top bit says which.
#define ENTITY_EDGE_FLAG 0x80000000u
#define ENTITY_INDEX_MASK 0x7FFFFFFFu
// Edges are ~2 px wide, so a click needs a tolerance to be hittable at all.
#define EDGE_PICK_RADIUS 5

typedef struct {
  simd_float4x4 modelViewProjection;
  simd_float4 lightDirection;  // xyz used
  simd_float4 baseColor;       // rgb used
  simd_float4 backgroundTop;
  simd_float4 backgroundBottom;
  simd_float4 markerColor;
  simd_float4 viewport;        // x,y = drawable px; z = edge half-width; w = marker half-size
  unsigned int selectedEntityId;
  unsigned int hoverEntityId;
  unsigned int pad0;
  unsigned int pad1;
} Uniforms;
