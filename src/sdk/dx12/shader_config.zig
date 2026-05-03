const std = @import("std");
const w32 = @import("win32").everything;

pub const ShaderConfig = struct {
    source_code: [:0]const u8,
    use_geometry_shader: bool = false,
    primitive_topology: PrimitiveTopology = .triangle_list,
    depth: Depth = .{},
    stencil: ?Stencil = null,
    blend: Blend = .{},
    rasterizer: Rasterizer = .{},

    pub fn getNativeDepthStencil(self: *const ShaderConfig) w32.D3D12_DEPTH_STENCIL_DESC {
        var result: w32.D3D12_DEPTH_STENCIL_DESC = undefined;
        self.depth.toNative(&result);
        Stencil.optionalToNative(&self.stencil, &result);
        return result;
    }

    pub const PrimitiveTopology = enum {
        point_list,
        line_list,
        line_strip,
        triangle_list,
        triangle_strip,
        line_list_adj,
        line_strip_adj,
        triangle_list_adj,
        triangle_strip_adj,

        pub fn toNative(self: PrimitiveTopology) w32.D3D_PRIMITIVE_TOPOLOGY {
            return switch (self) {
                .point_list => ._PRIMITIVE_TOPOLOGY_POINTLIST,
                .line_list => ._PRIMITIVE_TOPOLOGY_LINELIST,
                .line_strip => ._PRIMITIVE_TOPOLOGY_LINESTRIP,
                .triangle_list => ._PRIMITIVE_TOPOLOGY_TRIANGLELIST,
                .triangle_strip => ._PRIMITIVE_TOPOLOGY_TRIANGLESTRIP,
                .line_list_adj => ._PRIMITIVE_TOPOLOGY_LINELIST_ADJ,
                .line_strip_adj => ._PRIMITIVE_TOPOLOGY_LINESTRIP_ADJ,
                .triangle_list_adj => ._PRIMITIVE_TOPOLOGY_TRIANGLELIST_ADJ,
                .triangle_strip_adj => ._PRIMITIVE_TOPOLOGY_TRIANGLESTRIP_ADJ,
            };
        }

        pub fn toNativeType(self: PrimitiveTopology) w32.D3D12_PRIMITIVE_TOPOLOGY_TYPE {
            return switch (self) {
                .point_list => .POINT,
                .line_list, .line_strip, .line_list_adj, .line_strip_adj => .LINE,
                .triangle_list, .triangle_strip, .triangle_list_adj, .triangle_strip_adj => .TRIANGLE,
            };
        }
    };

    pub const Depth = struct {
        enable_testing: bool = true,
        testing_function: ComparisonFunction = .greater_equal,
        enable_writing: bool = true,

        pub fn toNative(self: *const Depth, out: *w32.D3D12_DEPTH_STENCIL_DESC) void {
            out.DepthEnable = if (self.enable_testing) 1 else 0;
            out.DepthWriteMask = if (self.enable_writing) .ALL else .ZERO;
            out.DepthFunc = self.testing_function.toNative();
        }
    };

    pub const Stencil = struct {
        read_mask: u8 = 0xFF,
        write_mask: u8 = 0xFF,
        front_face: Face = .{},
        back_face: Face = .{},

        pub fn toNative(self: *const Stencil, out: *w32.D3D12_DEPTH_STENCIL_DESC) void {
            out.StencilEnable = 1;
            out.StencilReadMask = self.read_mask;
            out.StencilWriteMask = self.write_mask;
            out.FrontFace = self.front_face.toNative();
            out.BackFace = self.back_face.toNative();
        }

        pub fn optionalToNative(self_maybe: *const ?Stencil, out: *w32.D3D12_DEPTH_STENCIL_DESC) void {
            if (self_maybe.*) |*self| {
                self.toNative(out);
                out.StencilEnable = 1;
            } else {
                (Stencil{}).toNative(out);
                out.StencilEnable = 0;
            }
        }

        pub const Face = struct {
            stencil_fail_operation: Operation = .keep,
            stencil_pass_depth_fail_operation: Operation = .keep,
            stencil_pass_depth_pass_operation: Operation = .keep,
            function: ComparisonFunction = .always,

            pub fn toNative(self: *const Face) w32.D3D12_DEPTH_STENCILOP_DESC {
                return .{
                    .StencilFailOp = self.stencil_fail_operation.toNative(),
                    .StencilDepthFailOp = self.stencil_pass_depth_fail_operation.toNative(),
                    .StencilPassOp = self.stencil_pass_depth_pass_operation.toNative(),
                    .StencilFunc = self.function.toNative(),
                };
            }
        };

        pub const Operation = enum {
            keep,
            zero,
            replace,
            increment_sat,
            decrement_sat,
            invert,
            increment,
            decrement,

            pub fn toNative(self: Operation) w32.D3D12_STENCIL_OP {
                return switch (self) {
                    .keep => .KEEP,
                    .zero => .ZERO,
                    .replace => .REPLACE,
                    .increment_sat => .INCR_SAT,
                    .decrement_sat => .DECR_SAT,
                    .invert => .INVERT,
                    .increment => .INCR,
                    .decrement => .DECR,
                };
            }
        };
    };

    pub const Blend = struct {
        enable_alpha_to_coverage: bool = false,
        mode: Mode = .{ .shared = .{} },

        pub fn toNative(self: *const Blend) w32.D3D12_BLEND_DESC {
            return .{
                .AlphaToCoverageEnable = if (self.enable_alpha_to_coverage) 1 else 0,
                .IndependentBlendEnable = switch (self.mode) {
                    .shared => 0,
                    .independent => 1,
                },
                .RenderTarget = switch (self.mode) {
                    .shared => |*target| [1]w32.D3D12_RENDER_TARGET_BLEND_DESC{Target.optionalToNative(target)} ** 8,
                    .independent => |*targets| block: {
                        var result: [8]w32.D3D12_RENDER_TARGET_BLEND_DESC = undefined;
                        for (targets, &result) |*target, *element| {
                            element.* = Target.optionalToNative(target);
                        }
                        break :block result;
                    },
                },
            };
        }

        pub const Mode = union(enum) {
            shared: ?Target,
            independent: [8](?Target),
        };

        pub const Target = struct {
            src: Factor = .src_alpha,
            dest: Factor = .inv_src_alpha,
            op: Operation = .add,
            src_alpha: Factor = .inv_dest_alpha,
            dest_alpha: Factor = .one,
            op_alpha: Operation = .add,
            render_target_write_mask: Mask = .all,

            pub fn toNative(self: *const Target) w32.D3D12_RENDER_TARGET_BLEND_DESC {
                return .{
                    .BlendEnable = 1,
                    .LogicOpEnable = 0,
                    .SrcBlend = self.src.toNative(),
                    .DestBlend = self.dest.toNative(),
                    .BlendOp = self.op.toNative(),
                    .SrcBlendAlpha = self.src_alpha.toNative(),
                    .DestBlendAlpha = self.dest_alpha.toNative(),
                    .BlendOpAlpha = self.op_alpha.toNative(),
                    .LogicOp = .NOOP,
                    .RenderTargetWriteMask = self.render_target_write_mask.toNative(),
                };
            }

            pub fn optionalToNative(maybe_self: *const ?Target) w32.D3D12_RENDER_TARGET_BLEND_DESC {
                if (maybe_self.*) |*self| {
                    var result = self.toNative();
                    result.BlendEnable = 1;
                    return result;
                } else {
                    var result = (Target{}).toNative();
                    result.BlendEnable = 0;
                    return result;
                }
            }
        };

        pub const Factor = enum {
            zero,
            one,
            src_color,
            inv_src_color,
            src_alpha,
            inv_src_alpha,
            dest_alpha,
            inv_dest_alpha,
            dest_color,
            inv_dest_color,
            src_alpha_sat,
            blend_factor,
            inv_blend_factor,
            src1_color,
            inv_src1_color,
            src1_alpha,
            inv_src1_alpha,

            pub fn toNative(self: Factor) w32.D3D12_BLEND {
                return switch (self) {
                    .zero => .ZERO,
                    .one => .ONE,
                    .src_color => .SRC_COLOR,
                    .inv_src_color => .INV_SRC_COLOR,
                    .src_alpha => .SRC_ALPHA,
                    .inv_src_alpha => .INV_SRC_ALPHA,
                    .dest_alpha => .DEST_ALPHA,
                    .inv_dest_alpha => .INV_DEST_ALPHA,
                    .dest_color => .DEST_COLOR,
                    .inv_dest_color => .INV_DEST_COLOR,
                    .src_alpha_sat => .SRC_ALPHA_SAT,
                    .blend_factor => .BLEND_FACTOR,
                    .inv_blend_factor => .INV_BLEND_FACTOR,
                    .src1_color => .SRC1_COLOR,
                    .inv_src1_color => .INV_SRC1_COLOR,
                    .src1_alpha => .SRC1_ALPHA,
                    .inv_src1_alpha => .INV_SRC1_ALPHA,
                };
            }
        };

        pub const Operation = enum {
            add,
            subtract,
            rev_subtract,
            min,
            max,

            pub fn toNative(self: Operation) w32.D3D12_BLEND_OP {
                return switch (self) {
                    .add => .ADD,
                    .subtract => .SUBTRACT,
                    .rev_subtract => .REV_SUBTRACT,
                    .min => .MIN,
                    .max => .MAX,
                };
            }
        };

        pub const Mask = packed struct(u4) {
            red: u1 = 0,
            green: u1 = 0,
            blue: u1 = 0,
            alpha: u1 = 0,

            pub const all = Mask{ .red = 1, .green = 1, .blue = 1, .alpha = 1 };

            pub fn toNative(self: Mask) u8 {
                var result: u8 = 0;
                if (self.red == 1) result += @intFromEnum(w32.D3D12_COLOR_WRITE_ENABLE.RED);
                if (self.green == 1) result += @intFromEnum(w32.D3D12_COLOR_WRITE_ENABLE.GREEN);
                if (self.blue == 1) result += @intFromEnum(w32.D3D12_COLOR_WRITE_ENABLE.BLUE);
                if (self.alpha == 1) result += @intFromEnum(w32.D3D12_COLOR_WRITE_ENABLE.ALPHA);
                return result;
            }
        };
    };

    pub const Rasterizer = struct {
        fill_mode: FillMode = .solid,
        cull_mode: CullMode = .none,
        front_direction: Direction = .counter_clockwise,
        depth_bias: i32 = 0,
        depth_bias_clamp: f32 = 0,
        slope_scaled_depth_bias: f32 = 0,
        enable_depth_clipping: bool = true,
        enable_multisampling: bool = false,
        enable_line_antialiasing: bool = false,

        pub fn toNative(self: Rasterizer) w32.D3D12_RASTERIZER_DESC {
            return .{
                .FillMode = self.fill_mode.toNative(),
                .CullMode = self.cull_mode.toNative(),
                .FrontCounterClockwise = switch (self.front_direction) {
                    .clockwise => 0,
                    .counter_clockwise => 1,
                },
                .DepthBias = self.depth_bias,
                .DepthBiasClamp = self.depth_bias_clamp,
                .SlopeScaledDepthBias = self.slope_scaled_depth_bias,
                .DepthClipEnable = if (self.enable_depth_clipping) 1 else 0,
                .MultisampleEnable = if (self.enable_multisampling) 1 else 0,
                .AntialiasedLineEnable = if (self.enable_line_antialiasing) 1 else 0,
                .ForcedSampleCount = 0,
                .ConservativeRaster = .FF,
            };
        }

        pub const FillMode = enum {
            wireframe,
            solid,

            pub fn toNative(self: FillMode) w32.D3D12_FILL_MODE {
                return switch (self) {
                    .wireframe => .WIREFRAME,
                    .solid => .SOLID,
                };
            }
        };

        pub const CullMode = enum {
            none,
            front,
            back,

            pub fn toNative(self: CullMode) w32.D3D12_CULL_MODE {
                return switch (self) {
                    .none => .NONE,
                    .front => .FRONT,
                    .back => .BACK,
                };
            }
        };

        pub const Direction = enum {
            clockwise,
            counter_clockwise,
        };
    };

    pub const ComparisonFunction = enum {
        never,
        less,
        equal,
        less_equal,
        greater,
        not_equal,
        greater_equal,
        always,

        pub fn toNative(self: ComparisonFunction) w32.D3D12_COMPARISON_FUNC {
            return switch (self) {
                .never => .NEVER,
                .less => .LESS,
                .equal => .EQUAL,
                .less_equal => .LESS_EQUAL,
                .greater => .GREATER,
                .not_equal => .NOT_EQUAL,
                .greater_equal => .GREATER_EQUAL,
                .always => .ALWAYS,
            };
        }
    };
};
