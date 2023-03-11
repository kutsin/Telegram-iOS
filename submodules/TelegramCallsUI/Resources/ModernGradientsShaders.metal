//
//  generateGradient.metal
//  Test
//
//  Created by Mr. Kutsin on 27.02.2023.
//

#include <metal_stdlib>

using namespace metal;

typedef struct {
    float4 position [[position]];
    float2 texCoord;
} ColorInOut;

typedef struct {
    int frameIndex;
    float4x2 positions;
    float4x3 colors;
} FragmentIn;

constant float2 positions[8] {
    { 0.80f, 0.10f },
    { 0.60f, 0.20f },
    { 0.35f, 0.25f },
    { 0.25f, 0.60f },
    { 0.20f, 0.90f },
    { 0.40f, 0.80f },
    { 0.65f, 0.75f },
    { 0.75f, 0.40f }
};

constant int duration = 8;
constant int maxFrame = 480;
constant int framesPerSecond = 60;

vertex ColorInOut gradientVertex(unsigned int vid [[ vertex_id ]]) {
    constexpr float2 verts[] = {
        float2(0, 0),
        float2(0, 1),
        float2(1, 0),
        float2(1, 1)
    };
    
    float2 cur_point = verts[vid];
    float2 pos = cur_point * 2 - 1;
    pos.y = -pos.y;
    
    ColorInOut out;
    
    out.position = float4(pos, 0, 1);
    out.texCoord = cur_point;
    
    return out;
}

float interpolateFloat(float value1, float value2, float factor) {
    return value1 * (1.0 - factor) + value2 * factor;
}

float2 interpolatePoints(float2 point1, float2 point2, float factor) {
    return { interpolateFloat(point1.x, point2.x, factor), interpolateFloat(point1.y, point2.y, factor) };
}

fragment float4 gradientFragment(ColorInOut in [[stage_in]],
                              constant FragmentIn &fragmentIn [[buffer(0)]])
{
    
    float2 dist = in.texCoord - 0.5;
    float centerDistance = sqrt(dist.x * dist.x + dist.y * dist.y);
    
    float swirlFactor = 0.35 * centerDistance;
    float theta = swirlFactor * swirlFactor * 0.8 * 8.0;
    float sinTheta = sin(theta);
    float cosTheta = cos(theta);
    
    float pixelX = max(0.0, min(1.0, 0.5 + dist.x * cosTheta - dist.y * sinTheta));
    float pixelY = max(0.0, min(1.0, 0.5 + dist.x * sinTheta + dist.y * cosTheta));
    
    float distanceSum = 0;
    
    float3 rgb = 0;
    
    for (int i = 0; i < 4; i++) {
        float colorX = fragmentIn.positions.columns[i].x;
        float colorY = fragmentIn.positions.columns[i].y;
        
        float distanceX = pixelX - colorX;
        float distanceY = pixelY - colorY;
        
        float distance = max(0.0, 0.92 - sqrt(distanceX * distanceX + distanceY * distanceY));
        distance = distance * distance * distance;
        distanceSum += distance;
        
        float r = rgb.r + distance * fragmentIn.colors.columns[i].r;
        float g = rgb.g + distance * fragmentIn.colors.columns[i].g;
        float b = rgb.b + distance * fragmentIn.colors.columns[i].b;
        
        rgb = { r, g, b };
    }
    
    if (distanceSum < 0.00001) {
        distanceSum = 0.00001;
    }
    
    float pixelB = rgb.b / distanceSum;
    float pixelG = rgb.g / distanceSum;
    float pixelR = rgb.r / distanceSum;

    float4 res = float4(pixelR, pixelG, pixelB, 1.0);
    
    return res;
}
