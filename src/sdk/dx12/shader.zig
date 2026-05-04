const std = @import("std");
const builtin = @import("builtin");
const w32 = @import("win32").everything;
const misc = @import("../misc/root.zig");
const math = @import("../math/root.zig");
const dx12 = @import("root.zig");

pub fn Shader(Vertex: type, Index: type, Constants: type) type {
    return struct {
        primitive_topology: w32.D3D_PRIMITIVE_TOPOLOGY,
        root_signature: *w32.ID3D12RootSignature,
        pipeline_state: *w32.ID3D12PipelineState,
        vertex_buffers: BufferSet,
        index_buffers: BufferSet,
        constant_buffers: BufferSet,
        vertex_count: u32,
        index_count: u32,
        test_allocation: if (builtin.is_test) *u8 else void,

        const Self = @This();
        const BufferSet = struct {
            buffers: [max_back_buffer_count]?Buffer = [1](?Buffer){null} ** max_back_buffer_count,
            current_index: usize = 0,
            last_back_buffer_index: u32 = 0,
        };
        const Buffer = struct {
            resource: *w32.ID3D12Resource,
            size: u32,
            mapped_data: [*]u8,
        };
        const max_back_buffer_count = 4;

        pub fn init(context: *const dx12.Context, config: *const dx12.ShaderConfig) !Self {
            const device = context.device;

            const vertex_blob = compile(config.source_code, "vs_main", "vs_5_0") catch |err| {
                misc.error_context.append("Failed to compile vertex_shader.", .{});
                return err;
            };
            defer _ = vertex_blob.IUnknown.Release();

            const pixel_blob = compile(config.source_code, "ps_main", "ps_5_0") catch |err| {
                misc.error_context.append("Failed to compile.", .{});
                return err;
            };
            defer _ = pixel_blob.IUnknown.Release();

            const geometry_blob = switch (config.use_geometry_shader) {
                true => compile(config.source_code, "gs_main", "gs_5_0") catch |err| {
                    misc.error_context.append("Failed to compile.", .{});
                    return err;
                },
                false => null,
            };
            defer if (geometry_blob) |blob| {
                _ = blob.IUnknown.Release();
            };

            try checkConstantsLayout(Constants, vertex_blob);

            const params = w32.D3D12_ROOT_PARAMETER{
                .ParameterType = .CBV,
                .Anonymous = .{ .Descriptor = .{
                    .ShaderRegister = 0,
                    .RegisterSpace = 0,
                } },
                .ShaderVisibility = .ALL,
            };
            const root_signature_desc = w32.D3D12_VERSIONED_ROOT_SIGNATURE_DESC{
                .Version = w32.D3D_ROOT_SIGNATURE_VERSION_1_0,
                .Anonymous = .{ .Desc_1_0 = .{
                    .NumParameters = switch (Constants) {
                        void => 0,
                        else => 1,
                    },
                    .pParameters = switch (Constants) {
                        void => null,
                        else => &params,
                    },
                    .NumStaticSamplers = 0,
                    .pStaticSamplers = null,
                    .Flags = .{ .ALLOW_INPUT_ASSEMBLER_INPUT_LAYOUT = 1 },
                } },
            };
            var root_signature_blob_maybe: ?*w32.ID3DBlob = null;
            var error_blob: ?*w32.ID3DBlob = null;
            const serialize_result = w32.D3D12SerializeVersionedRootSignature(
                &root_signature_desc,
                &root_signature_blob_maybe,
                &error_blob,
            );
            defer if (error_blob) |blob| {
                _ = blob.IUnknown.Release();
            };
            if (dx12.Error.from(serialize_result)) |err| {
                misc.error_context.clear();
                if (error_blob) |blob| {
                    const base: [*c]u8 = @ptrCast(blob.GetBufferPointer());
                    const compile_error = std.mem.sliceTo(base[0..blob.GetBufferSize()], 0);
                    misc.error_context.append("{s}", .{compile_error});
                }
                misc.error_context.append("{f}", .{err});
                misc.error_context.append("D3D12SerializeRootSignature returned a failure value.", .{});
                return error.Dx12Error;
            }
            const root_signature_blob = root_signature_blob_maybe orelse {
                misc.error_context.new("D3D12SerializeRootSignature returned a null pointer to the blob.", .{});
                return error.Dx12Error;
            };
            defer _ = root_signature_blob.IUnknown.Release();

            var root_signature: *w32.ID3D12RootSignature = undefined;
            const signature_result = device.CreateRootSignature(
                0,
                @ptrCast(root_signature_blob.GetBufferPointer()),
                root_signature_blob.GetBufferSize(),
                w32.IID_ID3D12RootSignature,
                @ptrCast(&root_signature),
            );
            if (dx12.Error.from(signature_result)) |err| {
                misc.error_context.new("{f}", .{err});
                misc.error_context.append("ID3D12Device.CreateRootSignature returned a failure value.", .{});
                return error.Dx12Error;
            }
            errdefer _ = root_signature.IUnknown.Release();

            const pipeline_state_desc = w32.D3D12_GRAPHICS_PIPELINE_STATE_DESC{
                .pRootSignature = root_signature,
                .VS = .{
                    .pShaderBytecode = vertex_blob.GetBufferPointer(),
                    .BytecodeLength = vertex_blob.GetBufferSize(),
                },
                .PS = .{
                    .pShaderBytecode = pixel_blob.GetBufferPointer(),
                    .BytecodeLength = pixel_blob.GetBufferSize(),
                },
                .DS = .{ .pShaderBytecode = null, .BytecodeLength = 0 },
                .HS = .{ .pShaderBytecode = null, .BytecodeLength = 0 },
                .GS = if (geometry_blob) |blob| .{
                    .pShaderBytecode = blob.GetBufferPointer(),
                    .BytecodeLength = blob.GetBufferSize(),
                } else .{ .pShaderBytecode = null, .BytecodeLength = 0 },
                .StreamOutput = .{
                    .pSODeclaration = null,
                    .NumEntries = 0,
                    .pBufferStrides = null,
                    .NumStrides = 0,
                    .RasterizedStream = 0,
                },
                .BlendState = config.blend.toNative(),
                .SampleMask = 0xFFFFFFFF,
                .RasterizerState = config.rasterizer.toNative(),
                .DepthStencilState = config.getNativeDepthStencil(),
                .InputLayout = getInputLayoutDesc(Vertex),
                .IBStripCutValue = .DISABLED,
                .PrimitiveTopologyType = config.primitive_topology.toNativeType(),
                .NumRenderTargets = 1,
                .RTVFormats = [1]w32.DXGI_FORMAT{.R8G8B8A8_UNORM} ++ ([1]w32.DXGI_FORMAT{.UNKNOWN} ** 7),
                .DSVFormat = .D32_FLOAT,
                .SampleDesc = .{ .Count = 1, .Quality = 0 },
                .NodeMask = 0,
                .CachedPSO = .{ .pCachedBlob = null, .CachedBlobSizeInBytes = 0 },
                .Flags = .{},
            };
            var pipeline_state: *w32.ID3D12PipelineState = undefined;
            const state_result = device.CreateGraphicsPipelineState(
                &pipeline_state_desc,
                w32.IID_ID3D12PipelineState,
                @ptrCast(&pipeline_state),
            );
            if (dx12.Error.from(state_result)) |err| {
                misc.error_context.new("{f}", .{err});
                misc.error_context.append("ID3D12Device.CreateGraphicsPipelineState returned a failure value.", .{});
                return error.Dx12Error;
            }
            errdefer _ = pipeline_state.IUnknown.Release();

            const test_allocation = if (builtin.is_test) try std.testing.allocator.create(u8) else {};

            return .{
                .primitive_topology = config.primitive_topology.toNative(),
                .root_signature = root_signature,
                .pipeline_state = pipeline_state,
                .vertex_buffers = .{},
                .index_buffers = .{},
                .constant_buffers = .{},
                .vertex_count = 0,
                .index_count = 0,
                .test_allocation = test_allocation,
            };
        }

        pub fn deinit(self: *const Self, context: *const dx12.Context) void {
            context.waitForGpu();
            for (&self.constant_buffers.buffers) |buffer_maybe| {
                if (buffer_maybe) |*buffer| {
                    _ = buffer.resource.IUnknown.Release();
                }
            }
            for (&self.index_buffers.buffers) |buffer_maybe| {
                if (buffer_maybe) |*buffer| {
                    _ = buffer.resource.IUnknown.Release();
                }
            }
            for (&self.vertex_buffers.buffers) |buffer_maybe| {
                if (buffer_maybe) |*buffer| {
                    _ = buffer.resource.IUnknown.Release();
                }
            }
            _ = self.pipeline_state.IUnknown.Release();
            _ = self.root_signature.IUnknown.Release();

            if (builtin.is_test) {
                std.testing.allocator.destroy(self.test_allocation);
            }
        }

        pub fn setVertices(self: *Self, context: *const dx12.Context, vertices: []const Vertex) !void {
            setBufferData(Vertex, context, &self.vertex_buffers, vertices, .vertex) catch |err| {
                misc.error_context.append("Failed to set vertex buffer data.", .{});
                return err;
            };
            self.vertex_count = @intCast(vertices.len);
        }

        pub fn setIndices(self: *Self, context: *const dx12.Context, indices: []const Index) !void {
            if (Index == void) {
                @compileError("This function is not defined for indices of type void.");
            }
            setBufferData(Index, context, &self.index_buffers, indices, .index) catch |err| {
                misc.error_context.append("Failed to set vertex buffer data.", .{});
                return err;
            };
            self.index_count = @intCast(indices.len);
        }

        pub fn setConstants(self: *Self, context: *const dx12.Context, constants: *const Constants) !void {
            if (Constants == void) {
                @compileError("This function is not defined for constants of type void.");
            }
            setBufferData(Constants, context, &self.constant_buffers, constants[0..1], .constant) catch |err| {
                misc.error_context.append("Failed to set vertex buffer data.", .{});
                return err;
            };
        }

        pub fn draw(self: *const Self, context: *const dx12.Context, buffer_context: *const dx12.BufferContext) !void {
            _ = context;
            const command_list = buffer_context.command_list;

            const vertex_buffer_maybe = self.vertex_buffers.buffers[self.vertex_buffers.current_index];
            const index_buffer_maybe = self.index_buffers.buffers[self.index_buffers.current_index];
            const constant_buffer_maybe = self.constant_buffers.buffers[self.constant_buffers.current_index];

            const vertex_buffer = vertex_buffer_maybe orelse {
                misc.error_context.new("Vertices never set.", .{});
                return error.MissingVertices;
            };
            if (Index != void and index_buffer_maybe == null) {
                misc.error_context.new("Indices never set.", .{});
                return error.MissingIndices;
            }
            if (Constants != void and constant_buffer_maybe == null) {
                misc.error_context.new("Constants never set.", .{});
                return error.MissingConstants;
            }

            command_list.SetGraphicsRootSignature(self.root_signature);
            command_list.SetPipelineState(self.pipeline_state);
            command_list.IASetPrimitiveTopology(self.primitive_topology);
            if (constant_buffer_maybe) |*buffer| {
                command_list.SetGraphicsRootConstantBufferView(
                    0,
                    buffer.resource.GetGPUVirtualAddress(),
                );
            }
            const vertex_view = w32.D3D12_VERTEX_BUFFER_VIEW{
                .BufferLocation = vertex_buffer.resource.GetGPUVirtualAddress(),
                .SizeInBytes = vertex_buffer.size,
                .StrideInBytes = @sizeOf(Vertex),
            };
            command_list.IASetVertexBuffers(0, 1, (&vertex_view)[0..1]);

            const format: w32.DXGI_FORMAT = switch (Index) {
                void => {
                    command_list.DrawInstanced(self.vertex_count, 1, 0, 0);
                    return;
                },
                u16 => .R16_UINT,
                u32 => .R32_UINT,
                else => @compileError("Expecting Index to be void, u16 or u32 but got: " ++ @typeName(Index)),
            };
            const index_buffer = index_buffer_maybe.?;
            command_list.IASetIndexBuffer(&.{
                .BufferLocation = index_buffer.resource.GetGPUVirtualAddress(),
                .SizeInBytes = index_buffer.size,
                .Format = format,
            });
            command_list.DrawIndexedInstanced(self.index_count, 1, 0, 0, 0);
        }

        fn setBufferData(
            comptime Element: type,
            context: *const dx12.Context,
            buffer_set: *BufferSet,
            data: []const Element,
            buffer_type: enum { vertex, index, constant },
        ) !void {
            const device = context.device;

            var swap_chain_desc: w32.DXGI_SWAP_CHAIN_DESC = undefined;
            const swap_chain_result = context.swap_chain.GetDesc(&swap_chain_desc);
            if (dx12.Error.from(swap_chain_result)) |err| {
                misc.error_context.new("{f}", .{err});
                misc.error_context.append("IDXGISwapChain.GetDesc returned a failure value.", .{});
                return error.Dx12Error;
            }
            const back_buffer_count = swap_chain_desc.BufferCount;
            if (back_buffer_count > max_back_buffer_count) {
                misc.error_context.new(
                    "Back buffer count {} exceeds maximum allowed: {}",
                    .{ back_buffer_count, max_back_buffer_count },
                );
                return error.Dx12Error;
            }
            const swap_chain_3: *const w32.IDXGISwapChain3 = @ptrCast(context.swap_chain);
            const back_buffer_index = swap_chain_3.GetCurrentBackBufferIndex();

            const next_index = switch (back_buffer_index == buffer_set.last_back_buffer_index) {
                true => buffer_set.current_index,
                false => switch (buffer_set.current_index + 1 < back_buffer_count) {
                    true => buffer_set.current_index + 1,
                    false => 0,
                },
            };

            const len = std.math.cast(u32, data.len) orelse {
                misc.error_context.new("Overflow while casting vertices length.", .{});
                return error.Overflow;
            };
            const bytes_needed = std.math.mul(u32, len, @sizeOf(Element)) catch |err| {
                misc.error_context.new("Overflow while calculating bytes needed.", .{});
                return err;
            };

            const buffer_maybe = &buffer_set.buffers[next_index];
            if (buffer_maybe.*) |*buffer| {
                if (bytes_needed > buffer.size) {
                    _ = buffer.resource.IUnknown.Release();
                    buffer_maybe.* = null;
                }
            }

            const buffer = buffer_maybe.* orelse block: {
                errdefer misc.error_context.append("Failed to (re)allocate the buffer.", .{});
                const size = switch (buffer_type) {
                    .vertex, .index => std.math.ceilPowerOfTwo(u32, bytes_needed) catch std.math.maxInt(u32),
                    .constant => b: {
                        if (@sizeOf(Constants) > std.math.maxInt(u32) - 255) {
                            misc.error_context.new("Overflow while calculating size.", .{});
                            return error.Overflow;
                        }
                        break :b std.mem.alignForward(u32, bytes_needed, 256);
                    },
                };

                const props = w32.D3D12_HEAP_PROPERTIES{
                    .Type = .UPLOAD,
                    .CPUPageProperty = .UNKNOWN,
                    .MemoryPoolPreference = .UNKNOWN,
                    .CreationNodeMask = 0,
                    .VisibleNodeMask = 0,
                };
                const desc = w32.D3D12_RESOURCE_DESC{
                    .Dimension = .BUFFER,
                    .Alignment = 0,
                    .Width = size,
                    .Height = 1,
                    .DepthOrArraySize = 1,
                    .MipLevels = 1,
                    .Format = .UNKNOWN,
                    .SampleDesc = .{ .Count = 1, .Quality = 0 },
                    .Layout = .ROW_MAJOR,
                    .Flags = .{},
                };
                var resource: *w32.ID3D12Resource = undefined;
                const resource_result = device.CreateCommittedResource(
                    &props,
                    .{},
                    &desc,
                    w32.D3D12_RESOURCE_STATE_GENERIC_READ,
                    null,
                    w32.IID_ID3D12Resource,
                    @ptrCast(&resource),
                );
                if (dx12.Error.from(resource_result)) |err| {
                    misc.error_context.new("{f}", .{err});
                    misc.error_context.append("ID3D12Device.CreateCommittedResource returned a failure value.", .{});
                    return error.Dx12Error;
                }

                var mapped_maybe: ?*anyopaque = null;
                const map_result = resource.Map(0, &.{ .Begin = 0, .End = 0 }, &mapped_maybe);
                if (dx12.Error.from(map_result)) |err| {
                    misc.error_context.new("{f}", .{err});
                    misc.error_context.append("ID3D12Resource.Map returned a failure value.", .{});
                    return error.Dx12Error;
                }
                const mapped = mapped_maybe orelse {
                    misc.error_context.new("ID3D12Resource.Map returned a null pointer to data.", .{});
                    return error.Dx12Error;
                };

                const buffer = Buffer{
                    .resource = resource,
                    .size = size,
                    .mapped_data = @ptrCast(mapped),
                };
                buffer_maybe.* = buffer;
                break :block buffer;
            };

            if (buffer_type == .constant) {
                @memset(buffer.mapped_data[0..buffer.size], 0);
            }
            @memcpy(buffer.mapped_data, std.mem.sliceAsBytes(data));
            buffer_set.current_index = next_index;
            buffer_set.last_back_buffer_index = back_buffer_index;
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
    if (dx12.Error.from(result)) |err| {
        misc.error_context.clear();
        if (error_blob) |blob| {
            const base: [*c]u8 = @ptrCast(blob.GetBufferPointer());
            const compile_error = std.mem.sliceTo(base[0..blob.GetBufferSize()], 0);
            misc.error_context.append("{s}", .{compile_error});
        }
        misc.error_context.append("{f}", .{err});
        misc.error_context.append("D3DCompile returned a failure value.", .{});
        return error.Dx12Error;
    }
    return shader_blob orelse {
        misc.error_context.new("D3DCompile returned a null pointer to result blob.", .{});
        return error.Dx12Error;
    };
}

inline fn getInputLayoutDesc(comptime Vertex: type) w32.D3D12_INPUT_LAYOUT_DESC {
    const final = comptime block: {
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
        var result: [info.fields.len]w32.D3D12_INPUT_ELEMENT_DESC = undefined;
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
        break :block result[0..len].*;
    };
    return .{
        .pInputElementDescs = &final[0],
        .NumElements = final.len,
    };
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

    var reflection: *w32.ID3D12ShaderReflection = undefined;
    const reflect_result = w32.D3DReflect(
        @ptrCast(vertex_blob.GetBufferPointer()),
        vertex_blob.GetBufferSize(),
        w32.IID_ID3D12ShaderReflection,
        @ptrCast(&reflection),
    );
    if (dx12.Error.from(reflect_result)) |err| {
        misc.error_context.new("{f}", .{err});
        misc.error_context.append("ID3DReflect returned a failure value.", .{});
        return error.Dx12Error;
    }
    defer _ = reflection.IUnknown.Release();

    const constants = reflection.GetConstantBufferByName("Constants") orelse {
        if (fields.len == 0) {
            return;
        }
        misc.error_context.new("Failed to find cbuffer called Constants inside the shader.", .{});
        return error.Dx12Error;
    };

    var number_of_fields: usize = 0;
    inline for (fields) |*field| {
        errdefer misc.error_context.append("Check failed for field: {s}", .{field.name});
        if (field.name.len == 0 or field.name[0] == '_') {
            continue;
        }
        errdefer misc.error_context.append("Check failed for field: {s}", .{field.name});
        const variable = constants.GetVariableByName(field.name) orelse {
            misc.error_context.append("Failed to find a HLSL variable with matching name.", .{});
            return error.LinkError;
        };
        var desc: w32.D3D12_SHADER_VARIABLE_DESC = undefined;
        const desc_result = variable.GetDesc(&desc);
        if (dx12.Error.from(desc_result)) |err| {
            misc.error_context.new("{f}", .{err});
            misc.error_context.append("ID3D12ShaderReflectionVariable.GetDesc returned a failure value.", .{});
            return error.Dx12Error;
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

    var desc: w32.D3D12_SHADER_BUFFER_DESC = undefined;
    const desc_result = constants.GetDesc(&desc);
    if (dx12.Error.from(desc_result)) |err| {
        if (fields.len == 0) {
            return;
        }
        misc.error_context.new("{f}", .{err});
        misc.error_context.append("ID3D12ShaderReflectionConstantBuffer.GetDesc returned a failure value.", .{});
        return error.Dx12Error;
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
    std.debug.print("TEST!\n", .{});
    if (@import("config").skip_gpu) {
        return error.SkipZigTest;
    }
    const testing_context = try dx12.TestingContext.init();
    defer testing_context.deinit();
    const host_context = testing_context.getHostContext();
    var managed_context = try dx12.ManagedContext.init(testing.allocator, &host_context);
    defer managed_context.deinit();
    const context = dx12.Context.fromHostAndManaged(&testing_context.getHostContext(), &managed_context);

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
        try buffer_context.setViewports(&context, &.{.{}});
        try shader.draw(&context, buffer_context);
        try context.afterRender(buffer_context);
        const result = context.swap_chain.Present(0, 0);
        if (dx12.Error.from(result)) |_| return error.PresentFailed;
    }
}
