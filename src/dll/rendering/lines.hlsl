struct Vertex {
	float3 start : start;
	float thickness : thickness;
	float3 end : end;
	float t : t;
	float4 color : color;
};

struct PixelInput {
	float4 position: SV_Position;
	float4 color : color;
	float2 screen_position : screen_position;
	float2 screen_start : screen_start;
	float2 screen_end : screen_end;
	float half_thickness : half_thickness;
	float screen_to_depth : screen_to_depth;
};

struct PixelOutput {
	float4 color : SV_Target;
	float depth : SV_Depth;
};

cbuffer Constants : register(b0) {
	float4x4 world_to_clip;
	float4x4 clip_to_world;
	float2 viewport_size;
	float anti_aliasing;
}

float2 safeNormalize(float2 the_vector);
float pointLineDistance(float2 the_point, float2 line_start, float2 line_end);

PixelInput vs_main(Vertex vertex) {
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
	float4 position = mul(float4(world_position, 1.0), world_to_clip);
	position.xy += clip_offset * position.w;
	float3 clip_position = position.xyz / position.w;

	float screen_to_clip = 2.0 / viewport_size.x;
	float4 right_offset_world_position = mul(float4(clip_position + float3(screen_to_clip, 0, 0), 1), clip_to_world);
	right_offset_world_position /= right_offset_world_position.w;
	float screen_to_world = length(right_offset_world_position.xyz - world_position);
	float4 forward_offset_world_position = mul(float4(clip_position + float3(0, 0, 1), 1), clip_to_world);
	forward_offset_world_position /= forward_offset_world_position.w;
	float3 forward_world_direction = normalize(forward_offset_world_position.xyz - world_position);
	float3 depth_offset_world_position = world_position + (screen_to_world * forward_world_direction);
	float4 depth_offset_clip_position = mul(float4(depth_offset_world_position, 1), world_to_clip);
	depth_offset_clip_position /= depth_offset_clip_position.w;
	float screen_to_depth = depth_offset_clip_position.z - clip_position.z;

	PixelInput pixel;
	pixel.position = position;
	pixel.color = vertex.color;
	pixel.screen_position = clip_position.xy * 0.5 * viewport_size;
	pixel.screen_start = screen_start;
	pixel.screen_end = screen_end;
	pixel.half_thickness = abs_half_thickness;
	pixel.screen_to_depth = screen_to_depth;
	return pixel;
}

PixelOutput ps_main(PixelInput input) {
	float distance = pointLineDistance(input.screen_position, input.screen_start, input.screen_end);
	if (distance > input.half_thickness) {
	    discard;
	}
	float alpha = 1.0 - smoothstep(input.half_thickness - anti_aliasing, input.half_thickness, distance);
	float screen_depth = sqrt((input.half_thickness * input.half_thickness) - (distance * distance));

	PixelOutput output;
	output.color = float4(input.color.rgb, input.color.a * alpha);
	output.depth = input.position.z + (input.screen_to_depth * screen_depth);
	return output;
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
