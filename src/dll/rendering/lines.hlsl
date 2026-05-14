struct Vertex {
	float3 start : start;
	float thickness : thickness;
	float3 end : end;
	float t : t;
	float4 color : color;
};

struct Pixel {
	float4 position: SV_POSITION;
	float4 color : COLOR;
	float2 screen_position : SCREEN_POSITION;
	float2 screen_start : SCREEN_START;
	float2 screen_end : SCREEN_END;
	float half_thickness : RADIUS;
};

cbuffer Constants : register(b0) {
	float4x4 world_to_clip;
	float2 viewport_size;
	float anti_aliasing;
}

float2 safeNormalize(float2 the_vector);
float pointLineDistance(float2 the_point, float2 line_start, float2 line_end);

Pixel vs_main(Vertex vertex) {
	float half_thickness = 0.5 * (vertex.thickness + (sign(vertex.thickness) * anti_aliasing));
	float abs_half_thickness = abs(half_thickness);

	float4 clip_start = mul(float4(vertex.start, 1.0), world_to_clip);
	float4 clip_end = mul(float4(vertex.end, 1.0), world_to_clip);

	float2 screen_start = (clip_start.xy / clip_start.w) * 0.5 * viewport_size;
	float2 screen_end = (clip_end.xy / clip_end.w) * 0.5 * viewport_size;
	float2 screen_direction = safeNormalize(screen_end - screen_start);
	float2 screen_normal = float2(-screen_direction.y, screen_direction.x);

	float2 direction_screen_offset = sign(vertex.t - 0.5) * abs_half_thickness * screen_direction;
	float2 normal_screen_offset = half_thickness * screen_normal;
	float2 screen_offset = direction_screen_offset + normal_screen_offset;
	float2 clip_offset = 2 * screen_offset / viewport_size;

	float3 world_position = lerp(vertex.start, vertex.end, vertex.t);
	float4 clip_position = mul(float4(world_position, 1.0), world_to_clip);
	clip_position.xy += clip_offset * clip_position.w;

	Pixel pixel;
	pixel.position = clip_position;
	pixel.color = vertex.color;
	pixel.screen_position = (clip_position.xy / clip_position.w) * 0.5 * viewport_size;
	pixel.screen_start = screen_start;
	pixel.screen_end = screen_end;
	pixel.half_thickness = abs_half_thickness;
	return pixel;
}

float4 ps_main(Pixel pixel) : SV_TARGET {
	float distance = pointLineDistance(pixel.screen_position, pixel.screen_start, pixel.screen_end);
	float alpha = 1.0 - smoothstep(pixel.half_thickness - anti_aliasing, pixel.half_thickness, distance);
	return float4(pixel.color.rgb, pixel.color.a * alpha);
}

float2 safeNormalize(float2 the_vector) {
    float length_squared = dot(the_vector, the_vector);
    return (length_squared >= 1e-8) ? (the_vector * rsqrt(length_squared)) : float2(1, 0);
}

float pointLineDistance(float2 the_point, float2 line_start, float2 line_end) {
	float2 start_end = line_end - line_start;
	float2 start_point = the_point - line_start;
	float length_squared = dot(start_end, start_end);
	if (length_squared <= 1e-6) {
		return length(start_point);
	}
	float t = saturate(dot(start_point, start_end) / length_squared);
	float2 closest = line_start + t * start_end;
	return length(the_point - closest);
}
