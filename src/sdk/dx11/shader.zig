const std = @import("std");
const builtin = @import("builtin");
const w32 = @import("win32").everything;
const misc = @import("../misc/root.zig");
const math = @import("../math/root.zig");
const dx11 = @import("root.zig");

pub fn Shader(Vertex: type, Index: type, Constants: type) type {
    return struct {
        primitive_topology: w32.D3D_PRIMITIVE_TOPOLOGY,
        vertex_shader: *w32.ID3D11VertexShader,
        geometry_shader: ?*w32.ID3D11GeometryShader,
        pixel_shader: *w32.ID3D11PixelShader,
        input_layout: *w32.ID3D11InputLayout,
        depth_stencil_state: *w32.ID3D11DepthStencilState,
        blend_state: *w32.ID3D11BlendState,
        rasterizer_state: *w32.ID3D11RasterizerState,
        vertex_buffer: ?Buffer,
        index_buffer: ?Buffer,
        constant_buffer: ?Buffer,
        vertex_count: u32,
        index_count: u32,
        test_allocation: if (builtin.is_test) *u8 else void,

        const Self = @This();
        const Buffer = struct {
            handle: *w32.ID3D11Buffer,
            size: u32,
        };

        pub fn init(context: *const dx11.Context, config: *const dx11.ShaderConfig) !Self {
            const device = context.device;

            const vertex_blob = compile(config.source_code, "vs_main", "vs_4_0") catch |err| {
                misc.error_context.append("Failed to compile vertex_shader.", .{});
                return err;
            };
            defer _ = vertex_blob.IUnknown.Release();

            const pixel_blob = compile(config.source_code, "ps_main", "ps_4_0") catch |err| {
                misc.error_context.append("Failed to compile.", .{});
                return err;
            };
            defer _ = pixel_blob.IUnknown.Release();

            const geometry_blob = switch (config.use_geometry_shader) {
                true => compile(config.source_code, "gs_main", "gs_4_0") catch |err| {
                    misc.error_context.append("Failed to compile.", .{});
                    return err;
                },
                false => null,
            };
            defer if (geometry_blob) |blob| {
                _ = blob.IUnknown.Release();
            };

            checkConstantsLayout(Constants, vertex_blob) catch |err| {
                misc.error_context.append("Constants layout check failed.", .{});
                return err;
            };

            var vertex_shader: *w32.ID3D11VertexShader = undefined;
            const vertex_result = device.CreateVertexShader(
                @ptrCast(vertex_blob.GetBufferPointer()),
                vertex_blob.GetBufferSize(),
                null,
                &vertex_shader,
            );
            if (dx11.Error.from(vertex_result)) |err| {
                misc.error_context.new("{f}", .{err});
                misc.error_context.append("ID3D11Device.CreateVertexShader returned a failure value.", .{});
                return error.Dx11Error;
            }
            errdefer _ = vertex_shader.IUnknown.Release();

            var pixel_shader: *w32.ID3D11PixelShader = undefined;
            const pixel_result = device.CreatePixelShader(
                @ptrCast(pixel_blob.GetBufferPointer()),
                pixel_blob.GetBufferSize(),
                null,
                &pixel_shader,
            );
            if (dx11.Error.from(pixel_result)) |err| {
                misc.error_context.new("{f}", .{err});
                misc.error_context.append("ID3D11Device.CreatePixelShader returned a failure value.", .{});
                return error.Dx11Error;
            }
            errdefer _ = pixel_shader.IUnknown.Release();

            const geometry_shader = if (geometry_blob) |blob| block: {
                var shader: *w32.ID3D11GeometryShader = undefined;
                const result = device.CreateGeometryShader(
                    @ptrCast(blob.GetBufferPointer()),
                    blob.GetBufferSize(),
                    null,
                    &shader,
                );
                if (dx11.Error.from(result)) |err| {
                    misc.error_context.new("{f}", .{err});
                    misc.error_context.append("ID3D11Device.CreateGeometryShader returned a failure value.", .{});
                    return error.Dx11Error;
                }
                break :block shader;
            } else null;
            errdefer if (geometry_shader) |shader| {
                _ = shader.IUnknown.Release();
            };

            const input_layout_desc = getInputLayoutDesc(Vertex);
            var input_layout: *w32.ID3D11InputLayout = undefined;
            const input_result = device.CreateInputLayout(
                input_layout_desc.ptr,
                input_layout_desc.len,
                @ptrCast(vertex_blob.GetBufferPointer()),
                vertex_blob.GetBufferSize(),
                &input_layout,
            );
            if (dx11.Error.from(input_result)) |err| {
                misc.error_context.new("{f}", .{err});
                misc.error_context.append("ID3D11Device.CreateInputLayout returned a failure value.", .{});
                return error.Dx11Error;
            }
            errdefer _ = input_layout.IUnknown.Release();

            var depth_stencil_state: *w32.ID3D11DepthStencilState = undefined;
            const depth_stencil_result = device.CreateDepthStencilState(
                &config.getNativeDepthStencil(),
                &depth_stencil_state,
            );
            if (dx11.Error.from(depth_stencil_result)) |err| {
                misc.error_context.new("{f}", .{err});
                misc.error_context.append("ID3D11Device.CreateDepthStencilState returned a failure value.", .{});
                return error.Dx11Error;
            }
            errdefer _ = depth_stencil_state.IUnknown.Release();

            var blend_state: *w32.ID3D11BlendState = undefined;
            const blend_result = device.CreateBlendState(&config.blend.toNative(), &blend_state);
            if (dx11.Error.from(blend_result)) |err| {
                misc.error_context.new("{f}", .{err});
                misc.error_context.append("ID3D11Device.CreateBlendState returned a failure value.", .{});
                return error.Dx11Error;
            }
            errdefer _ = blend_state.IUnknown.Release();

            var rasterizer_state: *w32.ID3D11RasterizerState = undefined;
            const rasterizer_result = device.CreateRasterizerState(&config.rasterizer.toNative(), &rasterizer_state);
            if (dx11.Error.from(rasterizer_result)) |err| {
                misc.error_context.new("{f}", .{err});
                misc.error_context.append("ID3D11Device.CreateRasterizerState returned a failure value.", .{});
                return error.Dx11Error;
            }
            errdefer _ = rasterizer_state.IUnknown.Release();

            const test_allocation = if (builtin.is_test) try std.testing.allocator.create(u8) else {};

            return .{
                .primitive_topology = config.primitive_topology.toNative(),
                .vertex_shader = vertex_shader,
                .pixel_shader = pixel_shader,
                .geometry_shader = geometry_shader,
                .input_layout = input_layout,
                .depth_stencil_state = depth_stencil_state,
                .blend_state = blend_state,
                .rasterizer_state = rasterizer_state,
                .vertex_buffer = null,
                .index_buffer = null,
                .constant_buffer = null,
                .vertex_count = 0,
                .index_count = 0,
                .test_allocation = test_allocation,
            };
        }

        pub fn deinit(self: *const Self, context: *const dx11.Context) void {
            context.waitForGpu();
            if (self.constant_buffer) |buffer| {
                _ = buffer.handle.IUnknown.Release();
            }
            if (self.index_buffer) |buffer| {
                _ = buffer.handle.IUnknown.Release();
            }
            if (self.vertex_buffer) |buffer| {
                _ = buffer.handle.IUnknown.Release();
            }
            _ = self.rasterizer_state.IUnknown.Release();
            _ = self.blend_state.IUnknown.Release();
            _ = self.depth_stencil_state.IUnknown.Release();
            _ = self.input_layout.IUnknown.Release();
            _ = self.pixel_shader.IUnknown.Release();
            if (self.geometry_shader) |shader| {
                _ = shader.IUnknown.Release();
            }
            _ = self.vertex_shader.IUnknown.Release();

            if (builtin.is_test) {
                std.testing.allocator.destroy(self.test_allocation);
            }
        }

        pub fn setVertices(self: *Self, context: *const dx11.Context, vertices: []const Vertex) !void {
            setBufferData(Vertex, context, &self.vertex_buffer, vertices, .vertex) catch |err| {
                misc.error_context.append("Failed to set vertex buffer data.", .{});
                return err;
            };
            self.vertex_count = @intCast(vertices.len);
        }

        pub fn setIndices(self: *Self, context: *const dx11.Context, indices: []const Index) !void {
            if (Index == void) {
                @compileError("This function is not defined for indices of type void.");
            }
            setBufferData(Index, context, &self.index_buffer, indices, .index) catch |err| {
                misc.error_context.append("Failed to set vertex buffer data.", .{});
                return err;
            };
            self.index_count = @intCast(indices.len);
        }

        pub fn setConstants(self: *Self, context: *const dx11.Context, constants: *const Constants) !void {
            if (Constants == void) {
                @compileError("This function is not defined for constants of type void.");
            }
            setBufferData(Constants, context, &self.constant_buffer, constants[0..1], .constant) catch |err| {
                misc.error_context.append("Failed to set vertex buffer data.", .{});
                return err;
            };
        }

        pub fn draw(self: *const Self, context: *const dx11.Context, buffer_context: *const dx11.BufferContext) !void {
            const device_context = context.device_context;
            _ = buffer_context;

            const vertex_buffer = self.vertex_buffer orelse {
                misc.error_context.new("Vertices never set.", .{});
                return error.MissingVertices;
            };
            if (Index != void and self.index_buffer == null) {
                misc.error_context.new("Indices never set.", .{});
                return error.MissingIndices;
            }
            if (Constants != void and self.constant_buffer == null) {
                misc.error_context.new("Constants never set.", .{});
                return error.MissingConstants;
            }

            device_context.IASetPrimitiveTopology(self.primitive_topology);
            device_context.VSSetShader(self.vertex_shader, null, 0);
            device_context.PSSetShader(self.pixel_shader, null, 0);
            device_context.GSSetShader(self.geometry_shader, null, 0);
            device_context.IASetInputLayout(self.input_layout);
            device_context.OMSetDepthStencilState(self.depth_stencil_state, 0xFF);
            const blend_factor = [4]f32{ 1.0, 1.0, 1.0, 1.0 };
            device_context.OMSetBlendState(self.blend_state, &blend_factor[0], 0xFFFFFFFF);
            device_context.RSSetState(self.rasterizer_state);
            if (self.constant_buffer) |buffer| {
                var array = [1](?*w32.ID3D11Buffer){buffer.handle};
                const buffers: [*](?*w32.ID3D11Buffer) = &array;
                device_context.VSSetConstantBuffers(0, 1, buffers);
                if (self.geometry_shader != null) {
                    device_context.GSSetConstantBuffers(0, 1, buffers);
                }
                device_context.PSSetConstantBuffers(0, 1, buffers);
            } else {
                device_context.VSSetConstantBuffers(0, 0, null);
                if (self.geometry_shader != null) {
                    device_context.GSSetConstantBuffers(0, 0, null);
                }
                device_context.PSSetConstantBuffers(0, 0, null);
            }
            var array = [1](?*w32.ID3D11Buffer){vertex_buffer.handle};
            const buffers: [*](?*w32.ID3D11Buffer) = &array;
            const sizes: [*]const u32 = &[1]u32{@sizeOf(Vertex)};
            const offsets: [*]const u32 = &[1]u32{0};
            device_context.IASetVertexBuffers(0, 1, buffers, sizes, offsets);

            const format: w32.DXGI_FORMAT = switch (Index) {
                void => {
                    device_context.Draw(self.vertex_count, 0);
                    return;
                },
                u16 => .R16_UINT,
                u32 => .R32_UINT,
                else => @compileError("Expecting Index to be void, u16 or u32 but got: " ++ @typeName(Index)),
            };
            device_context.IASetIndexBuffer(self.index_buffer.?.handle, format, 0);
            device_context.DrawIndexed(self.index_count, 0, 0);
        }

        fn setBufferData(
            comptime Element: type,
            context: *const dx11.Context,
            buffer_maybe: *?Buffer,
            data: []const Element,
            buffer_type: enum { vertex, index, constant },
        ) !void {
            const device = context.device;
            const device_context = context.device_context;

            const len = std.math.cast(u32, data.len) orelse {
                misc.error_context.new("Overflow while casting vertices length.", .{});
                return error.Overflow;
            };
            const bytes_needed = std.math.mul(u32, len, @sizeOf(Element)) catch |err| {
                misc.error_context.new("Overflow while calculating bytes needed.", .{});
                return err;
            };
            if (buffer_maybe.*) |*buffer| {
                if (bytes_needed > buffer.size) {
                    _ = buffer.handle.IUnknown.Release();
                    buffer_maybe.* = null;
                }
            }

            const buffer = buffer_maybe.* orelse block: {
                errdefer misc.error_context.append("Failed to (re)allocate the buffer.", .{});
                const size = switch (buffer_type) {
                    .vertex, .index => std.math.ceilPowerOfTwo(u32, bytes_needed) catch std.math.maxInt(u32),
                    .constant => b: {
                        if (@sizeOf(Constants) > std.math.maxInt(u32) - 15) {
                            misc.error_context.new("Overflow while calculating size.", .{});
                            return error.Overflow;
                        }
                        break :b std.mem.alignForward(u32, bytes_needed, 16);
                    },
                };

                const desc = w32.D3D11_BUFFER_DESC{
                    .ByteWidth = size,
                    .Usage = .DYNAMIC,
                    .BindFlags = switch (buffer_type) {
                        .vertex => .{ .VERTEX_BUFFER = 1 },
                        .index => .{ .INDEX_BUFFER = 1 },
                        .constant => .{ .CONSTANT_BUFFER = 1 },
                    },
                    .CPUAccessFlags = .{ .WRITE = 1 },
                    .MiscFlags = .{},
                    .StructureByteStride = 0,
                };
                var handle: *w32.ID3D11Buffer = undefined;
                const result = device.CreateBuffer(&desc, null, &handle);
                if (dx11.Error.from(result)) |err| {
                    misc.error_context.new("{f}", .{err});
                    misc.error_context.append("ID3D11Device.CreateBuffer returned a failure value.", .{});
                    return error.Dx11Error;
                }

                const buffer = Buffer{ .handle = handle, .size = size };
                buffer_maybe.* = buffer;
                break :block buffer;
            };

            var mapped: w32.D3D11_MAPPED_SUBRESOURCE = undefined;
            const result = device_context.Map(&buffer.handle.ID3D11Resource, 0, .WRITE_DISCARD, 0, &mapped);
            if (dx11.Error.from(result)) |err| {
                misc.error_context.new("{f}", .{err});
                misc.error_context.append("ID3D11DeviceContext.Map returned a failure value.", .{});
                return error.Dx11Error;
            }
            defer device_context.Unmap(&buffer.handle.ID3D11Resource, 0);

            if (mapped.pData == null) {
                misc.error_context.new("ID3D11DeviceContext.Map returned a null address to data.", .{});
                return error.Dx11Error;
            }
            const mapped_data: [*]u8 = @ptrCast(mapped.pData);

            if (buffer_type == .constant) {
                @memset(mapped_data[0..buffer.size], 0);
            }
            @memcpy(mapped_data, std.mem.sliceAsBytes(data));
        }
    };
}

fn compile(source_code: [:0]const u8, entry_point: [:0]const u8, target: [:0]const u8) !*w32.ID3DBlob {
    var shader_blob: ?*w32.ID3DBlob = null;
    var error_blob: ?*w32.ID3DBlob = null;
    const result = w32.D3DCompile(
        source_code.ptr,
        source_code.len,
        null,
        null,
        null,
        entry_point,
        target,
        0,
        0,
        &shader_blob,
        &error_blob,
    );
    errdefer if (shader_blob) |blob| {
        _ = blob.IUnknown.Release();
    };
    defer if (error_blob) |blob| {
        _ = blob.IUnknown.Release();
    };
    if (dx11.Error.from(result)) |err| {
        misc.error_context.clear();
        if (error_blob) |blob| {
            const base: [*c]u8 = @ptrCast(blob.GetBufferPointer());
            const compile_error = std.mem.sliceTo(base[0..blob.GetBufferSize()], 0);
            misc.error_context.append("{s}", .{compile_error});
        }
        misc.error_context.append("{f}", .{err});
        misc.error_context.append("D3DCompile returned a failure value.", .{});
        return error.Dx11Error;
    }
    return shader_blob orelse {
        misc.error_context.new("D3DCompile returned a null pointer to result blob.", .{});
        return error.Dx11Error;
    };
}

inline fn getInputLayoutDesc(comptime Vertex: type) []const w32.D3D11_INPUT_ELEMENT_DESC {
    comptime {
        const info = switch (@typeInfo(Vertex)) {
            .@"struct" => |*info| info,
            else => @compileError("Expecting Vertex to be a struct type but got: " ++ @typeName(Vertex)),
        };
        if (info.layout != .@"extern") {
            @compileError(std.fmt.comptimePrint(
                "Expecting vertex struct {s} to have extern layout but got: {s}",
                .{ @typeName(Vertex), @tagName(info.layout) },
            ));
        }
        if (@sizeOf(Vertex) % 16 != 0) {
            @compileError(std.fmt.comptimePrint(
                "Expecting size of vertex struct {s} to be divisible with 16 but got: {}",
                .{ @typeName(Vertex), @sizeOf(Vertex) },
            ));
        }
        var result: [info.fields.len]w32.D3D11_INPUT_ELEMENT_DESC = undefined;
        var len: usize = 0;
        for (info.fields) |*field| {
            if (field.name.len == 0 or field.name[0] == '_') {
                continue;
            }
            result[len] = .{
                .SemanticName = field.name,
                .SemanticIndex = 0,
                .Format = getTypeFormat(field.type),
                .InputSlot = 0,
                .AlignedByteOffset = @offsetOf(Vertex, field.name),
                .InputSlotClass = .VERTEX_DATA,
                .InstanceDataStepRate = 0,
            };
            len += 1;
        }
        const final = result[0..len].*;
        return &final;
    }
}

inline fn getTypeFormat(comptime Type: type) w32.DXGI_FORMAT {
    return switch (Type) {
        u8 => .R8_UINT,
        [1]u8 => .R8_UINT,
        [2]u8 => .R8G8_UINT,
        [3]u8 => .R8G8B8_UINT,
        [4]u8 => .R8G8B8A8_UINT,
        math.Vector(1, u8) => .R8_UINT,
        math.Vector(2, u8) => .R8G8_UINT,
        math.Vector(3, u8) => .R8G8B8_UINT,
        math.Vector(4, u8) => .R8G8B8A8_UINT,
        i8 => .R8_SINT,
        [1]i8 => .R8_SINT,
        [2]i8 => .R8G8_SINT,
        [3]i8 => .R8G8B8_SINT,
        [4]i8 => .R8G8B8A8_SINT,
        math.Vector(1, i8) => .R8_SINT,
        math.Vector(2, i8) => .R8G8_SINT,
        math.Vector(3, i8) => .R8G8B8_SINT,
        math.Vector(4, i8) => .R8G8B8A8_SINT,
        u16 => .R16_UINT,
        [1]u16 => .R16_UINT,
        [2]u16 => .R16G16_UINT,
        [3]u16 => .R16G16B16_UINT,
        [4]u16 => .R16G16B16A16_UINT,
        math.Vector(1, u16) => .R16_UINT,
        math.Vector(2, u16) => .R16G16_UINT,
        math.Vector(3, u16) => .R16G16B16_UINT,
        math.Vector(4, u16) => .R16G16B16A16_UINT,
        i16 => .R16_SINT,
        [1]i16 => .R16_SINT,
        [2]i16 => .R16G16_SINT,
        [3]i16 => .R16G16B16_SINT,
        [4]i16 => .R16G16B16A16_SINT,
        math.Vector(1, i16) => .R16_SINT,
        math.Vector(2, i16) => .R16G16_SINT,
        math.Vector(3, i16) => .R16G16B16_SINT,
        math.Vector(4, i16) => .R16G16B16A16_SINT,
        f16 => .R16_FLOAT,
        [1]f16 => .R16_FLOAT,
        [2]f16 => .R16G16_FLOAT,
        [3]f16 => .R16G16B16_FLOAT,
        [4]f16 => .R16G16B16A16_FLOAT,
        math.Vector(1, f16) => .R16_FLOAT,
        math.Vector(2, f16) => .R16G16_FLOAT,
        math.Vector(3, f16) => .R16G16B16_FLOAT,
        math.Vector(4, f16) => .R16G16B16A16_FLOAT,
        u32 => .R32_UINT,
        [1]u32 => .R32_UINT,
        [2]u32 => .R32G32_UINT,
        [3]u32 => .R32G32B32_UINT,
        [4]u32 => .R32G32B32A32_UINT,
        math.Vector(1, u32) => .R32_UINT,
        math.Vector(2, u32) => .R32G32_UINT,
        math.Vector(3, u32) => .R32G32B32_UINT,
        math.Vector(4, u32) => .R32G32B32A32_UINT,
        i32 => .R32_SINT,
        [1]i32 => .R32_SINT,
        [2]i32 => .R32G32_SINT,
        [3]i32 => .R32G32B32_SINT,
        [4]i32 => .R32G32B32A32_SINT,
        math.Vector(1, i32) => .R32_SINT,
        math.Vector(2, i32) => .R32G32_SINT,
        math.Vector(3, i32) => .R32G32B32_SINT,
        math.Vector(4, i32) => .R32G32B32A32_SINT,
        f32 => .R32_FLOAT,
        [1]f32 => .R32_FLOAT,
        [2]f32 => .R32G32_FLOAT,
        [3]f32 => .R32G32B32_FLOAT,
        [4]f32 => .R32G32B32A32_FLOAT,
        math.Vector(1, f32) => .R32_FLOAT,
        math.Vector(2, f32) => .R32G32_FLOAT,
        math.Vector(3, f32) => .R32G32B32_FLOAT,
        math.Vector(4, f32) => .R32G32B32A32_FLOAT,
        else => @compileError("Unsupported vertex attribute type: " ++ @typeName(Type)),
    };
}

fn checkConstantsLayout(comptime Constants: type, vertex_blob: *w32.ID3DBlob) !void {
    const fields: []const std.builtin.Type.StructField = switch (@typeInfo(Constants)) {
        .void => &.{},
        .@"struct" => |*info| block: {
            if (info.layout != .@"extern") {
                @compileError(std.fmt.comptimePrint(
                    "Expecting constants struct {s} to have extern layout but got: {s}",
                    .{ @typeName(Constants), @tagName(info.layout) },
                ));
            }
            break :block info.fields;
        },
        else => @compileError("Expecting Constants to be a struct type but got: " ++ @typeName(Constants)),
    };

    var reflection: *w32.ID3D11ShaderReflection = undefined;
    const reflect_result = w32.D3DReflect(
        @ptrCast(vertex_blob.GetBufferPointer()),
        vertex_blob.GetBufferSize(),
        w32.IID_ID3D11ShaderReflection,
        @ptrCast(&reflection),
    );
    if (dx11.Error.from(reflect_result)) |err| {
        misc.error_context.new("{f}", .{err});
        misc.error_context.append("ID3DReflect returned a failure value.", .{});
        return error.Dx11Error;
    }
    defer _ = reflection.IUnknown.Release();

    const constants = reflection.GetConstantBufferByName("Constants") orelse {
        if (fields.len == 0) {
            return;
        }
        misc.error_context.new("Failed to find cbuffer called Constants inside the shader.", .{});
        return error.Dx11Error;
    };

    var number_of_fields: usize = 0;
    inline for (fields) |*field| {
        errdefer misc.error_context.append("Check failed for field: {s}", .{field.name});
        if (field.name.len == 0 or field.name[0] == '_') {
            continue;
        }
        const variable = constants.GetVariableByName(field.name) orelse {
            misc.error_context.append("Failed to find a HLSL variable with matching name.", .{});
            return error.LinkError;
        };
        var desc: w32.D3D11_SHADER_VARIABLE_DESC = undefined;
        const desc_result = variable.GetDesc(&desc);
        if (dx11.Error.from(desc_result)) |err| {
            misc.error_context.new("{f}", .{err});
            misc.error_context.append("ID3D11ShaderReflectionVariable.GetDesc returned a failure value.", .{});
            return error.Dx11Error;
        }
        if (desc.StartOffset != @offsetOf(Constants, field.name)) {
            misc.error_context.new(
                "GPU offset {} does not match the CPU offset: {}",
                .{ desc.StartOffset, @offsetOf(Constants, field.name) },
            );
            return error.LinkError;
        }
        if (desc.Size != @sizeOf(field.type)) {
            misc.error_context.new(
                "GPU size {} does not match the CPU size: {}",
                .{ desc.Size, @sizeOf(field.type) },
            );
            return error.LinkError;
        }
        number_of_fields += 1;
    }

    var desc: w32.D3D11_SHADER_BUFFER_DESC = undefined;
    const desc_result = constants.GetDesc(&desc);
    if (dx11.Error.from(desc_result)) |err| {
        if (fields.len == 0) {
            return;
        }
        misc.error_context.new("{f}", .{err});
        misc.error_context.append("ID3D11ShaderReflectionConstantBuffer.GetDesc returned a failure value.", .{});
        return error.Dx11Error;
    }
    if (desc.Variables != number_of_fields) {
        misc.error_context.new(
            "Found {} constant variables on the GPU side while the CPU side contains only {} constant fields.",
            .{ desc.Variables, number_of_fields },
        );
        return error.LinkError;
    }
}

const testing = std.testing;

test "draw should draw a simple triangle without crashing" {
    if (@import("config").skip_gpu) {
        return error.SkipZigTest;
    }
    const testing_context = try dx11.TestingContext.init();
    defer testing_context.deinit();
    const host_context = testing_context.getHostContext();
    var managed_context = try dx11.ManagedContext.init(testing.allocator, &host_context);
    defer managed_context.deinit();
    var context = dx11.Context.fromHostAndManaged(&testing_context.getHostContext(), &managed_context);

    const source_code =
        \\struct Vertex {
        \\    float3 position : position;
        \\    float4 color : color;
        \\};
        \\
        \\struct Pixel {
        \\    float4 position: SV_POSITION;
        \\    float4 color: COLOR;
        \\};
        \\
        \\cbuffer Constants : register(b0) {
        \\    float2 screen_size;
        \\}
        \\
        \\Pixel vs_main(Vertex vertex) {
        \\    Pixel pixel;
        \\    pixel.position.xyz = vertex.position;
        \\    pixel.position.xy /= screen_size;
        \\    pixel.position.w = 1;
        \\    pixel.color = vertex.color;
        \\    return pixel;
        \\}
        \\
        \\float4 ps_main(Pixel pixel) : SV_TARGET {
        \\    return pixel.color;
        \\}
    ;
    const Vertex = extern struct {
        position: math.Vec3,
        _padding: f32 = 0,
        color: math.Vec4,
    };
    const Constants = extern struct {
        screen_size: math.Vec2,
    };

    var shader = try Shader(Vertex, u16, Constants).init(&context, &.{ .source_code = source_code });
    defer shader.deinit(&context);

    try shader.setVertices(&context, &.{
        .{ .position = .fromArray(.{ -0.5, -0.5, 0 }), .color = .fromArray(.{ 1, 0, 0, 1 }) },
        .{ .position = .fromArray(.{ 0.5, -0.5, 0 }), .color = .fromArray(.{ 0, 1, 0, 1 }) },
        .{ .position = .fromArray(.{ 0, 0.5, 0 }), .color = .fromArray(.{ 0, 0, 1, 1 }) },
    });
    try shader.setIndices(&context, &.{ 0, 1, 2 });
    try shader.setConstants(&context, &.{ .screen_size = .fromArray(.{ 1, 1 }) });

    for (0..10) |_| {
        const buffer_context = try context.beforeRender();
        try context.setDefaultViewportsAndScissors(buffer_context);
        try shader.draw(&context, buffer_context);
        try context.afterRender(buffer_context);
        const result = context.swap_chain.Present(0, 0);
        if (dx11.Error.from(result)) |_| return error.PresentFailed;
    }
}
