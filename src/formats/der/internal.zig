const std = @import("std");
const Type = std.builtin.Type;

const Reader = @import("Reader.zig");
const types = @import("types.zig");

const asn1_types = [_]type{
    types.Any,
    types.Integer,
    types.BitString,
    types.OctetString,
    types.Null,
    types.Sequence,
    types.ObjectIdentifier,
};

pub const ReadOptions = struct {
    value_only: ?u28 = null,
};

pub fn read(comptime T: type, reader: *Reader, opts: ReadOptions) !T {
    inline for (asn1_types) |U| {
        if (T == U) return selectRead(T, reader, opts.value_only);
    }

    switch (@typeInfo(T)) {
        .Pointer => |type_info| return readPointer(type_info, reader, opts),
        .Array => |type_info| return readArray(type_info, reader, opts),
        .Int => return readInt(T, reader, opts),
        .Struct => |type_info| return readStruct(T, type_info, reader, opts),
        .Union => |type_info| return readUnion(T, type_info, reader, opts),
        .Optional => @compileError("Optinals are not allowed outside a struct"),
        else => @compileError("Not implemented for type '" ++ @typeName(T) ++ "'"),
    }
}

fn readPointer(type_info: Type.Pointer, reader: *Reader, opts: ReadOptions) ![]const u8 {
    if (type_info.size != .Slice) @compileError("Not implemented for non-slice types");
    if (!type_info.is_const) @compileError("Only implemented for const slices");
    if (type_info.child != u8) @compileError("Only implemented for []const u8");

    const octet_string = try selectRead(types.OctetString, reader, opts.value_only);
    return octet_string.bytes;
}

fn readArray(type_info: Type.Array, reader: *Reader, opts: ReadOptions) ![type_info.len]u8 {
    if (type_info.sentinel != null) @compileError("Arrays must have no sentinel value");
    if (type_info.child != u8) @compileError("Must be a u8 array");

    const octet_string = try selectRead(types.OctetString, reader, opts.value_only);
    if (octet_string.bytes.len != type_info.len) return error.ArrayLengthMismatch;

    var arr: [type_info.len]u8 = undefined;
    @memcpy(&arr, octet_string.bytes);

    return arr;
}

fn readInt(comptime IntT: type, reader: *Reader, opts: ReadOptions) !IntT {
    const integer = try selectRead(types.Integer, reader, opts.value_only);
    return integer.cast(IntT);
}

fn readStruct(comptime T: type, type_info: Type.Struct, reader: *Reader, opts: ReadOptions) !T {
    // NOTE: Doing this becase otherwise we have no way of detecting that
    // this is a type generated by a type function in Zig currently (0.14).
    inline for (type_info.decls) |decl| {
        // NOTE 2: This is a hacky way of detecting we are looking for a ContextSpecific type.
        if (std.mem.eql(u8, decl.name, "__der_ctx_spc")) {
            return T.read(reader);
        }
    }

    const sequence = try selectRead(types.Sequence, reader, opts.value_only);
    var sequence_reader = sequence.der_reader();

    var ret_val: T = undefined;
    inline for (type_info.fields) |field| {
        @field(ret_val, field.name) = switch (@typeInfo(field.type)) {
            .Optional => |field_type| try readOptional(field_type.child, &sequence_reader, opts),
            else => try read(field.type, &sequence_reader, opts),
        };
    }

    return ret_val;
}

fn readOptional(comptime T: type, reader: *Reader, opts: ReadOptions) !?T {
    const reader_pos = reader.stream.pos;
    if (reader_pos >= reader.stream.buffer.len) return null;

    const ret_val = read(T, reader, opts) catch |err| {
        reader.stream.pos = reader_pos;
        switch (err) {
            error.UnexpectedTag, error.UnexpectedClass => return null,
            else => return err,
        }
    };

    return ret_val;
}

fn readUnion(comptime T: type, type_info: Type.Union, reader: *Reader, opts: ReadOptions) !T {
    inline for (type_info.fields) |field| {
        const reader_pos = reader.stream.pos;
        const val = read(field.type, reader, opts) catch blk: {
            reader.stream.pos = reader_pos;
            break :blk null;
        };
        if (val) |v| return @unionInit(T, field.name, v);
    }

    return error.Cast;
}

fn selectRead(comptime T: type, reader: *Reader, value_only: ?u28) !T {
    if (value_only) |len| {
        return T.readValue(reader, len);
    }
    return T.read(reader);
}
